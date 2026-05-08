#!/usr/bin/env bash
# delegate_to_claude.sh — Main entry point for Claude delegation on macOS.
# Ported from windows_scripts/delegate_to_claude.ps1.

set -euo pipefail

# === Environment & Dependency Check ===
if [[ "${CODEX_CLAUDE_CHILD_THREAD:-}" != "1" ]]; then
  echo "ERROR: This delegate script may only run inside a Codex spawn_agent child thread." >&2
  echo "Missing or unset CODEX_CLAUDE_CHILD_THREAD=1 environment variable." >&2
  exit 1
fi

if ! command -v claude &>/dev/null; then
  echo "ERROR: 'claude' CLI is not found in PATH." >&2
  exit 1
fi

if ! command -v jq &>/dev/null; then
  echo "ERROR: 'jq' is required but not found. Install it: brew install jq" >&2
  exit 1
fi

# === Paths ===
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKFLOW_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORKFLOW_CONTAINER="$(cd "$WORKFLOW_ROOT/.." && pwd)"
WORKFLOW_CONTAINER_NAME="$(basename "$WORKFLOW_CONTAINER")"
if [[ "$WORKFLOW_CONTAINER_NAME" == "docs" || "$WORKFLOW_CONTAINER_NAME" == "doc" ]]; then
  REPO_ROOT="$(cd "$WORKFLOW_CONTAINER/.." && pwd)"
else
  REPO_ROOT="$WORKFLOW_CONTAINER"
fi

HELPER_SCRIPT="${SCRIPT_DIR}/claude_delegate_backend_helpers.sh"
POOL_SCRIPT="${SCRIPT_DIR}/claude_session_pool.sh"

if [[ ! -f "$HELPER_SCRIPT" ]] || [[ ! -f "$POOL_SCRIPT" ]]; then
  echo "ERROR: Backend scripts missing in $SCRIPT_DIR" >&2
  exit 1
fi

source "$HELPER_SCRIPT"
source "$POOL_SCRIPT"

# === Parse Arguments ===
TASK_FILE=""
TASK=""
ARTIFACT_ROOT=".codex/codex_with_cc/claude-delegate"
SESSION_KEY=""
SESSION_MODE="PrimaryReuse"
SCOPE=""
TESTS=""
MAX_BUDGET_USD=""
BYPASS_PERMISSIONS="false"
DRY_RUN="false"
ALLOW_PARALLEL="false"
MODEL=""
MAX_ATTEMPTS=4
MAX_RETRIES=3
SESSION_LEASE_TIMEOUT_SECONDS=600
SESSION_LEASE_WAIT_SECONDS=60

usage() {
  echo "Usage: delegate_to_claude.sh [options]"
  echo "  --task-file PATH           Path to markdown file containing task details"
  echo "  --task STRING              Task details (if not using file)"
  echo "  --session-key KEY          Key for session pooling"
  echo "  --session-mode MODE        PrimaryReuse (default) | PrimaryAnchor | ParallelPool"
  echo "  --bypass-permissions       Pass dangerously-skip-permissions to claude"
  echo "  --dry-run                  Output config but do not run claude"
  echo "  --allow-parallel           Allow parallel execution (for PrimaryAnchor/ParallelPool)"
  echo "  --artifact-root PATH       Root for artifacts (default: .codex/codex_with_cc/claude-delegate)"
  echo "  --scope STRING             Semicolon-separated list of scopes"
  echo "  --tests STRING             Semicolon-separated list of test commands"
  echo "  --max-budget-usd NUM       Max budget in USD"
  echo "  --model MODEL              Claude model to use (default: gpt-5.3-codex)"
  echo "  --max-attempts NUM         Max attempts (default: 4)"
  echo "  --max-retries NUM          Max retries (default: 3)"
  echo "  --session-lease-timeout-seconds NUM"
  echo "  --session-lease-wait-seconds NUM"
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --task-file|-TaskFile) TASK_FILE="$2"; shift 2 ;;
    --task|-Task) TASK="$2"; shift 2 ;;
    --artifact-root|-ArtifactRoot) ARTIFACT_ROOT="$2"; shift 2 ;;
    --session-key|-SessionKey) SESSION_KEY="$2"; shift 2 ;;
    --session-mode|-SessionMode) SESSION_MODE="$2"; shift 2 ;;
    --scope|-Scope) SCOPE="$2"; shift 2 ;;
    --tests|-Tests) TESTS="$2"; shift 2 ;;
    --max-budget-usd|-MaxBudgetUsd) MAX_BUDGET_USD="$2"; shift 2 ;;
    --bypass-permissions|-BypassPermissions) BYPASS_PERMISSIONS="true"; shift ;;
    --dry-run|-DryRun) DRY_RUN="true"; shift ;;
    --allow-parallel|-AllowParallel) ALLOW_PARALLEL="true"; shift ;;
    --model|-Model) MODEL="$2"; shift 2 ;;
    --max-attempts|-MaxAttempts) MAX_ATTEMPTS="$2"; shift 2 ;;
    --max-retries|-MaxRetries) MAX_RETRIES="$2"; shift 2 ;;
    --session-lease-timeout-seconds|-SessionLeaseTimeoutSeconds) SESSION_LEASE_TIMEOUT_SECONDS="$2"; shift 2 ;;
    --session-lease-wait-seconds|-SessionLeaseWaitSeconds) SESSION_LEASE_WAIT_SECONDS="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

if [[ -n "$TASK_FILE" ]]; then
  if [[ ! -f "$TASK_FILE" ]]; then
    echo "ERROR: Task file not found: $TASK_FILE" >&2
    exit 1
  fi
  TASK="$(cat "$TASK_FILE")"
fi

if [[ -z "$TASK" ]]; then
  echo "ERROR: Task definition is missing. Provide --task-file or --task." >&2
  exit 1
fi

if [[ "$ALLOW_PARALLEL" != "true" ]]; then
  if [[ "$SESSION_MODE" == "PrimaryAnchor" || "$SESSION_MODE" == "ParallelPool" ]]; then
    echo "ERROR: --allow-parallel switch is required when using SessionMode $SESSION_MODE" >&2
    exit 1
  fi
fi

if [[ "$SESSION_MODE" != "PrimaryReuse" && "$SESSION_MODE" != "PrimaryAnchor" && "$SESSION_MODE" != "ParallelPool" ]]; then
  echo "ERROR: Invalid SessionMode: $SESSION_MODE. Must be PrimaryReuse, PrimaryAnchor, or ParallelPool" >&2
  exit 1
fi

# === Artifact Setup ===
EFFECTIVE_SESSION_KEY="$(get_effective_session_key "$SESSION_KEY")"
SAFE_SESSION_KEY="$(get_safe_session_key "$EFFECTIVE_SESSION_KEY")"
RUN_ID="$(uuidgen | tr '[:upper:]' '[:lower:]')"
NOW_TIMESTAMP="$(date -u +"%Y-%m-%dT%H:%M:%S%z" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%S")"

if [[ "$ARTIFACT_ROOT" == /* ]]; then
  ARTIFACT_ROOT_ABS="$ARTIFACT_ROOT"
else
  ARTIFACT_ROOT_ABS="$REPO_ROOT/$ARTIFACT_ROOT"
fi

mkdir -p "$ARTIFACT_ROOT_ABS"
PROMPT_PATH="${ARTIFACT_ROOT_ABS}/prompt_${RUN_ID}.md"
OUTPUT_PATH="${ARTIFACT_ROOT_ABS}/claude_${RUN_ID}.md"
STREAM_PATH="${ARTIFACT_ROOT_ABS}/stream_${RUN_ID}.jsonl"
TRACE_PATH="${ARTIFACT_ROOT_ABS}/trace_${RUN_ID}.log"
STATUS_PATH="${ARTIFACT_ROOT_ABS}/status_${RUN_ID}.json"
CONFIG_PATH="${ARTIFACT_ROOT_ABS}/config_${RUN_ID}.json"

SESSION_POOLS_DIR="${ARTIFACT_ROOT_ABS}/session-pools"
mkdir -p "$SESSION_POOLS_DIR"
SESSION_STATE_PATH="${SESSION_POOLS_DIR}/${SAFE_SESSION_KEY}.json"
SESSION_LOCK_PATH="${SESSION_POOLS_DIR}/${SAFE_SESSION_KEY}.lock"

test_claude_delegate_path_writable "$CONFIG_PATH"
test_claude_delegate_path_writable "$SESSION_STATE_PATH"

# === Prompt Builder ===
build_prompt() {
  echo "You are running as a worker agent in the Codex -> Claude Code CLI workflow."
  echo "Execute the following task exactly as specified."
  echo ""
  echo "## Task details:"
  echo "$TASK"
  
  if [[ -n "$SCOPE" ]]; then
    echo ""
    echo "## Scope:"
    echo "You must limit your changes strictly to these scope areas:"
    local scope_lines
    scope_lines="$(normalize_claude_delegate_list "$SCOPE")"
    while IFS= read -r line; do
      [[ -n "$line" ]] && echo "- $line"
    done <<< "$scope_lines"
  fi
  
  if [[ -n "$TESTS" ]]; then
    echo ""
    echo "## Tests:"
    echo "You must run these tests to verify your changes:"
    local test_lines
    test_lines="$(normalize_claude_delegate_list "$TESTS")"
    while IFS= read -r line; do
      [[ -n "$line" ]] && echo "- $line"
    done <<< "$test_lines"
  fi

  echo ""
  echo "## Core Guidelines:"
  echo "1. Stay strictly within the specified scope. Do not rewrite unrelated subsystems."
  echo "2. Keep changes minimal and safe. Fix the issue described without introducing regressions."
  echo "3. Only run read-only commands for discovery. Never execute destructive commands outside the scope."
  echo "4. After making changes, run the specified tests or verification commands."
  echo "5. **Never call docs/codex_with_cc/macos_scripts/delegate_to_claude.sh, claude, or spawn_agent recursively.** You are the worker."
  echo ""
  echo "## Required Report Format"
  echo "When your task is complete and verified, you MUST output a final message that ends EXACTLY with the following headings."
  echo "Do not deviate from these headings or add markdown formatting to the heading names themselves."
  echo "Use standard single # or ## for these."
  echo ""
  echo "\`\`\`"
  echo "Process Log"
  echo "[Brief list of what you investigated and modified]"
  echo ""
  echo "Summary"
  echo "[1-2 sentences summarizing the change]"
  echo ""
  echo "Changed Files"
  echo "- [list of modified/created files]"
  echo ""
  echo "Verification"
  echo "- [commands you ran and their outcomes, e.g., 'pytest passed', or 'could not verify because X']"
  echo ""
  echo "Final Result"
  echo "[Detailed explanation of the final state, any remaining issues, or what the Codex leader needs to know]"
  echo ""
  echo "Risks Or Follow-ups"
  echo "[List of potential side-effects or next steps]"
  echo "\`\`\`"
}

PROMPT_TEXT="$(build_prompt)"
TASK_FINGERPRINT="$(get_task_fingerprint "$TASK" "$SCOPE" "$TESTS" "$SESSION_MODE")"
printf '%s\n' "$PROMPT_TEXT" > "$PROMPT_PATH"

# === Session Lease ===
set +e
acquire_claude_session_lease "$SESSION_STATE_PATH" "$SESSION_LOCK_PATH" "$SAFE_SESSION_KEY" \
  "$SESSION_MODE" "$RUN_ID" "$TASK_FINGERPRINT" \
  "$SESSION_LEASE_TIMEOUT_SECONDS" "$SESSION_LEASE_WAIT_SECONDS" "false" "false"
LEASE_RC=$?
set -e

if [[ $LEASE_RC -ne 0 ]]; then
  echo "ERROR: Failed to acquire Claude session lease." >&2
  
  # Write failure JSON
  STATUS_JSON="$(jq -n \
    --arg schema "2" \
    --arg contract "spawn_agent_child_only" \
    --arg markerName "CODEX_CLAUDE_CHILD_THREAD" \
    --argjson markerVal "true" \
    --arg runId "$RUN_ID" \
    --arg output "$OUTPUT_PATH" \
    --arg prompt "$PROMPT_PATH" \
    --arg stream "$STREAM_PATH" \
    --arg trace "$TRACE_PATH" \
    '{
      artifactSchema: ($schema | tonumber),
      invocationContract: $contract,
      childThreadMarkerName: $markerName,
      childThreadMarkerValidated: $markerVal,
      runId: $runId,
      status: "failed",
      outputPath: $output,
      promptPath: $prompt,
      rawStreamPath: $stream,
      tracePath: $trace,
      exitCode: 1,
      attemptCount: 0,
      retryCount: 0,
      failureDisposition: "NEED_HUMAN_INTERVENTION",
      failureSummary: "STARTUP_FAILURE: Lock acquisition failed or timed out"
    }')"
  write_claude_delegate_json_file "$STATUS_PATH" "$STATUS_JSON"
  exit 1
fi

# Global vars set by acquire_claude_session_lease:
# _LEASE_MODE, _LEASE_SESSION_ID, _LEASE_RESUME, _LEASE_POOL_INDEX, _LEASE_LEASED
INITIAL_SESSION_ID="$_LEASE_SESSION_ID"
INITIAL_RESUME="$_LEASE_RESUME"
CURRENT_SESSION_ID="$_LEASE_SESSION_ID"
CURRENT_RESUME="$_LEASE_RESUME"

# === Config JSON ===
CONFIG_JSON="$(jq -n \
  --arg schema "2" \
  --arg contract "spawn_agent_child_only" \
  --arg markerName "CODEX_CLAUDE_CHILD_THREAD" \
  --argjson markerVal "true" \
  --arg mode "$SESSION_MODE" \
  --arg key "$EFFECTIVE_SESSION_KEY" \
  --arg safeKey "$SAFE_SESSION_KEY" \
  --arg statePath "$SESSION_STATE_PATH" \
  --arg fp "$TASK_FINGERPRINT" \
  --argjson allowParallel "$ALLOW_PARALLEL" \
  --arg initialSid "$INITIAL_SESSION_ID" \
  --argjson initialRes "$INITIAL_RESUME" \
  --arg sid "$CURRENT_SESSION_ID" \
  --argjson res "${CURRENT_RESUME:-false}" \
  --argjson att 1 \
  --argjson rty 0 \
  --arg runId "$RUN_ID" \
  --arg repoRoot "$REPO_ROOT" \
  --arg promptPath "$PROMPT_PATH" \
  --arg outputPath "$OUTPUT_PATH" \
  --arg statusPath "$STATUS_PATH" \
  --arg streamPath "$STREAM_PATH" \
  --arg tracePath "$TRACE_PATH" \
  --arg model "$MODEL" \
  --arg maxBudget "$MAX_BUDGET_USD" \
  --argjson bypass "$BYPASS_PERMISSIONS" \
  --argjson dryRun "$DRY_RUN" \
  '{
    artifactSchema: ($schema | tonumber),
    invocationContract: $contract,
    childThreadMarkerName: $markerName,
    childThreadMarkerValidated: $markerVal,
    sessionMode: $mode,
    sessionKey: $key,
    safeSessionKey: $safeKey,
    sessionStatePath: $statePath,
    taskFingerprint: $fp,
    allowParallel: $allowParallel,
    initialSessionId: $initialSid,
    initialResume: $initialRes,
    sessionId: $sid,
    resume: $res,
    attemptCount: $att,
    retryCount: $rty,
    runId: $runId,
    repoRoot: $repoRoot,
    promptPath: $promptPath,
    outputPath: $outputPath,
    statusPath: $statusPath,
    rawStreamPath: $streamPath,
    tracePath: $tracePath,
    model: $model,
    maxBudgetUsd: ($maxBudget | if . == "" then null else tonumber end),
    bypassPermissions: $bypass,
    dryRun: $dryRun
    }')"

write_claude_delegate_json_file "$CONFIG_PATH" "$CONFIG_JSON"

# === Dry Run ===
if [[ "$DRY_RUN" == "true" ]]; then
  echo "Dry run successful. Generated config:"
  echo "$CONFIG_JSON" | jq .
  
  cat <<EOF > "$OUTPUT_PATH"
Process Log
- dry run execution
Summary
dry run summary
Changed Files
None
Verification
- dry run verify
Final Result
DRY_RUN_PASS
Risks Or Follow-ups
None
EOF
  echo '{"type":"result","subtype":"success"}' > "$STREAM_PATH"
  echo "[dry-run] ok" > "$TRACE_PATH"
  
  STATUS_JSON="$(jq -n \
    --arg schema "2" \
    --arg contract "spawn_agent_child_only" \
    --arg markerName "CODEX_CLAUDE_CHILD_THREAD" \
    --argjson markerVal "true" \
    --arg runId "$RUN_ID" \
    --arg mode "$SESSION_MODE" \
    --arg key "$EFFECTIVE_SESSION_KEY" \
    --arg status "completed" \
    --arg initSid "$INITIAL_SESSION_ID" \
    --argjson initRes "${INITIAL_RESUME:-false}" \
    --arg currSid "$CURRENT_SESSION_ID" \
    --argjson currRes "${CURRENT_RESUME:-false}" \
    --arg output "$OUTPUT_PATH" \
    --arg prompt "$PROMPT_PATH" \
    --arg stream "$STREAM_PATH" \
    --arg trace "$TRACE_PATH" \
    --argjson exitCode "0" \
    '{
      artifactSchema: ($schema | tonumber),
      invocationContract: $contract,
      childThreadMarkerName: $markerName,
      childThreadMarkerValidated: $markerVal,
      runId: $runId,
      sessionMode: $mode,
      sessionKey: $key,
      status: $status,
      initialSessionId: $initSid,
      initialResume: $initRes,
      sessionId: $currSid,
      resume: $currRes,
      outputPath: $output,
      promptPath: $prompt,
      rawStreamPath: $stream,
      tracePath: $trace,
      exitCode: $exitCode,
      attemptCount: 1,
      retryCount: 0,
      attempts: [{
        attempt: 1,
        sessionId: $currSid,
        resume: $currRes,
        retryReason: null,
        exitCode: 0,
        sawAssistantText: true,
        sawResultSuccess: true,
        capturedFinalResult: true
      }]
      }')"
  write_claude_delegate_json_file "$STATUS_PATH" "$STATUS_JSON"
  
  release_claude_session_lease "$SESSION_STATE_PATH" "$SESSION_LOCK_PATH" "$SAFE_SESSION_KEY" \
    "$_LEASE_MODE" "$CURRENT_SESSION_ID" "$RUN_ID" "$TASK_FINGERPRINT" "$_LEASE_LEASED"
  
  echo "Prompt:"
  echo "$PROMPT_PATH"
  echo "Args:"
  new_claude_delegate_cli_args "$MODEL" "delegate-$RUN_ID" "$CURRENT_SESSION_ID" "$CURRENT_RESUME" "$MAX_BUDGET_USD" "$BYPASS_PERMISSIONS" "$PROMPT_TEXT"
  exit 0
fi

# === Execution Loop ===
ATTEMPT=1
RETRY_COUNT=0
STATUS_JSON="$(jq -n '.attempts = []')"
LAST_RETRY_REASON="null"
IS_FINAL_ATTEMPT="false"

touch "$STREAM_PATH"
touch "$TRACE_PATH"
rm -f "${OUTPUT_PATH}.tmp"

while [[ $ATTEMPT -le $MAX_ATTEMPTS ]]; do
  if [[ $ATTEMPT -eq $MAX_ATTEMPTS ]]; then
    IS_FINAL_ATTEMPT="true"
  fi

  CONFIG_JSON="$(echo "$CONFIG_JSON" | jq \
    --arg sid "$CURRENT_SESSION_ID" \
    --argjson res "${CURRENT_RESUME:-false}" \
    --argjson att "$ATTEMPT" \
    --argjson rty "$RETRY_COUNT" \
    '.sessionId = $sid | .resume = $res | .attemptCount = $att | .retryCount = $rty')"
  write_claude_delegate_json_file "$CONFIG_PATH" "$CONFIG_JSON"
  
  STATUS_JSON="$(echo "$STATUS_JSON" | jq \
    --arg schema "2" \
    --arg contract "spawn_agent_child_only" \
    --arg markerName "CODEX_CLAUDE_CHILD_THREAD" \
    --argjson markerVal "true" \
    --arg runId "$RUN_ID" \
    --arg mode "$SESSION_MODE" \
    --arg key "$EFFECTIVE_SESSION_KEY" \
    --arg status "running" \
    --arg initSid "$INITIAL_SESSION_ID" \
    --argjson initRes "${INITIAL_RESUME:-false}" \
    --arg currSid "$CURRENT_SESSION_ID" \
    --argjson currRes "${CURRENT_RESUME:-false}" \
    --arg output "$OUTPUT_PATH" \
    --arg prompt "$PROMPT_PATH" \
    --arg stream "$STREAM_PATH" \
    --arg trace "$TRACE_PATH" \
    --argjson att "$ATTEMPT" \
    --argjson rty "$RETRY_COUNT" \
    '{
      artifactSchema: ($schema | tonumber),
      invocationContract: $contract,
      childThreadMarkerName: $markerName,
      childThreadMarkerValidated: $markerVal,
      runId: $runId,
      sessionMode: $mode,
      sessionKey: $key,
      status: $status,
      initialSessionId: $initSid,
      initialResume: $initRes,
      sessionId: $currSid,
      resume: $currRes,
      outputPath: $output,
      promptPath: $prompt,
      rawStreamPath: $stream,
      tracePath: $trace,
      attemptCount: $att,
      retryCount: $rty,
      lastRetryReason: .lastRetryReason,
      attempts: .attempts
      }')"
  write_claude_delegate_json_file "$STATUS_PATH" "$STATUS_JSON"

  echo "Starting Claude run (Attempt $ATTEMPT/$MAX_ATTEMPTS)"
  echo "=== Running Claude CLI ==="

  # Build args array
  CLAUDE_ARGS=(
    "--verbose"
    "--print"
    "--output-format" "stream-json"
    "--name" "delegate-$RUN_ID"
    "--permission-mode" "acceptEdits"
  )
  if [[ -n "$MODEL" ]]; then
    CLAUDE_ARGS+=("--model" "$MODEL")
  fi
  if [[ "$CURRENT_RESUME" == "true" ]]; then
    CLAUDE_ARGS+=("--resume" "$CURRENT_SESSION_ID")
  else
    CLAUDE_ARGS+=("--session-id" "$CURRENT_SESSION_ID")
  fi
  if [[ -n "$MAX_BUDGET_USD" ]]; then
    CLAUDE_ARGS+=("--max-budget-usd" "$MAX_BUDGET_USD")
  fi
  if [[ "$BYPASS_PERMISSIONS" == "true" ]]; then
    CLAUDE_ARGS+=("--dangerously-skip-permissions")
  fi
  
  CLAUDE_ARGS+=("$PROMPT_TEXT")

  # Global capture state for helpers
  _CAPTURE_ASSISTANT_TEXTS=""
  _CAPTURE_TRACE_LINES=""
  _CAPTURE_FINAL_TEXT=""
  _CAPTURE_SAW_ASSISTANT_TEXT="false"
  _CAPTURE_SAW_RESULT_SUCCESS="false"
  _CAPTURE_CAPTURED_FINAL_RESULT_HEADING="false"
  
  RAW_LINES=""
  
  pushd "$REPO_ROOT" >/dev/null
  echo ""
  
  # Note: Actually streaming in bash while parsing stream-json
  # We read from claude via process substitution or pipe.
  CLAUDE_EXIT_CODE=0
  set +e
  
  exec 3>&1 # Save stdout
  
  # Wait for process and capture
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ -z "${line// /}" ]]; then continue; fi
    RAW_LINES="${RAW_LINES}${line}
"
    
    # Try parsing as JSON
    if echo "$line" | jq empty 2>/dev/null; then
      # Is JSON, append to stream file and process
      echo "$line" >> "$STREAM_PATH"
      update_claude_delegate_stream_capture "$line"
      if [[ -n "$_STREAM_TRACE_LINES" ]]; then
        echo "$_STREAM_TRACE_LINES" >> "$TRACE_PATH"
      fi
    else
      # Not JSON, echo to stdout
      echo "$line" >&3
    fi
  done < <(claude "${CLAUDE_ARGS[@]}" 2>&1 || CLAUDE_EXIT_CODE=$?)
  set -e
  popd >/dev/null
  exec 3>&- # Close fd
  
  # Determine resolution
  get_claude_delegate_output_resolution "$_CAPTURE_FINAL_TEXT" "$OUTPUT_PATH" "$CLAUDE_EXIT_CODE" "$_CAPTURE_SAW_RESULT_SUCCESS" "$_CAPTURE_CAPTURED_FINAL_RESULT_HEADING"
  
  FINAL_TEXT_HAS_FINAL_RESULT="$_RESOLUTION_FINAL_TEXT_HAS_FINAL_RESULT"
  EXISTING_STRUCTURED_OUTPUT="$_RESOLUTION_EXISTING_STRUCTURED_OUTPUT"
  OUTPUT_WAS_NORMALIZED="$_RESOLUTION_OUTPUT_WAS_NORMALIZED"
  PERSISTED_FINAL_TEXT="$_RESOLUTION_PERSISTED_FINAL_TEXT"
  SHOULD_PERSIST_FINAL_TEXT="$_RESOLUTION_SHOULD_PERSIST_FINAL_TEXT"
  DELEGATE_SUCCEEDED="$_RESOLUTION_DELEGATE_SUCCEEDED"

  if [[ "$SHOULD_PERSIST_FINAL_TEXT" == "true" ]]; then
    printf '%s\n' "$PERSISTED_FINAL_TEXT" > "$OUTPUT_PATH"
  fi
  
  # Update attempts array
  STATUS_JSON="$(echo "$STATUS_JSON" | jq \
    --argjson att "$ATTEMPT" \
    --arg sid "$CURRENT_SESSION_ID" \
    --argjson res "${CURRENT_RESUME:-false}" \
    --argjson exit "$CLAUDE_EXIT_CODE" \
    --argjson sawAst "$_CAPTURE_SAW_ASSISTANT_TEXT" \
    --argjson sawRes "$_CAPTURE_SAW_RESULT_SUCCESS" \
    --argjson capFin "$_CAPTURE_CAPTURED_FINAL_RESULT_HEADING" \
    '.attempts += [{
      attempt: $att,
      sessionId: $sid,
      resume: $res,
      retryReason: null,
      exitCode: $exit,
      sawAssistantText: $sawAst,
      sawResultSuccess: $sawRes,
      capturedFinalResult: $capFin
    }]')"

  if [[ "$DELEGATE_SUCCEEDED" == "true" ]]; then
    STATUS_JSON="$(echo "$STATUS_JSON" | jq '.status = "completed" | .exitCode = 0')"
    write_claude_delegate_json_file "$STATUS_PATH" "$STATUS_JSON"
    
    release_claude_session_lease "$SESSION_STATE_PATH" "$SESSION_LOCK_PATH" "$SAFE_SESSION_KEY" \
      "$_LEASE_MODE" "$CURRENT_SESSION_ID" "$RUN_ID" "$TASK_FINGERPRINT" "$_LEASE_LEASED"
    
    echo "=== Delegate Succeeded ==="
    exit 0
  fi
  
  # Failure analysis & Retry
  get_claude_delegate_retry_decision "$RAW_LINES" "$CURRENT_RESUME" "$CLAUDE_EXIT_CODE" "$_CAPTURE_SAW_ASSISTANT_TEXT" "$_CAPTURE_SAW_RESULT_SUCCESS" "$_CAPTURE_CAPTURED_FINAL_RESULT_HEADING"
  
  RETRY_SHOULD_RETRY="$_RETRY_SHOULD_RETRY"
  RETRY_REASON="$_RETRY_REASON"
  RETRY_WITH_FRESH_SESSION="$_RETRY_WITH_FRESH_SESSION"

  # Update the current attempt's retryReason
  STATUS_JSON="$(echo "$STATUS_JSON" | jq \
    --argjson idx "$((ATTEMPT - 1))" \
    --arg reason "$RETRY_REASON" \
    '.attempts[$idx].retryReason = ($reason | if . == "" then null else . end)')"

  if [[ "$IS_FINAL_ATTEMPT" == "true" || "$RETRY_SHOULD_RETRY" == "false" || $RETRY_COUNT -ge $MAX_RETRIES ]]; then
    get_claude_delegate_failure_summary "$RAW_LINES" "$RETRY_REASON" "$ATTEMPT" "$MAX_RETRIES" "$CLAUDE_EXIT_CODE"
    
    STATUS_JSON="$(echo "$STATUS_JSON" | jq --argjson exit "$CLAUDE_EXIT_CODE" '.status = "failed" | .exitCode = $exit')"
    write_claude_delegate_json_file "$STATUS_PATH" "$STATUS_JSON"
    
    release_claude_session_lease "$SESSION_STATE_PATH" "$SESSION_LOCK_PATH" "$SAFE_SESSION_KEY" \
      "$_LEASE_MODE" "$CURRENT_SESSION_ID" "$RUN_ID" "$TASK_FINGERPRINT" "$_LEASE_LEASED"
      
    exit 1
  fi
  
  # Prepare for next attempt
  echo "WARNING: Run failed ($RETRY_REASON). Retrying..."
  ATTEMPT=$((ATTEMPT + 1))
  RETRY_COUNT=$((RETRY_COUNT + 1))
  LAST_RETRY_REASON="$RETRY_REASON"
  
  STATUS_JSON="$(echo "$STATUS_JSON" | jq --arg reason "$LAST_RETRY_REASON" '.lastRetryReason = $reason')"
  
  if [[ "$RETRY_WITH_FRESH_SESSION" == "true" ]]; then
    reset_claude_session_lease_for_fresh_session "$SESSION_STATE_PATH" "$SESSION_LOCK_PATH" "$SAFE_SESSION_KEY" \
      "$_LEASE_MODE" "$CURRENT_SESSION_ID" "$RUN_ID" "$TASK_FINGERPRINT" "$LAST_RETRY_REASON"
    
    CURRENT_SESSION_ID="$_LEASE_SESSION_ID"
    CURRENT_RESUME="$_LEASE_RESUME"
  fi
  
done

# We shouldn't reach here due to the final attempt check above
exit 1
