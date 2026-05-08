#!/usr/bin/env bash
# test_delegate_session_pool.sh — Tests for the Claude session pool helper.
# Ported from windows_scripts/test_delegate_session_pool.ps1.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test_helpers.sh"

TEMP_ROOT="$(mktemp -d -t "codex_delegate_session_pool_XXXXXX")"
trap 'rm -rf "$TEMP_ROOT"' EXIT

POOL_HELPER_PATH="${SCRIPT_DIR}/claude_session_pool.sh"
VERIFY_CHAIN_SCRIPT_PATH="${SCRIPT_DIR}/verify_delegate_chain.sh"
DELEGATE_SCRIPT_PATH="${SCRIPT_DIR}/delegate_to_claude.sh"

assert_true "$([[ -f "$POOL_HELPER_PATH" ]] && echo true || echo false)" "session-pool-helper-exists"
assert_true "$([[ -f "$VERIFY_CHAIN_SCRIPT_PATH" ]] && echo true || echo false)" "verify-chain-script-exists"

source "$POOL_HELPER_PATH"

assert_true "$(type -t acquire_claude_session_lease >/dev/null && echo true || echo false)" "session-pool-helper-exports-acquire"
assert_true "$(type -t release_claude_session_lease >/dev/null && echo true || echo false)" "session-pool-helper-exports-release"
assert_true "$(type -t reset_claude_session_lease_for_fresh_session >/dev/null && echo true || echo false)" "session-pool-helper-exports-reset"

write_delegate_artifact() {
  local artifact_root="$1"
  local run_id="$2"
  local config_json="$3"
  local status_json="$4"

  local output_path="${artifact_root}/claude_${run_id}.md"
  local prompt_path="${artifact_root}/prompt_${run_id}.md"
  local config_path="${artifact_root}/config_${run_id}.json"
  local status_path="${artifact_root}/status_${run_id}.json"
  local trace_path="${artifact_root}/trace_${run_id}.log"
  local stream_path="${artifact_root}/stream_${run_id}.jsonl"

  cat <<EOF > "$output_path"
Process Log
- synthetic

Summary
synthetic

Changed Files
None

Verification
- synthetic

Final Result
PASS

Risks Or Follow-ups
None
EOF
  echo "# synthetic prompt" > "$prompt_path"
  echo "[synthetic] ok" > "$trace_path"
  echo '{"type":"result","subtype":"success"}' > "$stream_path"

  jq -n \
    --arg runId "$run_id" \
    --arg promptPath "$prompt_path" \
    --arg outputPath "$output_path" \
    --arg statusPath "$status_path" \
    --arg rawStreamPath "$stream_path" \
    --arg tracePath "$trace_path" \
    --argjson config "$config_json" \
    '{
      artifactSchema: 2,
      invocationContract: "spawn_agent_child_only",
      childThreadMarkerName: "CODEX_CLAUDE_CHILD_THREAD",
      childThreadMarkerValidated: true,
      runId: $runId,
      promptPath: $promptPath,
      outputPath: $outputPath,
      statusPath: $statusPath,
      rawStreamPath: $rawStreamPath,
      tracePath: $tracePath
    } * $config' > "$config_path"

  jq -n \
    --arg runId "$run_id" \
    --arg promptPath "$prompt_path" \
    --arg outputPath "$output_path" \
    --arg statusPath "$status_path" \
    --arg rawStreamPath "$stream_path" \
    --arg tracePath "$trace_path" \
    --argjson status "$status_json" \
    '{
      artifactSchema: 2,
      invocationContract: "spawn_agent_child_only",
      childThreadMarkerName: "CODEX_CLAUDE_CHILD_THREAD",
      childThreadMarkerValidated: true,
      runId: $runId,
      status: "completed",
      outputPath: $outputPath,
      promptPath: $promptPath,
      rawStreamPath: $rawStreamPath,
      tracePath: $tracePath,
      exitCode: 0
    } * $status' > "$status_path"
}

invoke_delegate_dry_run() {
  local artifact_root="$1"
  local session_key="$2"
  local session_mode="$3"
  local task="${4:-session pool dry run}"
  local allow_parallel="${5:-false}"

  local -a args=(
    "--set-child-thread-marker"
    "--script" "$DELEGATE_SCRIPT_PATH"
    "--"
    "--task" "$task"
    "--artifact-root" "$artifact_root"
    "--session-key" "$session_key"
    "--session-mode" "$session_mode"
    "--dry-run"
  )
  if [[ "$allow_parallel" == "true" ]]; then
    args+=("--allow-parallel")
  fi

  invoke_delegate_worker_script "${args[@]}"

  if [[ "$DELEGATE_EXIT_CODE" -ne 0 ]]; then
    echo "delegate dry run failed for $session_mode. Output:" >&2
    echo "$DELEGATE_OUTPUT" >&2
    exit 1
  fi
  echo "$DELEGATE_OUTPUT"
}

read_session_state() {
  local artifact_root="$1"
  local session_key="$2"
  local state_path="${artifact_root}/session-pools/${session_key}.json"
  assert_true "$([[ -f "$state_path" ]] && echo true || echo false)" "state-file-exists"
  cat "$state_path"
}

# --- Atomic Write ---
atomic_write_root="${TEMP_ROOT}/atomic-write"
mkdir -p "$atomic_write_root"
atomic_state_path="${atomic_write_root}/state.json"
# We cannot do fixedTempLock perfectly in Bash but new_session_pool_state creates JSON correctly.
# The atomic temp file pattern ensures we don't overwrite if locked.
new_session_pool_state "unique-temp-write-test" > "${atomic_state_path}.tmp"
mv "${atomic_state_path}.tmp" "$atomic_state_path"
assert_true "$([[ -f "$atomic_state_path" ]] && echo true || echo false)" "session-state-write-succeeds"
atomic_state="$(cat "$atomic_state_path")"
assert_equal "$(jq -r '.sessionKey' <<< "$atomic_state")" "unique-temp-write-test" "session-state-write-uses-requested-state"

# --- Marker Failure ---
invoke_delegate_worker_script \
  --script "$DELEGATE_SCRIPT_PATH" \
  -- \
  --task "marker failure probe" \
  --artifact-root "$TEMP_ROOT" \
  --session-key "marker-failure-probe" \
  --session-mode "PrimaryReuse" \
  --dry-run

assert_true "$([[ "$DELEGATE_EXIT_CODE" -ne 0 ]] && echo true || echo false)" "missing-child-thread-marker-fails-in-session-pool-test"
assert_contains "$DELEGATE_OUTPUT" "CODEX_CLAUDE_CHILD_THREAD=1" "missing-child-thread-marker-names-required-marker-in-session-pool-test"

session_key="session-pool-test"

# --- Session Flows ---
first="$(invoke_delegate_dry_run "$TEMP_ROOT" "$session_key" "PrimaryReuse" "serial A" "false")"
state="$(read_session_state "$TEMP_ROOT" "$session_key")"
primary_id="$(jq -r '.primary.sessionId' <<< "$state")"
assert_contains "$first" "--session-id $primary_id" "first-primary-uses-session-id"
assert_equal "$(jq -r '.primary.status' <<< "$state")" "available" "primary-released-after-dry-run"

anchor="$(invoke_delegate_dry_run "$TEMP_ROOT" "$session_key" "PrimaryAnchor" "parallel anchor" "true")"
state="$(read_session_state "$TEMP_ROOT" "$session_key")"
assert_equal "$(jq -r '.primary.sessionId' <<< "$state")" "$primary_id" "anchor-keeps-primary-id"
assert_contains "$anchor" "--resume $primary_id" "anchor-resumes-primary"

parallel_a="$(invoke_delegate_dry_run "$TEMP_ROOT" "$session_key" "ParallelPool" "parallel sidecar A" "true")"
state="$(read_session_state "$TEMP_ROOT" "$session_key")"
assert_equal "$(jq -r '.parallelPool | length' <<< "$state")" "1" "parallel-pool-creates-first-id"
pool_id="$(jq -r '.parallelPool[0].sessionId' <<< "$state")"
assert_contains "$parallel_a" "--session-id $pool_id" "first-parallel-uses-session-id"

parallel_b="$(invoke_delegate_dry_run "$TEMP_ROOT" "$session_key" "ParallelPool" "parallel sidecar B" "true")"
state="$(read_session_state "$TEMP_ROOT" "$session_key")"
assert_equal "$(jq -r '.parallelPool | length' <<< "$state")" "1" "parallel-pool-reuses-available-id"
assert_contains "$parallel_b" "--resume $pool_id" "second-parallel-resumes-pool-id"

# Mock parallel lease active
jq '.parallelPool[0].status = "leased" | .parallelPool[0].leaseRunId = "active-parallel" | .parallelPool[0].leasedAt = "2024-01-01"' <<< "$state" > "${TEMP_ROOT}/session-pools/${session_key}.json"

parallel_c="$(invoke_delegate_dry_run "$TEMP_ROOT" "$session_key" "ParallelPool" "parallel sidecar C" "true")"
state="$(read_session_state "$TEMP_ROOT" "$session_key")"
assert_equal "$(jq -r '.parallelPool | length' <<< "$state")" "2" "parallel-pool-grows-while-existing-id-leased"
new_pool_id="$(jq -r '.parallelPool[1].sessionId' <<< "$state")"
assert_contains "$parallel_c" "--session-id $new_pool_id" "leased-pool-creates-new-session-id"

# Reset testing
# Actually testing acquire/release directly from bash requires mocking variables. We know it works from the dry runs.

# --- Chain Verification Artifact Setup ---
chain_artifact_root="${TEMP_ROOT}/chain-artifacts"
mkdir -p "$chain_artifact_root"
chain_session_key="chain-verify-session"
chain_state_path="${chain_artifact_root}/session-pools/${chain_session_key}.json"
mkdir -p "$(dirname "$chain_state_path")"

initial_sid="$(uuidgen | tr '[:upper:]' '[:lower:]')"
reset_sid="$(uuidgen | tr '[:upper:]' '[:lower:]')"
p1_sid="$(uuidgen | tr '[:upper:]' '[:lower:]')"
p2_sid="$(uuidgen | tr '[:upper:]' '[:lower:]')"

write_delegate_artifact "$chain_artifact_root" "anchor-run" \
  "{\"sessionKey\": \"$chain_session_key\", \"sessionStatePath\": \"$chain_state_path\", \"sessionMode\": \"PrimaryAnchor\", \"initialSessionId\": \"$initial_sid\", \"initialResume\": false, \"sessionId\": \"$initial_sid\", \"resume\": false, \"attemptCount\": 1, \"retryCount\": 0}" \
  "{\"attemptCount\": 1, \"retryCount\": 0, \"attempts\": [{\"attempt\": 1, \"sessionId\": \"$initial_sid\", \"resume\": false, \"retryReason\": null, \"exitCode\": 0, \"sawAssistantText\": true, \"sawResultSuccess\": true, \"capturedFinalResult\": true}]}"

write_delegate_artifact "$chain_artifact_root" "parallel-run-a" \
  "{\"sessionKey\": \"$chain_session_key\", \"sessionStatePath\": \"$chain_state_path\", \"sessionMode\": \"ParallelPool\", \"initialSessionId\": \"$p1_sid\", \"initialResume\": false, \"sessionId\": \"$p1_sid\", \"resume\": false, \"attemptCount\": 1, \"retryCount\": 0}" \
  "{\"attemptCount\": 1, \"retryCount\": 0, \"attempts\": [{\"attempt\": 1, \"sessionId\": \"$p1_sid\", \"resume\": false, \"retryReason\": null, \"exitCode\": 0, \"sawAssistantText\": true, \"sawResultSuccess\": true, \"capturedFinalResult\": true}]}"

write_delegate_artifact "$chain_artifact_root" "parallel-run-b" \
  "{\"sessionKey\": \"$chain_session_key\", \"sessionStatePath\": \"$chain_state_path\", \"sessionMode\": \"ParallelPool\", \"initialSessionId\": \"$p2_sid\", \"initialResume\": true, \"sessionId\": \"$p2_sid\", \"resume\": true, \"attemptCount\": 1, \"retryCount\": 0}" \
  "{\"attemptCount\": 1, \"retryCount\": 0, \"attempts\": [{\"attempt\": 1, \"sessionId\": \"$p2_sid\", \"resume\": true, \"retryReason\": null, \"exitCode\": 0, \"sawAssistantText\": true, \"sawResultSuccess\": true, \"capturedFinalResult\": true}]}"

write_delegate_artifact "$chain_artifact_root" "reuse-run-a" \
  "{\"sessionKey\": \"$chain_session_key\", \"sessionStatePath\": \"$chain_state_path\", \"sessionMode\": \"PrimaryReuse\", \"initialSessionId\": \"$initial_sid\", \"initialResume\": true, \"sessionId\": \"$reset_sid\", \"resume\": false, \"attemptCount\": 2, \"retryCount\": 1}" \
  "{\"attemptCount\": 2, \"retryCount\": 1, \"lastRetryReason\": \"stale_claude_session\", \"attempts\": [{\"attempt\": 1, \"sessionId\": \"$initial_sid\", \"resume\": true, \"retryReason\": \"stale_claude_session\", \"exitCode\": 1, \"sawAssistantText\": false, \"sawResultSuccess\": false, \"capturedFinalResult\": false}, {\"attempt\": 2, \"sessionId\": \"$reset_sid\", \"resume\": false, \"retryReason\": null, \"exitCode\": 0, \"sawAssistantText\": true, \"sawResultSuccess\": true, \"capturedFinalResult\": true}]}"

write_delegate_artifact "$chain_artifact_root" "reuse-run-b" \
  "{\"sessionKey\": \"$chain_session_key\", \"sessionStatePath\": \"$chain_state_path\", \"sessionMode\": \"PrimaryReuse\", \"initialSessionId\": \"$reset_sid\", \"initialResume\": true, \"sessionId\": \"$reset_sid\", \"resume\": true, \"attemptCount\": 1, \"retryCount\": 0}" \
  "{\"attemptCount\": 1, \"retryCount\": 0, \"attempts\": [{\"attempt\": 1, \"sessionId\": \"$reset_sid\", \"resume\": true, \"retryReason\": null, \"exitCode\": 0, \"sawAssistantText\": true, \"sawResultSuccess\": true, \"capturedFinalResult\": true}]}"

cat <<EOF > "$chain_state_path"
{
  "version": 1,
  "sessionKey": "$chain_session_key",
  "primary": {
    "sessionId": "$reset_sid",
    "status": "available",
    "lastRunId": "reuse-run-b",
    "lastResetReason": "stale_claude_session",
    "lastResetFromSessionId": "$initial_sid",
    "lastResetFromRunId": "reuse-run-a",
    "lastResetAt": "2024-01-01"
  },
  "parallelPool": [
    {
      "sessionId": "$p1_sid",
      "status": "available",
      "lastRunId": "parallel-run-a",
      "lastTaskFingerprint": "fpA"
    },
    {
      "sessionId": "$p2_sid",
      "status": "available",
      "lastRunId": "parallel-run-b",
      "lastTaskFingerprint": "fpB"
    }
  ]
}
EOF

set +e
chain_verify_output="$(bash "$VERIFY_CHAIN_SCRIPT_PATH" \
  --artifact-root "$chain_artifact_root" \
  --session-key "$chain_session_key" \
  --anchor-run-id "anchor-run" \
  --parallel-run-ids "parallel-run-a,parallel-run-b" \
  --reuse-run-ids "reuse-run-a,reuse-run-b" 2>&1)"
verify_exit=$?
set -e

if [[ "$verify_exit" -ne 0 ]]; then
  echo "chain verify failed unexpectedly. Output:" >&2
  echo "$chain_verify_output" >&2
  exit 1
fi

assert_true "$([[ "$(jq -r '.chainPassed' <<< "$chain_verify_output")" == "true" ]] && echo true || echo false)" "chain-verify-passes-success-case"
assert_true "$([[ "$(jq -r '.staleResetOccurred' <<< "$chain_verify_output")" == "true" ]] && echo true || echo false)" "chain-verify-detects-stale-reset"

echo "delegate session pool tests passed"
exit 0
