#!/usr/bin/env bash
# verify_delegate_artifacts.sh — Validates Claude delegate artifacts for consistency and contract compliance.
# Ported from windows_scripts/verify_delegate_artifacts.ps1.

set -euo pipefail

usage() {
  echo "Usage: verify_delegate_artifacts.sh --run-id ID [--artifact-root PATH]"
  exit 1
}

RUN_ID=""
ARTIFACT_ROOT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-id|-RunId) RUN_ID="$2"; shift 2 ;;
    --artifact-root|-ArtifactRoot) ARTIFACT_ROOT="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

if [[ -z "$RUN_ID" ]]; then
  echo "ERROR: --run-id is required." >&2
  usage
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER_SCRIPT="${SCRIPT_DIR}/claude_delegate_backend_helpers.sh"
if [[ ! -f "$HELPER_SCRIPT" ]]; then
  echo "ERROR: Missing Claude delegate backend helper: $HELPER_SCRIPT" >&2
  exit 1
fi
source "$HELPER_SCRIPT"

if [[ -z "$ARTIFACT_ROOT" ]]; then
  REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
  ARTIFACT_ROOT="$REPO_ROOT/.codex/codex_with_cc/claude-delegate"
fi

RESOLVED_ARTIFACT_ROOT="$(cd "$(dirname "$ARTIFACT_ROOT")" 2>/dev/null && pwd || echo "$PWD")/$(basename "$ARTIFACT_ROOT")"
if [[ -d "$ARTIFACT_ROOT" ]]; then
  RESOLVED_ARTIFACT_ROOT="$(cd "$ARTIFACT_ROOT" && pwd)"
fi

CONFIG_PATH="$RESOLVED_ARTIFACT_ROOT/config_${RUN_ID}.json"
STATUS_PATH="$RESOLVED_ARTIFACT_ROOT/status_${RUN_ID}.json"
OUTPUT_PATH="$RESOLVED_ARTIFACT_ROOT/claude_${RUN_ID}.md"

if [[ ! -f "$CONFIG_PATH" ]]; then
  echo "ERROR: Missing delegate config: $CONFIG_PATH" >&2
  exit 1
fi
if [[ ! -f "$STATUS_PATH" ]]; then
  echo "ERROR: Missing delegate status: $STATUS_PATH" >&2
  exit 1
fi
if [[ ! -f "$OUTPUT_PATH" ]]; then
  echo "ERROR: Missing delegate output: $OUTPUT_PATH" >&2
  exit 1
fi

EXPECTED_SCHEMA=2
EXPECTED_CONTRACT="spawn_agent_child_only"
EXPECTED_MARKER="CODEX_CLAUDE_CHILD_THREAD"

# Extract JSON
config_schema="$(jq -r '.artifactSchema // empty' "$CONFIG_PATH")"
config_contract="$(jq -r '.invocationContract // empty' "$CONFIG_PATH")"
status_schema="$(jq -r '.artifactSchema // empty' "$STATUS_PATH")"
status_contract="$(jq -r '.invocationContract // empty' "$STATUS_PATH")"

if [[ -z "$config_schema" || -z "$config_contract" || -z "$status_schema" || -z "$status_contract" ]]; then
  echo "ERROR: Legacy delegate artifact is unsupported; rerun with current spawn_agent-based flow." >&2
  exit 1
fi

if [[ "$config_schema" != "$EXPECTED_SCHEMA" || "$status_schema" != "$EXPECTED_SCHEMA" ]]; then
  echo "ERROR: Unexpected delegate artifact schema. Expected $EXPECTED_SCHEMA." >&2
  exit 1
fi

if [[ "$config_contract" != "$EXPECTED_CONTRACT" || "$status_contract" != "$EXPECTED_CONTRACT" ]]; then
  echo "ERROR: Unexpected delegate invocation contract. Expected '$EXPECTED_CONTRACT'." >&2
  exit 1
fi

config_marker="$(jq -r '.childThreadMarkerName // empty' "$CONFIG_PATH")"
status_marker="$(jq -r '.childThreadMarkerName // empty' "$STATUS_PATH")"
if [[ -z "$config_marker" || -z "$status_marker" ]]; then
  echo "ERROR: Delegate artifact is missing child-thread marker metadata." >&2
  exit 1
fi
if [[ "$config_marker" != "$EXPECTED_MARKER" || "$status_marker" != "$EXPECTED_MARKER" ]]; then
  echo "ERROR: Unexpected child-thread marker name. Expected '$EXPECTED_MARKER'." >&2
  exit 1
fi

config_val="$(jq -r '.childThreadMarkerValidated | type' "$CONFIG_PATH")"
status_val="$(jq -r '.childThreadMarkerValidated | type' "$STATUS_PATH")"
if [[ "$config_val" != "boolean" || "$status_val" != "boolean" ]]; then
  echo "ERROR: Delegate artifact is missing child-thread validation state." >&2
  exit 1
fi
if [[ "$(jq -r '.childThreadMarkerValidated' "$CONFIG_PATH")" != "true" || "$(jq -r '.childThreadMarkerValidated' "$STATUS_PATH")" != "true" ]]; then
  echo "ERROR: Delegate artifact indicates the child-thread marker was not validated." >&2
  exit 1
fi

config_output="$(jq -r '.outputPath // ""' "$CONFIG_PATH")"
if [[ "$config_output" != "$OUTPUT_PATH" ]]; then
  echo "ERROR: Config outputPath mismatch. Expected: $OUTPUT_PATH ; Actual: $config_output" >&2
  exit 1
fi

status_output="$(jq -r '.outputPath // ""' "$STATUS_PATH")"
if [[ "$status_output" != "$OUTPUT_PATH" ]]; then
  echo "ERROR: Status outputPath mismatch. Expected: $OUTPUT_PATH ; Actual: $status_output" >&2
  exit 1
fi

status_val_str="$(jq -r '.status // ""' "$STATUS_PATH")"
if [[ "$status_val_str" != "starting" && "$status_val_str" != "running" && "$status_val_str" != "completed" && "$status_val_str" != "failed" ]]; then
  echo "ERROR: Unexpected delegate status value: $status_val_str" >&2
  exit 1
fi

is_completed="false"
is_structured_failure="false"
[[ "$status_val_str" == "completed" ]] && is_completed="true"
[[ "$status_val_str" == "failed" ]] && is_structured_failure="true"

if [[ "$is_completed" == "false" && "$is_structured_failure" == "false" ]]; then
  echo "ERROR: Delegate status is neither completed nor failed: $status_val_str" >&2
  exit 1
fi

if ! test_claude_delegate_has_final_result "$OUTPUT_PATH"; then
  echo "ERROR: Delegate output does not contain a Final Result heading: $OUTPUT_PATH" >&2
  exit 1
fi

status_exitcode="$(jq -r '.exitCode // empty' "$STATUS_PATH")"
if [[ "$is_completed" == "true" && -n "$status_exitcode" && "$status_exitcode" != "0" ]]; then
  echo "ERROR: Delegate exitCode is not zero: $status_exitcode" >&2
  exit 1
fi
if [[ "$is_structured_failure" == "true" && -n "$status_exitcode" && "$status_exitcode" == "0" ]]; then
  echo "ERROR: Structured failed delegate must record a non-zero exitCode." >&2
  exit 1
fi

if [[ "$(jq -r '.attempts | type' "$STATUS_PATH")" != "array" ]]; then
  echo "ERROR: Delegate status is missing attempts[] audit data." >&2
  exit 1
fi
if [[ "$(jq -r '.sessionMode | type' "$CONFIG_PATH")" == "null" ]]; then
  echo "ERROR: Delegate config is missing sessionMode." >&2
  exit 1
fi
if [[ "$(jq -r '.sessionKey | type' "$CONFIG_PATH")" == "null" ]]; then
  echo "ERROR: Delegate config is missing sessionKey." >&2
  exit 1
fi

attempts_count="$(jq -r '.attempts | length' "$STATUS_PATH")"
status_attemptCount="$(jq -r 'if has("attemptCount") then .attemptCount else '"$attempts_count"' end' "$STATUS_PATH")"
status_retryCount="$(jq -r 'if has("retryCount") then .retryCount else 0 end' "$STATUS_PATH")"
config_attemptCount="$(jq -r 'if has("attemptCount") then .attemptCount else '"$status_attemptCount"' end' "$CONFIG_PATH")"
config_retryCount="$(jq -r 'if has("retryCount") then .retryCount else '"$status_retryCount"' end' "$CONFIG_PATH")"

if [[ "$attempts_count" != "$status_attemptCount" ]]; then
  echo "ERROR: Delegate attempts[] count mismatch. attempts=$attempts_count status.attemptCount=$status_attemptCount" >&2
  exit 1
fi
if (( status_attemptCount < 1 )); then
  echo "ERROR: Delegate status must record at least one attempt." >&2
  exit 1
fi
if [[ "$config_attemptCount" != "$status_attemptCount" ]]; then
  echo "ERROR: Config/status attemptCount mismatch. config=$config_attemptCount status=$status_attemptCount" >&2
  exit 1
fi
if [[ "$config_retryCount" != "$status_retryCount" ]]; then
  echo "ERROR: Config/status retryCount mismatch. config=$config_retryCount status=$status_retryCount" >&2
  exit 1
fi

if [[ "$is_structured_failure" == "true" ]]; then
  for prop in failureDisposition failureSummary maxRetryCount; do
    if [[ "$(jq -r "has(\"$prop\")" "$STATUS_PATH")" != "true" ]]; then
      echo "ERROR: Structured failed delegate status is missing '$prop'." >&2
      exit 1
    fi
    if [[ "$(jq -r "has(\"$prop\")" "$CONFIG_PATH")" != "true" ]]; then
      echo "ERROR: Structured failed delegate config is missing '$prop'." >&2
      exit 1
    fi
  done
  
  status_disp="$(jq -r '.failureDisposition' "$STATUS_PATH")"
  if [[ "$status_disp" != "NEED_HUMAN_INTERVENTION" ]]; then
    echo "ERROR: Structured failed delegate must set failureDisposition to 'NEED_HUMAN_INTERVENTION'. Actual: $status_disp" >&2
    exit 1
  fi
  config_disp="$(jq -r '.failureDisposition' "$CONFIG_PATH")"
  if [[ "$config_disp" != "$status_disp" ]]; then
    echo "ERROR: Structured failed delegate failureDisposition must match between config and status." >&2
    exit 1
  fi
  
  status_summary="$(jq -r '.failureSummary // ""' "$STATUS_PATH")"
  if [[ -z "$status_summary" ]]; then
    echo "ERROR: Structured failed delegate must record a non-empty failureSummary." >&2
    exit 1
  fi
  config_summary="$(jq -r '.failureSummary // ""' "$CONFIG_PATH")"
  if [[ "$config_summary" != "$status_summary" ]]; then
    echo "ERROR: Structured failed delegate failureSummary must match between config and status." >&2
    exit 1
  fi
  
  if [[ "$(jq -r '.maxRetryCount' "$CONFIG_PATH")" != "$(jq -r '.maxRetryCount' "$STATUS_PATH")" ]]; then
    echo "ERROR: Structured failed delegate maxRetryCount must match between config and status." >&2
    exit 1
  fi
fi

recorded_retry_reasons=0
for (( i=0; i<attempts_count; i++ )); do
  for prop in attempt sessionId resume retryReason exitCode sawAssistantText sawResultSuccess capturedFinalResult; do
    if [[ "$(jq -r ".attempts[$i] | has(\"$prop\")" "$STATUS_PATH")" != "true" ]]; then
      echo "ERROR: Delegate attempt[$i] is missing '$prop'." >&2
      exit 1
    fi
  done
  
  attempt_num="$(jq -r ".attempts[$i].attempt" "$STATUS_PATH")"
  if [[ "$attempt_num" != "$((i + 1))" ]]; then
    echo "ERROR: Delegate attempt numbering is not sequential at index $i. Expected $((i + 1)) but found $attempt_num." >&2
    exit 1
  fi
  
  reason="$(jq -r ".attempts[$i].retryReason // \"\"" "$STATUS_PATH")"
  if [[ -n "$reason" && "$reason" != "null" ]]; then
    recorded_retry_reasons=$((recorded_retry_reasons + 1))
  fi
done

if [[ "$recorded_retry_reasons" != "$status_retryCount" ]]; then
  echo "ERROR: Delegate retry count mismatch. attempts-with-retryReason=$recorded_retry_reasons status.retryCount=$status_retryCount" >&2
  exit 1
fi

if [[ "$(jq -r 'has("initialSessionId")' "$CONFIG_PATH")" != "true" ]]; then
  echo "ERROR: Delegate config is missing initialSessionId." >&2
  exit 1
fi
if [[ "$(jq -r 'has("initialResume")' "$CONFIG_PATH")" != "true" ]]; then
  echo "ERROR: Delegate config is missing initialResume." >&2
  exit 1
fi

config_init_sid="$(jq -r '.initialSessionId' "$CONFIG_PATH")"
first_attempt_sid="$(jq -r '.attempts[0].sessionId' "$STATUS_PATH")"
if [[ "$config_init_sid" != "$first_attempt_sid" ]]; then
  echo "ERROR: Config initialSessionId mismatch. Expected first attempt session $first_attempt_sid but found $config_init_sid" >&2
  exit 1
fi

config_init_res="$(jq -r '.initialResume' "$CONFIG_PATH")"
first_attempt_res="$(jq -r '.attempts[0].resume' "$STATUS_PATH")"
if [[ "$config_init_res" != "$first_attempt_res" ]]; then
  echo "ERROR: Config initialResume mismatch. Expected first attempt resume $first_attempt_res but found $config_init_res" >&2
  exit 1
fi

config_sid="$(jq -r '.sessionId // empty' "$CONFIG_PATH")"
final_attempt_sid="$(jq -r ".attempts[$((attempts_count - 1))].sessionId" "$STATUS_PATH")"
if [[ -n "$config_sid" && "$config_sid" != "$final_attempt_sid" ]]; then
  echo "ERROR: Config final sessionId mismatch. Expected final attempt session $final_attempt_sid but found $config_sid" >&2
  exit 1
fi

config_res="$(jq -r '.resume' "$CONFIG_PATH")"
final_attempt_res="$(jq -r ".attempts[$((attempts_count - 1))].resume" "$STATUS_PATH")"
if [[ "$(jq -r 'has("resume")' "$CONFIG_PATH")" == "true" && "$config_res" != "$final_attempt_res" ]]; then
  echo "ERROR: Config final resume mismatch. Expected final attempt resume $final_attempt_res but found $config_res" >&2
  exit 1
fi

final_attempt_exit="$(jq -r ".attempts[$((attempts_count - 1))].exitCode" "$STATUS_PATH")"
if [[ "$final_attempt_exit" != "$status_exitcode" ]]; then
  echo "ERROR: Final attempt exitCode mismatch. Expected $status_exitcode but found $final_attempt_exit" >&2
  exit 1
fi

final_attempt_success="$(jq -r ".attempts[$((attempts_count - 1))].sawResultSuccess" "$STATUS_PATH")"
final_attempt_cap="$(jq -r ".attempts[$((attempts_count - 1))].capturedFinalResult" "$STATUS_PATH")"

if [[ "$is_completed" == "true" ]]; then
  if [[ "$final_attempt_success" != "true" ]]; then
    echo "ERROR: Completed delegate must record sawResultSuccess=true on the final attempt." >&2
    exit 1
  fi
  if [[ "$final_attempt_cap" != "true" ]]; then
    echo "ERROR: Completed delegate must record capturedFinalResult=true on the final attempt." >&2
    exit 1
  fi
fi

if [[ "$is_structured_failure" == "true" && "$final_attempt_cap" != "true" ]]; then
  echo "ERROR: Structured failed delegate must record capturedFinalResult=true on the final attempt." >&2
  exit 1
fi

# Check optional paths
for prop in rawStreamPath tracePath promptPath; do
  p="$(jq -r ".$prop // empty" "$CONFIG_PATH")"
  if [[ -n "$p" && ! -f "$p" ]]; then
    echo "ERROR: Referenced artifact path is missing: $p" >&2
    exit 1
  fi
  p2="$(jq -r ".$prop // empty" "$STATUS_PATH")"
  if [[ -n "$p2" && ! -f "$p2" && "$p2" != "$p" ]]; then
    echo "ERROR: Referenced artifact path is missing: $p2" >&2
    exit 1
  fi
done

# Session state check
config_session_path="$(jq -r '.sessionStatePath // empty' "$CONFIG_PATH")"
if [[ -n "$config_session_path" && -f "$config_session_path" ]]; then
  if [[ "$(jq -r '.primary.leaseRunId // ""' "$config_session_path")" == "$RUN_ID" ]]; then
    echo "ERROR: Primary session lease is still held by run $RUN_ID." >&2
    exit 1
  fi
  
  if [[ "$(jq -r '.parallelPool | type' "$config_session_path")" == "array" ]]; then
    if jq -e ".parallelPool[] | select(.leaseRunId == \"$RUN_ID\")" "$config_session_path" >/dev/null; then
      echo "ERROR: Parallel session lease is still held by run $RUN_ID." >&2
      exit 1
    fi
  fi
fi

echo "Artifact verification passed for RunId: $RUN_ID"
exit 0
