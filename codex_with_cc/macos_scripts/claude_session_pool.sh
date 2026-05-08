#!/usr/bin/env bash
# claude_session_pool.sh — Session pool management for Claude delegation.
# Ported from windows_scripts/claude_session_pool.ps1.
set -euo pipefail

if ! command -v jq &>/dev/null; then
  echo "ERROR: 'jq' is required but not found. Install it: brew install jq" >&2
  exit 1
fi

new_claude_session_id() {
  uuidgen | tr '[:upper:]' '[:lower:]'
}

get_effective_session_key() {
  local value="${1:-}"
  if [[ -n "$value" ]]; then
    echo "$value"
    return
  fi
  if [[ -n "${CODEX_THREAD_ID:-}" ]]; then
    echo "$CODEX_THREAD_ID"
    return
  fi
  if [[ -n "${CODEX_SESSION_ID:-}" ]]; then
    echo "$CODEX_SESSION_ID"
    return
  fi
  echo "WARNING: Using default Claude session key fallback. Pass -k/--session-key explicitly or set CODEX_THREAD_ID / CODEX_SESSION_ID to avoid unintended session sharing." >&2
  echo "default"
}

get_safe_session_key() {
  local value="$1"
  local safe
  safe="$(echo "$value" | sed 's/[^A-Za-z0-9_.-]/_/g')"
  if [[ -z "$safe" ]]; then
    echo "default"
  else
    echo "$safe"
  fi
}

normalize_claude_delegate_list() {
  local items="$1"
  local IFS=';'
  local -a parts
  read -ra parts <<< "$items"
  for part in "${parts[@]}"; do
    local trimmed
    trimmed="$(echo "$part" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    if [[ -n "$trimmed" ]]; then
      echo "$trimmed"
    fi
  done
}

get_task_fingerprint() {
  local text="$1"
  local scope_items="$2"
  local test_items="$3"
  local task_mode="$4"

  local prefix
  if [[ ${#text} -gt 1000 ]]; then
    prefix="${text:0:1000}"
  else
    prefix="$text"
  fi

  local sorted_scope sorted_tests
  sorted_scope="$(echo "$scope_items" | sort | tr '\n' '|' | sed 's/|$//')"
  sorted_tests="$(echo "$test_items" | sort | tr '\n' '|' | sed 's/|$//')"

  local raw
  raw="$(printf 'mode=%s\nscope=%s\ntests=%s\ntask=%s' "$task_mode" "$sorted_scope" "$sorted_tests" "$prefix")"
  echo -n "$raw" | shasum -a 256 | cut -d' ' -f1
}

# test_lease_expired JSON_ITEM TIMEOUT_SECONDS
# Returns 0 if lease is expired.
test_lease_expired() {
  local item_json="$1"
  local timeout_seconds="$2"

  if [[ -z "$item_json" || "$item_json" == "null" || "$timeout_seconds" -lt 0 ]]; then
    return 1
  fi

  local status
  status="$(echo "$item_json" | jq -r '.status // ""')"
  if [[ "$status" != "leased" ]]; then
    return 1
  fi

  local leased_at
  leased_at="$(echo "$item_json" | jq -r '.leasedAt // ""')"
  if [[ -z "$leased_at" ]]; then
    return 0
  fi

  local leased_epoch now_epoch
  local leased_at_clean
  leased_at_clean="$(echo "$leased_at" | sed 's/[+-][0-9]\{4\}$//')"
  leased_epoch="$(date -u -j -f "%Y-%m-%dT%H:%M:%S" "$leased_at_clean" "+%s" 2>/dev/null || date -u -d "$leased_at" "+%s" 2>/dev/null || echo 0)"
  now_epoch="$(date "+%s")"

  local elapsed=$(( now_epoch - leased_epoch ))
  if [[ "$elapsed" -ge "$timeout_seconds" ]]; then
    return 0
  fi
  return 1
}

new_session_pool_state() {
  local key="$1"
  local now
  now="$(date -u +"%Y-%m-%dT%H:%M:%S%z" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%S")"
  jq -n --arg key "$key" --arg now "$now" '{
    version: 1,
    sessionKey: $key,
    createdAt: $now,
    updatedAt: $now,
    primary: {
      sessionId: null,
      status: "available",
      leaseRunId: null,
      leasePid: null,
      leasedAt: null,
      lastUsedAt: null,
      lastRunId: null,
      lastResetAt: null,
      lastResetReason: null,
      lastResetFromSessionId: null,
      lastResetFromRunId: null
    },
    parallelPool: []
  }'
}

read_session_pool_state() {
  local path="$1"
  local key="$2"

  if [[ ! -f "$path" ]]; then
    new_session_pool_state "$key"
    return
  fi

  local state
  state="$(cat "$path")"

  # Ensure primary exists
  if [[ "$(echo "$state" | jq '.primary')" == "null" ]]; then
    local default_primary
    default_primary="$(new_session_pool_state "$key" | jq '.primary')"
    state="$(echo "$state" | jq --argjson p "$default_primary" '.primary = $p')"
  fi

  # Ensure parallelPool exists
  if [[ "$(echo "$state" | jq '.parallelPool')" == "null" ]]; then
    state="$(echo "$state" | jq '.parallelPool = []')"
  fi

  # Ensure audit fields on primary
  state="$(echo "$state" | jq '
    .primary += {
      lastResetAt: (.primary.lastResetAt // null),
      lastResetReason: (.primary.lastResetReason // null),
      lastResetFromSessionId: (.primary.lastResetFromSessionId // null),
      lastResetFromRunId: (.primary.lastResetFromRunId // null),
      leasePid: (.primary.leasePid // null)
    } |
    .parallelPool = [.parallelPool[]? | . + {
      lastResetAt: (.lastResetAt // null),
      lastResetReason: (.lastResetReason // null),
      lastResetFromSessionId: (.lastResetFromSessionId // null),
      lastResetFromRunId: (.lastResetFromRunId // null),
      leasePid: (.leasePid // null),
      lastTaskFingerprint: (.lastTaskFingerprint // null)
    }]
  ')"

  echo "$state"
}

write_session_pool_state() {
  local path="$1"
  local state="$2"
  local now
  now="$(date -u +"%Y-%m-%dT%H:%M:%S%z" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%S")"
  state="$(echo "$state" | jq --arg now "$now" '.updatedAt = $now')"

  local parent
  parent="$(dirname "$path")"
  mkdir -p "$parent"
  local tmp_path="${parent}/.$(basename "$path").$(uuidgen | tr -d '-' | head -c 12).tmp"
  printf '%s\n' "$state" > "$tmp_path"
  mv -f "$tmp_path" "$path"
}

# _acquire_lock LOCK_PATH TIMEOUT_SECONDS
# Acquires a directory-based lock. Returns 0 on success, 1 on timeout.
_acquire_lock() {
  local lock_path="$1"
  local timeout_seconds="$2"
  local lock_dir
  lock_dir="$(dirname "$lock_path")"
  mkdir -p "$lock_dir"

  local deadline=$(( $(date +%s) + timeout_seconds ))
  while true; do
    if mkdir "$lock_path.d" 2>/dev/null; then
      echo $$ > "$lock_path.d/pid"
      return 0
    fi
    if [[ $(date +%s) -ge $deadline ]]; then
      return 1
    fi
    sleep 0.1
  done
}

# _release_lock LOCK_PATH
_release_lock() {
  local lock_path="$1"
  rm -rf "$lock_path.d" 2>/dev/null || true
}

# invoke_session_state_update STATE_PATH LOCK_PATH KEY TIMEOUT_SECONDS CALLBACK
# CALLBACK receives the state JSON via stdin and must output the updated state + result.
# This is complex in bash; we use a temp file approach.
# The callback script file receives $1=state_file, $2=result_file and should:
#   - Read state from state_file
#   - Write updated state back to state_file
#   - Write result JSON to result_file
invoke_session_state_update() {
  local state_path="$1"
  local lock_path="$2"
  local key="$3"
  local timeout_seconds="$4"
  # remaining args are the callback command

  if ! _acquire_lock "$lock_path" "$timeout_seconds"; then
    echo "ERROR: Timed out waiting for Claude session pool lock: $lock_path" >&2
    return 1
  fi

  local state
  state="$(read_session_pool_state "$state_path" "$key")"

  local state_file result_file
  state_file="$(mktemp)"
  result_file="$(mktemp)"
  echo "$state" > "$state_file"

  local rc=0
  # The caller must define _session_update_callback which reads state_file, writes result_file
  _session_update_callback "$state_file" "$result_file" || rc=$?

  state="$(cat "$state_file")"
  write_session_pool_state "$state_path" "$state"

  local result=""
  if [[ -s "$result_file" ]]; then
    result="$(cat "$result_file")"
  fi

  rm -f "$state_file" "$result_file"
  _release_lock "$lock_path"

  if [[ $rc -ne 0 ]]; then
    return $rc
  fi
  if [[ -n "$result" ]]; then
    echo "$result"
  fi
}

# acquire_claude_session_lease STATE_PATH LOCK_PATH KEY MODE RUN_ID FINGERPRINT LEASE_TIMEOUT_SECONDS WAIT_SECONDS RESET_PRIMARY RESET_POOL
# Sets global variables:
#   _LEASE_MODE, _LEASE_SESSION_ID, _LEASE_RESUME, _LEASE_POOL_INDEX, _LEASE_LEASED
acquire_claude_session_lease() {
  local state_path="$1"
  local lock_path="$2"
  local key="$3"
  local mode="$4"
  local run_id="$5"
  local fingerprint="$6"
  local lease_timeout_seconds="$7"
  local wait_seconds="$8"
  local reset_primary="$9"
  local reset_pool="${10}"

  local deadline=$(( $(date +%s) + wait_seconds ))
  local current_pid=$$

  while true; do
    if ! _acquire_lock "$lock_path" 30; then
      echo "ERROR: Timed out waiting for Claude session pool lock: $lock_path" >&2
      return 1
    fi

    local state
    state="$(read_session_pool_state "$state_path" "$key")"

    # Apply resets
    if [[ "$reset_primary" == "true" ]]; then
      state="$(echo "$state" | jq '.primary.sessionId = null | .primary.status = "available" | .primary.leaseRunId = null | .primary.leasedAt = null | .primary.lastUsedAt = null | .primary.lastRunId = null')"
    fi
    if [[ "$reset_pool" == "true" ]]; then
      state="$(echo "$state" | jq '.parallelPool = []')"
    fi

    # Reclaim expired primary lease
    local primary_status primary_leased_at primary_lease_pid primary_lease_run_id
    primary_status="$(echo "$state" | jq -r '.primary.status // ""')"
    primary_leased_at="$(echo "$state" | jq -r '.primary.leasedAt // ""')"
    primary_lease_pid="$(echo "$state" | jq -r '.primary.leasePid // ""')"
    primary_lease_run_id="$(echo "$state" | jq -r '.primary.leaseRunId // ""')"

    if [[ "$primary_status" == "leased" && -n "$primary_leased_at" ]]; then
      local primary_json
      primary_json="$(echo "$state" | jq '.primary')"
      if test_lease_expired "$primary_json" "$lease_timeout_seconds" 2>/dev/null; then
        echo "WARNING: Reclaiming expired primary Claude session lease: $primary_lease_run_id" >&2
        state="$(echo "$state" | jq '.primary.status = "available" | .primary.leaseRunId = null | .primary.leasePid = null | .primary.leasedAt = null')"
        primary_status="available"
      fi
    fi

    # PID-based reclamation for primary
    if [[ "$primary_status" == "leased" && -n "$primary_lease_pid" && "$primary_lease_pid" != "null" ]]; then
      if [[ "$primary_lease_pid" -gt 0 ]] 2>/dev/null; then
        if ! kill -0 "$primary_lease_pid" 2>/dev/null; then
          echo "WARNING: Reclaiming primary lease from dead process (PID $primary_lease_pid, run $primary_lease_run_id)" >&2
          state="$(echo "$state" | jq '.primary.status = "available" | .primary.leaseRunId = null | .primary.leasePid = null | .primary.leasedAt = null')"
          primary_status="available"
        fi
      fi
    fi

    # Reclaim expired/dead parallel pool leases
    local pool_count
    pool_count="$(echo "$state" | jq '.parallelPool | length')"
    local i=0
    while [[ $i -lt $pool_count ]]; do
      local slot_json slot_status slot_pid slot_run_id
      slot_json="$(echo "$state" | jq ".parallelPool[$i]")"
      slot_status="$(echo "$slot_json" | jq -r '.status // ""')"
      slot_pid="$(echo "$slot_json" | jq -r '.leasePid // ""')"
      slot_run_id="$(echo "$slot_json" | jq -r '.leaseRunId // ""')"

      if [[ "$slot_status" == "leased" ]]; then
        if test_lease_expired "$slot_json" "$lease_timeout_seconds" 2>/dev/null; then
          echo "WARNING: Reclaiming expired parallel Claude session lease: $slot_run_id" >&2
          state="$(echo "$state" | jq ".parallelPool[$i].status = \"available\" | .parallelPool[$i].leaseRunId = null | .parallelPool[$i].leasePid = null | .parallelPool[$i].leasedAt = null")"
        elif [[ -n "$slot_pid" && "$slot_pid" != "null" && "$slot_pid" -gt 0 ]] 2>/dev/null; then
          if ! kill -0 "$slot_pid" 2>/dev/null; then
            echo "WARNING: Reclaiming parallel lease from dead process (PID $slot_pid, run $slot_run_id)" >&2
            state="$(echo "$state" | jq ".parallelPool[$i].status = \"available\" | .parallelPool[$i].leaseRunId = null | .parallelPool[$i].leasePid = null | .parallelPool[$i].leasedAt = null")"
          fi
        fi
      fi
      i=$((i + 1))
    done

    local now
    now="$(date -u +"%Y-%m-%dT%H:%M:%S%z" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%S")"
    primary_status="$(echo "$state" | jq -r '.primary.status // ""')"

    local lease_result=""
    if [[ "$mode" == "PrimaryReuse" || "$mode" == "PrimaryAnchor" ]]; then
      if [[ "$primary_status" == "leased" ]]; then
        # Can't acquire; lease is held
        write_session_pool_state "$state_path" "$state"
        _release_lock "$lock_path"

        if [[ $(date +%s) -ge $deadline ]]; then
          echo "ERROR: Another delegate_to_claude run is still active in this session. SessionKey: $key. Use a longer --session-lease-wait-seconds or choose ParallelPool." >&2
          return 1
        fi
        sleep 0.25
        continue
      fi

      local primary_session_id resume="false"
      primary_session_id="$(echo "$state" | jq -r '.primary.sessionId // ""')"
      if [[ -n "$primary_session_id" && "$primary_session_id" != "null" ]]; then
        resume="true"
      else
        primary_session_id="$(new_claude_session_id)"
        state="$(echo "$state" | jq --arg sid "$primary_session_id" '.primary.sessionId = $sid')"
      fi
      state="$(echo "$state" | jq --arg rid "$run_id" --arg pid "$current_pid" --arg now "$now" '
        .primary.status = "leased" |
        .primary.leaseRunId = $rid |
        .primary.leasePid = ($pid | tonumber) |
        .primary.leasedAt = $now
      ')"

      write_session_pool_state "$state_path" "$state"
      _release_lock "$lock_path"

      _LEASE_MODE="$mode"
      _LEASE_SESSION_ID="$primary_session_id"
      _LEASE_RESUME="$resume"
      _LEASE_POOL_INDEX=""
      _LEASE_LEASED="true"
      return 0

    else
      # ParallelPool mode
      pool_count="$(echo "$state" | jq '.parallelPool | length')"

      # Find available slot, preferring fingerprint match
      local selected_index=-1
      local selected_has_match="false"
      i=0
      while [[ $i -lt $pool_count ]]; do
        local slot_status fp
        slot_status="$(echo "$state" | jq -r ".parallelPool[$i].status // \"\"")"
        if [[ "$slot_status" != "leased" ]]; then
          fp="$(echo "$state" | jq -r ".parallelPool[$i].lastTaskFingerprint // \"\"")"
          if [[ "$fp" == "$fingerprint" ]]; then
            selected_index=$i
            selected_has_match="true"
            break
          elif [[ $selected_index -eq -1 ]]; then
            selected_index=$i
          fi
        fi
        i=$((i + 1))
      done

      local session_id resume="false"
      if [[ $selected_index -eq -1 ]]; then
        # Create new pool entry
        session_id="$(new_claude_session_id)"
        state="$(echo "$state" | jq --arg sid "$session_id" --arg rid "$run_id" --arg pid "$current_pid" --arg now "$now" --arg fp "$fingerprint" '
          .parallelPool += [{
            sessionId: $sid,
            status: "leased",
            leaseRunId: $rid,
            leasePid: ($pid | tonumber),
            leasedAt: $now,
            lastUsedAt: null,
            lastRunId: null,
            lastTaskFingerprint: $fp,
            lastResetAt: null,
            lastResetReason: null,
            lastResetFromSessionId: null,
            lastResetFromRunId: null
          }]
        ')"
        selected_index=$(( $(echo "$state" | jq '.parallelPool | length') - 1 ))
      else
        session_id="$(echo "$state" | jq -r ".parallelPool[$selected_index].sessionId // \"\"")"
        if [[ -n "$session_id" && "$session_id" != "null" ]]; then
          resume="true"
        else
          session_id="$(new_claude_session_id)"
          state="$(echo "$state" | jq --arg sid "$session_id" ".parallelPool[$selected_index].sessionId = \$sid")"
        fi
        state="$(echo "$state" | jq --arg rid "$run_id" --arg pid "$current_pid" --arg now "$now" --arg fp "$fingerprint" "
          .parallelPool[$selected_index].status = \"leased\" |
          .parallelPool[$selected_index].leaseRunId = \$rid |
          .parallelPool[$selected_index].leasePid = (\$pid | tonumber) |
          .parallelPool[$selected_index].leasedAt = \$now |
          .parallelPool[$selected_index].lastTaskFingerprint = \$fp
        ")"
      fi

      write_session_pool_state "$state_path" "$state"
      _release_lock "$lock_path"

      _LEASE_MODE="$mode"
      _LEASE_SESSION_ID="$session_id"
      _LEASE_RESUME="$resume"
      _LEASE_POOL_INDEX="$selected_index"
      _LEASE_LEASED="true"
      return 0
    fi
  done
}

# release_claude_session_lease STATE_PATH LOCK_PATH KEY LEASE_MODE LEASE_SESSION_ID RUN_ID FINGERPRINT
release_claude_session_lease() {
  local state_path="$1"
  local lock_path="$2"
  local key="$3"
  local lease_mode="$4"
  local lease_session_id="$5"
  local run_id="$6"
  local fingerprint="$7"
  local lease_leased="${8:-true}"

  if [[ "$lease_leased" != "true" ]]; then
    return 0
  fi

  if ! _acquire_lock "$lock_path" 30; then
    echo "WARNING: Failed to acquire lock for session release" >&2
    return 0
  fi

  local state
  state="$(read_session_pool_state "$state_path" "$key")"
  local now
  now="$(date -u +"%Y-%m-%dT%H:%M:%S%z" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%S")"

  if [[ "$lease_mode" == "PrimaryReuse" || "$lease_mode" == "PrimaryAnchor" ]]; then
    local current_lease_run_id
    current_lease_run_id="$(echo "$state" | jq -r '.primary.leaseRunId // ""')"
    if [[ "$current_lease_run_id" == "$run_id" ]]; then
      state="$(echo "$state" | jq --arg now "$now" --arg rid "$run_id" '
        .primary.status = "available" |
        .primary.leaseRunId = null |
        .primary.leasePid = null |
        .primary.leasedAt = null |
        .primary.lastUsedAt = $now |
        .primary.lastRunId = $rid
      ')"
    fi
  elif [[ "$lease_mode" == "ParallelPool" ]]; then
    local pool_count
    pool_count="$(echo "$state" | jq '.parallelPool | length')"
    local i=0
    while [[ $i -lt $pool_count ]]; do
      local slot_sid slot_rid
      slot_sid="$(echo "$state" | jq -r ".parallelPool[$i].sessionId // \"\"")"
      slot_rid="$(echo "$state" | jq -r ".parallelPool[$i].leaseRunId // \"\"")"
      if [[ "$slot_sid" == "$lease_session_id" && "$slot_rid" == "$run_id" ]]; then
        state="$(echo "$state" | jq --arg now "$now" --arg rid "$run_id" --arg fp "$fingerprint" "
          .parallelPool[$i].status = \"available\" |
          .parallelPool[$i].leaseRunId = null |
          .parallelPool[$i].leasePid = null |
          .parallelPool[$i].leasedAt = null |
          .parallelPool[$i].lastUsedAt = \$now |
          .parallelPool[$i].lastRunId = \$rid |
          .parallelPool[$i].lastTaskFingerprint = \$fp
        ")"
        break
      fi
      i=$((i + 1))
    done
  fi

  write_session_pool_state "$state_path" "$state"
  _release_lock "$lock_path"
}

# reset_claude_session_lease_for_fresh_session STATE_PATH LOCK_PATH KEY LEASE_MODE LEASE_SESSION_ID RUN_ID FINGERPRINT REASON
# Sets global _LEASE_* variables with the new lease info.
reset_claude_session_lease_for_fresh_session() {
  local state_path="$1"
  local lock_path="$2"
  local key="$3"
  local lease_mode="$4"
  local lease_session_id="$5"
  local run_id="$6"
  local fingerprint="$7"
  local reason="${8:-fresh_session_retry}"

  if ! _acquire_lock "$lock_path" 30; then
    echo "ERROR: Timed out waiting for session pool lock during reset" >&2
    exit 1
  fi

  local state
  state="$(read_session_pool_state "$state_path" "$key")"
  local now
  now="$(date -u +"%Y-%m-%dT%H:%M:%S%z" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%S")"
  local new_session_id
  new_session_id="$(new_claude_session_id)"

  if [[ "$lease_mode" == "PrimaryReuse" || "$lease_mode" == "PrimaryAnchor" ]]; then
    local current_run_id
    current_run_id="$(echo "$state" | jq -r '.primary.leaseRunId // ""')"
    if [[ "$current_run_id" != "$run_id" ]]; then
      _release_lock "$lock_path"
      echo "ERROR: Cannot reset primary Claude session lease; expected run '$run_id' but found '$current_run_id'." >&2
      exit 1
    fi

    state="$(echo "$state" | jq --arg sid "$new_session_id" --arg rid "$run_id" --arg now "$now" --arg reason "$reason" --arg old_sid "$lease_session_id" '
      .primary.sessionId = $sid |
      .primary.status = "leased" |
      .primary.leaseRunId = $rid |
      .primary.leasedAt = $now |
      .primary.lastUsedAt = null |
      .primary.lastRunId = null |
      .primary.lastResetAt = $now |
      .primary.lastResetReason = $reason |
      .primary.lastResetFromSessionId = $old_sid |
      .primary.lastResetFromRunId = $rid
    ')"

    write_session_pool_state "$state_path" "$state"
    _release_lock "$lock_path"

    _LEASE_MODE="$lease_mode"
    _LEASE_SESSION_ID="$new_session_id"
    _LEASE_RESUME="false"
    _LEASE_POOL_INDEX=""
    _LEASE_LEASED="true"
    return 0

  elif [[ "$lease_mode" == "ParallelPool" ]]; then
    local pool_count
    pool_count="$(echo "$state" | jq '.parallelPool | length')"
    local i=0
    while [[ $i -lt $pool_count ]]; do
      local slot_sid slot_rid
      slot_sid="$(echo "$state" | jq -r ".parallelPool[$i].sessionId // \"\"")"
      slot_rid="$(echo "$state" | jq -r ".parallelPool[$i].leaseRunId // \"\"")"
      if [[ "$slot_sid" == "$lease_session_id" && "$slot_rid" == "$run_id" ]]; then
        state="$(echo "$state" | jq --arg sid "$new_session_id" --arg rid "$run_id" --arg now "$now" --arg fp "$fingerprint" --arg reason "$reason" --arg old_sid "$lease_session_id" "
          .parallelPool[$i].sessionId = \$sid |
          .parallelPool[$i].status = \"leased\" |
          .parallelPool[$i].leaseRunId = \$rid |
          .parallelPool[$i].leasedAt = \$now |
          .parallelPool[$i].lastUsedAt = null |
          .parallelPool[$i].lastRunId = null |
          .parallelPool[$i].lastTaskFingerprint = \$fp |
          .parallelPool[$i].lastResetAt = \$now |
          .parallelPool[$i].lastResetReason = \$reason |
          .parallelPool[$i].lastResetFromSessionId = \$old_sid |
          .parallelPool[$i].lastResetFromRunId = \$rid
        ")"

        write_session_pool_state "$state_path" "$state"
        _release_lock "$lock_path"

        _LEASE_MODE="$lease_mode"
        _LEASE_SESSION_ID="$new_session_id"
        _LEASE_RESUME="false"
        _LEASE_POOL_INDEX="$i"
        _LEASE_LEASED="true"
        return 0
      fi
      i=$((i + 1))
    done

    _release_lock "$lock_path"
    echo "ERROR: Cannot reset parallel Claude session lease for run '$run_id'; the leased session was not found." >&2
    exit 1
  else
    _release_lock "$lock_path"
    echo "ERROR: Unsupported Claude session mode for reset: $lease_mode" >&2
    exit 1
  fi
}
