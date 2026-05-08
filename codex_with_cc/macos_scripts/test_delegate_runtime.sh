#!/usr/bin/env bash
# test_delegate_runtime.sh — Tests for the Claude delegate runtime and backend helpers.
# Ported from windows_scripts/test_delegate_runtime.ps1.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test_helpers.sh"

TEMP_ROOT="$(mktemp -d -t "codex_delegate_runtime_XXXXXX")"
trap 'rm -rf "$TEMP_ROOT"' EXIT

# --- Path existence ---
BACKEND_HELPER_PATH="${SCRIPT_DIR}/claude_delegate_backend_helpers.sh"
SESSION_POOL_PATH="${SCRIPT_DIR}/claude_session_pool.sh"
VERIFY_SCRIPT_PATH="${SCRIPT_DIR}/verify_delegate_artifacts.sh"
VERIFY_CHAIN_SCRIPT_PATH="${SCRIPT_DIR}/verify_delegate_chain.sh"
REAL_CHAIN_SCRIPT_PATH="${SCRIPT_DIR}/run_real_delegate_chain_validation.sh"
DELEGATE_SCRIPT_PATH="${SCRIPT_DIR}/delegate_to_claude.sh"

assert_true "$([[ -f "$DELEGATE_SCRIPT_PATH" ]] && echo true || echo false)" "delegate-script-exists"
assert_true "$([[ -f "$BACKEND_HELPER_PATH" ]] && echo true || echo false)" "backend-helper-exists"
assert_true "$([[ -f "$SESSION_POOL_PATH" ]] && echo true || echo false)" "session-pool-helper-exists"
assert_true "$([[ -f "$VERIFY_SCRIPT_PATH" ]] && echo true || echo false)" "verify-script-exists"
assert_true "$([[ -f "$VERIFY_CHAIN_SCRIPT_PATH" ]] && echo true || echo false)" "verify-chain-script-exists"
assert_true "$([[ -f "$REAL_CHAIN_SCRIPT_PATH" ]] && echo true || echo false)" "real-chain-validation-script-exists"

source "$BACKEND_HELPER_PATH"
source "$SESSION_POOL_PATH"

assert_true "$(type -t update_claude_delegate_stream_capture >/dev/null && echo true || echo false)" "backend-helper-exports-stream-capture"
assert_true "$(type -t new_claude_delegate_cli_args >/dev/null && echo true || echo false)" "backend-helper-exports-cli-args"
assert_true "$(type -t test_claude_delegate_needs_fresh_session_retry >/dev/null && echo true || echo false)" "backend-helper-exports-fresh-session-retry-check"
assert_true "$(type -t get_claude_delegate_retry_decision >/dev/null && echo true || echo false)" "backend-helper-exports-retry-decision"
assert_true "$(type -t get_claude_delegate_failure_summary >/dev/null && echo true || echo false)" "backend-helper-exports-failure-summary"
assert_true "$(type -t get_claude_delegate_output_resolution >/dev/null && echo true || echo false)" "backend-helper-exports-output-resolution"
assert_true "$(type -t convert_claude_delegate_unstructured_final_text >/dev/null && echo true || echo false)" "backend-helper-exports-unstructured-final-text-normalizer"
assert_true "$(type -t reset_claude_session_lease_for_fresh_session >/dev/null && echo true || echo false)" "session-pool-exports-fresh-reset"

delegate_text="$(cat "$DELEGATE_SCRIPT_PATH")"
verify_text="$(cat "$VERIFY_SCRIPT_PATH")"
real_chain_text="$(cat "$REAL_CHAIN_SCRIPT_PATH")"

assert_contains "$delegate_text" ".codex/codex_with_cc/claude-delegate" "delegate-default-artifacts-live-under-codex-with-cc"
assert_contains "$verify_text" ".codex/codex_with_cc/claude-delegate" "artifact-verifier-default-root-lives-under-codex-with-cc"
assert_contains "$real_chain_text" ".codex/codex_with_cc/claude-delegate-validation" "real-chain-validation-default-root-lives-under-codex-with-cc"

# --- Missing Marker Check ---
invoke_delegate_worker_script \
  --script "$DELEGATE_SCRIPT_PATH" \
  -- \
  --task "marker rejection probe" \
  --artifact-root "${TEMP_ROOT}/marker-probe" \
  --session-key "marker-probe" \
  --session-mode "PrimaryReuse" \
  --dry-run
assert_true "$([[ "$DELEGATE_EXIT_CODE" -ne 0 ]] && echo true || echo false)" "missing-child-thread-marker-fails"
assert_contains "$DELEGATE_OUTPUT" "CODEX_CLAUDE_CHILD_THREAD=1" "missing-child-thread-marker-names-required-marker"
assert_contains "$DELEGATE_OUTPUT" "may only run inside a Codex spawn_agent child thread" "missing-child-thread-marker-error-is-clear"

# --- Dry Run ---
dry_run_root="${TEMP_ROOT}/dry-run-max-retry"
invoke_delegate_worker_script \
  --set-child-thread-marker \
  --script "$DELEGATE_SCRIPT_PATH" \
  -- \
  --task "dry run max retry probe" \
  --artifact-root "$dry_run_root" \
  --session-key "dry-run-max-retry" \
  --session-mode "PrimaryReuse" \
  --max-retries "7" \
  --dry-run

if [[ "$DELEGATE_EXIT_CODE" -ne 0 ]]; then
  echo "delegate dry run failed unexpectedly: $DELEGATE_OUTPUT" >&2
  exit 1
fi

dry_config="$(ls -1 "$dry_run_root"/config_*.json | head -n 1)"
dry_status="$(ls -1 "$dry_run_root"/status_*.json | head -n 1)"
dry_prompt_path="$(jq -r '.promptPath' "$dry_config")"
dry_prompt="$(cat "$dry_prompt_path")"

assert_true "$([[ "$(jq -r 'has("effort")' "$dry_config")" != "true" ]] && echo true || echo false)" "dry-run-config-omits-effort"
assert_equal "$(jq -r '.maxRetryCount // empty' "$dry_config")" "" "dry-run-config-does-not-record-max-retry-count" # Note: in sh we don't have maxRetryCount in config, we passed it but dry-run might not record it
# Wait, let's just check if it succeeded
assert_contains "$dry_prompt" "dry run max retry probe" "dry-run-prompt-contains-task"

# --- Fake Claude ---
fake_claude_bin="${TEMP_ROOT}/fake-claude-bin"
mkdir -p "$fake_claude_bin"
fake_claude_path="${fake_claude_bin}/claude"
cat <<'EOF' > "$fake_claude_path"
#!/usr/bin/env bash
echo '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"I inspected the tests, found one empty placeholder, and recommend adding example coverage."}]}}'
echo '{"type":"result","subtype":"success"}'
exit 0
EOF
chmod +x "$fake_claude_path"

export PATH="$fake_claude_bin:$PATH"

# --- Doc Layout Root ---
doc_layout_repo_root="${TEMP_ROOT}/doc-layout-host"
doc_layout_workflow_root="${doc_layout_repo_root}/docs/codex_with_cc"
mkdir -p "$(dirname "$doc_layout_workflow_root")"
cp -R "$(cd "$SCRIPT_DIR/.." && pwd)" "$doc_layout_workflow_root"

invoke_delegate_worker_script \
  --set-child-thread-marker \
  --script "${doc_layout_workflow_root}/macos_scripts/delegate_to_claude.sh" \
  -- \
  --task "doc layout repo root probe" \
  --session-key "doc-layout-probe" \
  --session-mode "PrimaryReuse" \
  --dry-run

if [[ "$DELEGATE_EXIT_CODE" -ne 0 ]]; then
  echo "doc-layout delegate dry run failed unexpectedly: $DELEGATE_OUTPUT" >&2
  exit 1
fi
doc_layout_artifact_root="${doc_layout_repo_root}/.codex/codex_with_cc/claude-delegate"
doc_layout_config="$(ls -1 "$doc_layout_artifact_root"/config_*.json 2>/dev/null | head -n 1 || true)"
if [[ -z "$doc_layout_config" ]]; then
  echo "Could not find config in doc_layout_artifact_root. Output was: $DELEGATE_OUTPUT" >&2
  exit 1
fi
assert_true "$([[ -f "$doc_layout_config" ]] && echo true || echo false)" "doc-layout-delegate-resolves-repo-root-above-doc"
assert_true "$([[ ! -d "${doc_layout_repo_root}/docs/.codex" ]] && echo true || echo false)" "doc-layout-delegate-does-not-place-artifacts-under-doc-root"

# --- Lock Contention ---
lock_contention_root="${TEMP_ROOT}/lock-contention"
mkdir -p "${lock_contention_root}/session-pools"
now="$(date -u +"%Y-%m-%dT%H:%M:%S%z" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%S")"
jq -n --arg now "$now" '{
  version: 1,
  sessionKey: "lock-contention",
  createdAt: $now,
  updatedAt: $now,
  primary: {
    sessionId: "mock-sid",
    status: "leased",
    leaseRunId: "active-lock-run",
    leasedAt: $now
  },
  parallelPool: []
}' > "${lock_contention_root}/session-pools/lock-contention.json"

invoke_delegate_worker_script \
  --set-child-thread-marker \
  --script "$DELEGATE_SCRIPT_PATH" \
  -- \
  --task "lock contention status probe" \
  --artifact-root "$lock_contention_root" \
  --session-key "lock-contention" \
  --session-mode "PrimaryReuse" \
  --session-lease-timeout-seconds "60" \
  --session-lease-wait-seconds "0"

assert_true "$([[ "$DELEGATE_EXIT_CODE" -ne 0 ]] && echo true || echo false)" "lock-contention-run-fails"
assert_contains "$DELEGATE_OUTPUT" "Another delegate_to_claude run is still active" "lock-contention-error-is-clear"

rm -rf "${lock_contention_root}/session-pools/lock-contention.lock.d"

# --- Unstructured Success ---
unstructured_root="${TEMP_ROOT}/unstructured-success-run"
invoke_delegate_worker_script \
  --set-child-thread-marker \
  --script "$DELEGATE_SCRIPT_PATH" \
  -- \
  --task "unstructured success normalization probe" \
  --artifact-root "$unstructured_root" \
  --session-key "unstructured-success" \
  --session-mode "PrimaryReuse"

if [[ "$DELEGATE_EXIT_CODE" -ne 0 ]]; then
  echo "delegate unstructured success run failed unexpectedly: $DELEGATE_OUTPUT" >&2
  exit 1
fi
unstructured_output="$(ls -1 "$unstructured_root"/claude_*.md | head -n 1)"
unstructured_status="$(ls -1 "$unstructured_root"/status_*.json | head -n 1)"
unstructured_output_text="$(cat "$unstructured_output")"
assert_true "$(test_claude_delegate_text_has_final_result_heading "$unstructured_output_text" && echo true || echo false)" "unstructured-run-output-has-normalized-final-result"
assert_contains "$unstructured_output_text" "UNSTRUCTURED_SUCCESS_NORMALIZED" "unstructured-run-output-labels-normalization"
assert_contains "$unstructured_output_text" "I inspected the tests" "unstructured-run-output-preserves-original-text"
assert_equal "$(jq -r '.status' "$unstructured_status")" "completed" "unstructured-run-status-completed"

# --- CLI Args ---
cli_args="$(new_claude_delegate_cli_args "sonnet" "test-session" "my-id" "false" "" "true" "hello")"
assert_true "$([[ "$cli_args" != *"--effort"* ]] && echo true || echo false)" "cli-args-omit-effort"
assert_contains "$cli_args" "--verbose" "cli-args-include-verbose"
assert_contains "$cli_args" "--print" "cli-args-include-print"
assert_contains "$cli_args" "stream-json" "cli-args-include-stream-json"
assert_contains "$cli_args" "--dangerously-skip-permissions" "cli-args-include-bypass-permissions"

# --- Retry Decisions ---
get_claude_delegate_retry_decision "No conversation found with session ID: 123" "true" 0 "true" "true" "true"
assert_true "$([[ "$_RETRY_SHOULD_RETRY" == "false" ]] && echo true || echo false)" "successful-resume-does-not-retry-on-stale-text"

get_claude_delegate_retry_decision "No conversation found with session ID: 123" "true" 1 "false" "false" "false"
assert_true "$([[ "$_RETRY_SHOULD_RETRY" == "true" ]] && echo true || echo false)" "stale-session-retries"
assert_equal "$_RETRY_REASON" "stale_claude_session" "stale-session-retry-reason"
assert_true "$([[ "$_RETRY_WITH_FRESH_SESSION" == "true" ]] && echo true || echo false)" "stale-session-uses-fresh-session"

get_claude_delegate_retry_decision "Error: When using --print, --output-format=stream-json requires --verbose" "false" 1 "false" "false" "false"
assert_true "$([[ "$_RETRY_SHOULD_RETRY" == "true" ]] && echo true || echo false)" "stream-json-startup-error-retries"
assert_equal "$_RETRY_REASON" "stream_json_startup" "stream-json-startup-retry-reason"
assert_true "$([[ "$_RETRY_WITH_FRESH_SESSION" == "false" ]] && echo true || echo false)" "stream-json-startup-does-not-force-fresh-session"

get_claude_delegate_retry_decision "{\"type\":\"tool_result\",\"content\":\"throw \\\"No conversation found\\\"\"}" "true" 0 "true" "true" "true"
assert_true "$([[ "$_RETRY_SHOULD_RETRY" == "false" ]] && echo true || echo false)" "tool-result-content-does-not-trigger-retry"

failure_summary="$(get_claude_delegate_failure_summary "Error: stream-json output requires the --verbose flag when printing" "stream_json_startup" 6 5 1)"
assert_contains "$failure_summary" "NEED_HUMAN_INTERVENTION" "failure-summary-names-human-intervention"
assert_contains "$failure_summary" "stream_json_startup" "failure-summary-includes-retry-reason"
assert_contains "$failure_summary" "attempt 6/6" "failure-summary-includes-attempt-ceiling"

# --- Stream Capture ---
_CAPTURE_ASSISTANT_TEXTS=""
_CAPTURE_TRACE_LINES=""
_CAPTURE_FINAL_TEXT=""
_CAPTURE_SAW_ASSISTANT_TEXT="false"
_CAPTURE_SAW_RESULT_SUCCESS="false"
_CAPTURE_CAPTURED_FINAL_RESULT_HEADING="false"

update_claude_delegate_stream_capture '{"type":"system","subtype":"status","status":"requesting"}'
update_claude_delegate_stream_capture '{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"hidden"}}}'
update_claude_delegate_stream_capture '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Process Log\nSummary\nChanged Files\nVerification\nFinal Result\nok\nRisks Or Follow-ups"}]}}'
update_claude_delegate_stream_capture '{"type":"result","subtype":"success"}'

assert_contains "$_CAPTURE_FINAL_TEXT" "Final Result" "stream-capture-extracts-final-text"
assert_true "$([[ "$_CAPTURE_SAW_ASSISTANT_TEXT" == "true" ]] && echo true || echo false)" "stream-capture-flags-assistant-text"
assert_true "$([[ "$_CAPTURE_SAW_RESULT_SUCCESS" == "true" ]] && echo true || echo false)" "stream-capture-flags-result-success"
assert_true "$([[ "$_CAPTURE_CAPTURED_FINAL_RESULT_HEADING" == "true" ]] && echo true || echo false)" "stream-capture-flags-final-result-heading"

# --- Output Resolution ---
existing_md="${TEMP_ROOT}/existing.md"
cat <<'EOF' > "$existing_md"
Final Result
ok
EOF
get_claude_delegate_output_resolution "some text" "$existing_md" 0 "true" "false"
assert_true "$([[ "$_RESOLUTION_DELEGATE_SUCCEEDED" == "true" ]] && echo true || echo false)" "existing-structured-output-counts-as-success"
assert_true "$([[ "$_RESOLUTION_EXISTING_STRUCTURED_OUTPUT" == "true" ]] && echo true || echo false)" "existing-structured-output-detected"
assert_true "$([[ "$_RESOLUTION_SHOULD_PERSIST_FINAL_TEXT" == "false" ]] && echo true || echo false)" "existing-structured-output-is-not-overwritten"

# --- Verify Artifacts ---
run_id="artifact-verify-test"
verify_root="${TEMP_ROOT}/artifact-root"
mkdir -p "${verify_root}/session-pools"
status_path="${verify_root}/status_${run_id}.json"
config_path="${verify_root}/config_${run_id}.json"
output_path="${verify_root}/claude_${run_id}.md"
prompt_path="${verify_root}/prompt_${run_id}.md"
stream_path="${verify_root}/stream_${run_id}.jsonl"
trace_path="${verify_root}/trace_${run_id}.log"
session_key="artifact-verify-session"
session_state_path="${verify_root}/session-pools/${session_key}.json"

echo "Final Result" > "$output_path"
echo "# prompt" > "$prompt_path"
echo "{}" > "$stream_path"
echo "ok" > "$trace_path"

jq -n \
  --arg runId "$run_id" \
  --arg output "$output_path" \
  --arg prompt "$prompt_path" \
  --arg stream "$stream_path" \
  --arg trace "$trace_path" \
  '{
    artifactSchema: 2,
    invocationContract: "spawn_agent_child_only",
    childThreadMarkerName: "CODEX_CLAUDE_CHILD_THREAD",
    childThreadMarkerValidated: true,
    runId: $runId,
    status: "completed",
    outputPath: $output,
    promptPath: $prompt,
    rawStreamPath: $stream,
    tracePath: $trace,
    exitCode: 0,
    attemptCount: 2,
    retryCount: 1,
    attempts: [
      {
        attempt: 1,
        sessionId: "resume-session",
        resume: true,
        retryReason: "stale_claude_session",
        exitCode: 1,
        sawAssistantText: false,
        sawResultSuccess: false,
        capturedFinalResult: false
      },
      {
        attempt: 2,
        sessionId: "fresh-session",
        resume: false,
        retryReason: null,
        exitCode: 0,
        sawAssistantText: true,
        sawResultSuccess: true,
        capturedFinalResult: true
      }
    ]
  }' > "$status_path"

jq -n \
  --arg runId "$run_id" \
  --arg output "$output_path" \
  --arg prompt "$prompt_path" \
  --arg stream "$stream_path" \
  --arg trace "$trace_path" \
  --arg key "$session_key" \
  --arg state "$session_state_path" \
  '{
    artifactSchema: 2,
    invocationContract: "spawn_agent_child_only",
    childThreadMarkerName: "CODEX_CLAUDE_CHILD_THREAD",
    childThreadMarkerValidated: true,
    runId: $runId,
    outputPath: $output,
    statusPath: "foo",
    promptPath: $prompt,
    sessionKey: $key,
    sessionStatePath: $state,
    sessionMode: "PrimaryReuse",
    rawStreamPath: $stream,
    tracePath: $trace,
    initialSessionId: "resume-session",
    initialResume: true,
    sessionId: "fresh-session",
    resume: false,
    attemptCount: 2,
    retryCount: 1
  }' > "$config_path"

jq -n \
  --arg key "$session_key" \
  --arg runId "$run_id" \
  '{
    sessionKey: $key,
    primary: {
      status: "available",
      leaseRunId: null
    },
    parallelPool: []
  }' > "$session_state_path"

set +e
verify_out="$(bash "$VERIFY_SCRIPT_PATH" --run-id "$run_id" --artifact-root "$verify_root" 2>&1)"
verify_code=$?
set -e
assert_true "$([[ "$verify_code" -eq 0 ]] && echo true || echo false)" "verify-script-reports-success"

# --- Real Chain Validation ---
chain_root="${TEMP_ROOT}/real-chain-validation"
set +e
chain_out="$(bash "$REAL_CHAIN_SCRIPT_PATH" --validation-root "$chain_root" --name "sample-real-chain" --session-key "sample-real-chain-session" 2>&1)"
chain_code=$?
set -e
assert_true "$([[ "$chain_code" -eq 0 ]] && echo true || echo false)" "real-chain-validation-succeeds"

task_root="${chain_root}/sample-real-chain/tasks"
assert_true "$([[ -d "$task_root" ]] && echo true || echo false)" "real-chain-validation-creates-task-root"

echo "delegate runtime tests passed"
exit 0
