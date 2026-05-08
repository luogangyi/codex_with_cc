#!/usr/bin/env bash
# verify_delegate_chain.sh — Verifies the consistency and lifecycle of a multi-step Claude delegation chain.
# Ported from windows_scripts/verify_delegate_chain.ps1.

set -euo pipefail

usage() {
  echo "Usage: verify_delegate_chain.sh --artifact-root PATH --session-key KEY --anchor-run-id ID --parallel-run-ids 'ID1,ID2' --reuse-run-ids 'ID3,ID4'"
  exit 1
}

ARTIFACT_ROOT=""
SESSION_KEY=""
ANCHOR_RUN_ID=""
PARALLEL_RUN_IDS=""
REUSE_RUN_IDS=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --artifact-root|-ArtifactRoot) ARTIFACT_ROOT="$2"; shift 2 ;;
    --session-key|-SessionKey) SESSION_KEY="$2"; shift 2 ;;
    --anchor-run-id|-AnchorRunId) ANCHOR_RUN_ID="$2"; shift 2 ;;
    --parallel-run-ids|-ParallelRunIds) PARALLEL_RUN_IDS="$2"; shift 2 ;;
    --reuse-run-ids|-ReuseRunIds) REUSE_RUN_IDS="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

if [[ -z "$ARTIFACT_ROOT" || -z "$SESSION_KEY" || -z "$ANCHOR_RUN_ID" ]]; then
  echo "ERROR: Missing required arguments." >&2
  usage
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERIFY_ARTIFACTS_SCRIPT="${SCRIPT_DIR}/verify_delegate_artifacts.sh"

if [[ ! -f "$VERIFY_ARTIFACTS_SCRIPT" ]]; then
  echo "ERROR: Missing delegate artifact verifier: $VERIFY_ARTIFACTS_SCRIPT" >&2
  exit 1
fi

RESOLVED_ARTIFACT_ROOT="$(cd "$(dirname "$ARTIFACT_ROOT")" 2>/dev/null && pwd || echo "$PWD")/$(basename "$ARTIFACT_ROOT")"
if [[ -d "$ARTIFACT_ROOT" ]]; then
  RESOLVED_ARTIFACT_ROOT="$(cd "$ARTIFACT_ROOT" && pwd)"
fi

normalize_run_ids() {
  local input="$1"
  local -a output=()
  IFS=',' read -r -a parts <<< "$input"
  for part in "${parts[@]}"; do
    part="$(echo "$part" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e "s/^['\"]//" -e "s/['\"]$//")"
    if [[ -n "$part" ]]; then
      output+=("$part")
    fi
  done
  echo "${output[@]}"
}

# Parse lists
read -r -a PARALLEL_ARRAY <<< "$(normalize_run_ids "$PARALLEL_RUN_IDS")"
read -r -a REUSE_ARRAY <<< "$(normalize_run_ids "$REUSE_RUN_IDS")"

ALL_RUN_IDS=("$ANCHOR_RUN_ID" "${PARALLEL_ARRAY[@]}" "${REUSE_ARRAY[@]}")

# 1. Verify all individual artifacts
for run_id in "${ALL_RUN_IDS[@]}"; do
  if ! bash "$VERIFY_ARTIFACTS_SCRIPT" --run-id "$run_id" --artifact-root "$RESOLVED_ARTIFACT_ROOT" >/dev/null; then
    echo "ERROR: Artifact verification failed for run: $run_id" >&2
    exit 1
  fi
done

assert_true() {
  local condition="$1"
  local msg="$2"
  if [[ "$condition" != "true" ]]; then
    echo "ERROR: $msg" >&2
    exit 1
  fi
}

get_config_path() { echo "$RESOLVED_ARTIFACT_ROOT/config_${1}.json"; }
get_status_path() { echo "$RESOLVED_ARTIFACT_ROOT/status_${1}.json"; }

anchor_config="$(get_config_path "$ANCHOR_RUN_ID")"

assert_true "$([[ "$(jq -r '.sessionMode' "$anchor_config")" == "PrimaryAnchor" ]] && echo true || echo false)" "Anchor run must use PrimaryAnchor."
assert_true "$([[ "$(jq -r '.sessionKey' "$anchor_config")" == "$SESSION_KEY" ]] && echo true || echo false)" "Anchor run sessionKey mismatch."

session_state_path="$(jq -r '.sessionStatePath // ""' "$anchor_config")"
assert_true "$([[ -n "$session_state_path" ]] && echo true || echo false)" "Anchor run is missing sessionStatePath."
assert_true "$([[ -f "$session_state_path" ]] && echo true || echo false)" "Missing session state path: $session_state_path"

expected_main_session_id="$(jq -r '.sessionId' "$anchor_config")"

primary_cache_hit="true"
parallel_pool_reuse="false"
stale_reset_occurred="false"
artifact_contract_valid="true"

for run_id in "${PARALLEL_ARRAY[@]}"; do
  config_path="$(get_config_path "$run_id")"
  assert_true "$([[ "$(jq -r '.sessionMode' "$config_path")" == "ParallelPool" ]] && echo true || echo false)" "Parallel run '$run_id' must use ParallelPool."
  assert_true "$([[ "$(jq -r '.sessionKey' "$config_path")" == "$SESSION_KEY" ]] && echo true || echo false)" "Parallel run '$run_id' sessionKey mismatch."
  if [[ "$(jq -r '.initialResume' "$config_path")" == "true" ]]; then
    parallel_pool_reuse="true"
  fi
done

for run_id in "${REUSE_ARRAY[@]}"; do
  config_path="$(get_config_path "$run_id")"
  status_path="$(get_status_path "$run_id")"
  
  assert_true "$([[ "$(jq -r '.sessionMode' "$config_path")" == "PrimaryReuse" ]] && echo true || echo false)" "Reuse run '$run_id' must use PrimaryReuse."
  assert_true "$([[ "$(jq -r '.sessionKey' "$config_path")" == "$SESSION_KEY" ]] && echo true || echo false)" "Reuse run '$run_id' sessionKey mismatch."
  assert_true "$([[ "$(jq -r '.initialResume' "$config_path")" == "true" ]] && echo true || echo false)" "Reuse run '$run_id' must start by attempting resume=true."
  assert_true "$([[ "$(jq -r '.initialSessionId' "$config_path")" == "$expected_main_session_id" ]] && echo true || echo false)" "Reuse run '$run_id' did not start from the expected main session."

  first_resume="$(jq -r '.attempts[0].resume' "$status_path")"
  assert_true "$([[ "$first_resume" == "true" ]] && echo true || echo false)" "Reuse run '$run_id' first attempt must be resume=true."

  attempts_len="$(jq -r '.attempts | length' "$status_path")"
  final_session_id="$(jq -r ".attempts[$((attempts_len - 1))].sessionId" "$status_path")"
  final_resume="$(jq -r ".attempts[$((attempts_len - 1))].resume" "$status_path")"
  
  if [[ "$final_session_id" != "$expected_main_session_id" ]]; then
    stale_reset_occurred="true"
    retry_count="$(jq -r '.retryCount' "$status_path")"
    assert_true "$([[ "$retry_count" -ge 1 ]] && echo true || echo false)" "Reuse run '$run_id' changed primary session without recording a retry."
    
    last_reason="$(jq -r '.lastRetryReason' "$status_path")"
    assert_true "$([[ "$last_reason" == "stale_claude_session" ]] && echo true || echo false)" "Reuse run '$run_id' must record stale_claude_session when changing primary session."
    
    assert_true "$([[ "$final_resume" == "false" ]] && echo true || echo false)" "Reuse run '$run_id' fresh recovery attempt must be resume=false."
    expected_main_session_id="$final_session_id"
  fi
done

assert_true "$([[ "$(jq -r '.sessionKey' "$session_state_path")" == "$SESSION_KEY" ]] && echo true || echo false)" "Session pool sessionKey mismatch."
assert_true "$([[ "$(jq -r '.primary.status' "$session_state_path")" == "available" ]] && echo true || echo false)" "Primary session slot must be available after chain completion."
assert_true "$([[ "$(jq -r '.primary.sessionId' "$session_state_path")" == "$expected_main_session_id" ]] && echo true || echo false)" "Final primary session ID does not match the expected chain head."

if [[ "$stale_reset_occurred" == "true" ]]; then
  assert_true "$([[ -n "$(jq -r '.primary.lastResetAt // empty' "$session_state_path")" ]] && echo true || echo false)" "Primary session reset is missing lastResetAt."
  assert_true "$([[ "$(jq -r '.primary.lastResetReason' "$session_state_path")" == "stale_claude_session" ]] && echo true || echo false)" "Primary session reset reason must be stale_claude_session."
  assert_true "$([[ -n "$(jq -r '.primary.lastResetFromSessionId // empty' "$session_state_path")" ]] && echo true || echo false)" "Primary session reset is missing lastResetFromSessionId."
  assert_true "$([[ -n "$(jq -r '.primary.lastResetFromRunId // empty' "$session_state_path")" ]] && echo true || echo false)" "Primary session reset is missing lastResetFromRunId."
fi

for run_id in "${PARALLEL_ARRAY[@]}"; do
  config_path="$(get_config_path "$run_id")"
  parallel_session_id="$(jq -r '.sessionId' "$config_path")"
  
  slot_status="$(jq -r ".parallelPool[] | select(.sessionId == \"$parallel_session_id\") | .status" "$session_state_path" | head -n 1)"
  slot_last_fp="$(jq -r ".parallelPool[] | select(.sessionId == \"$parallel_session_id\") | .lastTaskFingerprint // empty" "$session_state_path" | head -n 1)"
  
  assert_true "$([[ -n "$slot_status" ]] && echo true || echo false)" "Parallel pool slot for run '$run_id' was not found."
  assert_true "$([[ "$slot_status" == "available" ]] && echo true || echo false)" "Parallel pool slot for run '$run_id' must be available after chain completion."
  assert_true "$([[ -n "$slot_last_fp" ]] && echo true || echo false)" "Parallel pool slot for run '$run_id' is missing lastTaskFingerprint."
done

orphan_lease_detected="false"
if [[ "$(jq -r '.primary.status' "$session_state_path")" == "leased" ]]; then
  orphan_lease_detected="true"
fi
if jq -e '.parallelPool[] | select(.status == "leased")' "$session_state_path" >/dev/null 2>&1; then
  orphan_lease_detected="true"
fi

chain_passed="false"
if [[ "$orphan_lease_detected" == "false" ]]; then
  chain_passed="true"
fi

jq -n \
  --argjson pCache "$primary_cache_hit" \
  --argjson pPool "$parallel_pool_reuse" \
  --argjson sReset "$stale_reset_occurred" \
  --argjson oLease "$orphan_lease_detected" \
  --argjson aValid "$artifact_contract_valid" \
  --argjson cPass "$chain_passed" \
  '{
    primaryCacheHit: $pCache,
    parallelPoolReuse: $pPool,
    staleResetOccurred: $sReset,
    orphanLeaseDetected: $oLease,
    artifactContractValid: $aValid,
    chainPassed: $cPass
  }'

if [[ "$orphan_lease_detected" == "true" ]]; then
  echo "ERROR: Delegate chain verification failed because a session lease is still active." >&2
  exit 1
fi

exit 0
