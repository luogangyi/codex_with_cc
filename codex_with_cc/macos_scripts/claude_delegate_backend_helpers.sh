#!/usr/bin/env bash
# claude_delegate_backend_helpers.sh — Backend utility functions for Claude delegation.
# Ported from windows_scripts/claude_delegate_backend_helpers.ps1.
set -euo pipefail

# Ensure jq is available
if ! command -v jq &>/dev/null; then
  echo "ERROR: 'jq' is required but not found. Install it: brew install jq" >&2
  exit 1
fi

# write_claude_delegate_json_file PATH JSON_STRING
# Atomically writes JSON to PATH, adding/updating an updatedAt field.
write_claude_delegate_json_file() {
  local path="$1"
  local data="$2"
  local dir
  dir="$(dirname "$path")"
  mkdir -p "$dir"

  local updated_at
  updated_at="$(date -u +"%Y-%m-%dT%H:%M:%S%z" 2>/dev/null || date -Iseconds 2>/dev/null || date +"%Y-%m-%dT%H:%M:%S")"

  # Add or update updatedAt
  local json
  json="$(echo "$data" | jq --arg ts "$updated_at" '. + {updatedAt: $ts}')"

  local tmp_path="${dir}/.$(basename "$path").$(uuidgen | tr -d '-' | head -c 12).tmp"
  printf '%s\n' "$json" > "$tmp_path"
  mv -f "$tmp_path" "$path"
}

# test_claude_delegate_text_has_final_result_heading TEXT
# Returns 0 (true) if text contains a "Final Result" heading, 1 otherwise.
test_claude_delegate_text_has_final_result_heading() {
  local text="${1:-}"
  if [[ -z "$text" ]]; then
    return 1
  fi
  if echo "$text" | grep -qE '^[[:space:]]*(#+[[:space:]]*|\*\*|__)?Final Result(\*\*|__)?(:)?[[:space:]]*$'; then
    return 0
  fi
  return 1
}

# test_claude_delegate_has_final_result PATH
# Returns 0 if the file at PATH contains a Final Result heading.
test_claude_delegate_has_final_result() {
  local path="${1:-}"
  if [[ -z "$path" || ! -f "$path" ]]; then
    return 1
  fi
  local content
  content="$(cat "$path")"
  test_claude_delegate_text_has_final_result_heading "$content"
}

# convert_claude_delegate_unstructured_final_text TEXT
# Wraps unstructured text into the required report envelope.
# Prints the normalized text to stdout.
convert_claude_delegate_unstructured_final_text() {
  local text="${1:-}"
  local trimmed
  trimmed="$(echo "$text" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  if [[ -z "$trimmed" ]]; then
    echo ""
    return
  fi
  if test_claude_delegate_text_has_final_result_heading "$trimmed"; then
    echo "$trimmed"
    return
  fi

  cat <<EOF
Process Log
- Claude returned a successful response without the required delegate report headings.
- The delegate wrapper normalized that response into the required structured report envelope.

Summary
Claude completed successfully, but its final response did not use the required report template. The original response is preserved under Final Result.

Changed Files
Unknown from unstructured response; inspect git diff and raw delegate artifacts before accepting file-level conclusions.

Verification
Unknown from unstructured response; do not treat verification as proven unless the original response below lists exact commands and outcomes.

Final Result
UNSTRUCTURED_SUCCESS_NORMALIZED
${trimmed}

Risks Or Follow-ups
- Review the raw stream, trace, and repository diff before accepting verification-sensitive changes.
EOF
}

# get_claude_delegate_output_resolution FINAL_TEXT OUTPUT_PATH EXIT_CODE SAW_RESULT_SUCCESS CAPTURED_FINAL_RESULT_HEADING
# Outputs a JSON object with resolution fields.
get_claude_delegate_output_resolution() {
  local final_text="${1:-}"
  local output_path="${2:-}"
  local exit_code="$3"
  local saw_result_success="$4"
  local captured_final_result_heading="$5"

  local final_text_has_final_result="false"
  if test_claude_delegate_text_has_final_result_heading "$final_text" 2>/dev/null; then
    final_text_has_final_result="true"
  fi

  local existing_structured_output="false"
  if test_claude_delegate_has_final_result "$output_path" 2>/dev/null; then
    existing_structured_output="true"
  fi

  local output_was_normalized="false"
  if [[ "$exit_code" -eq 0 && "$saw_result_success" == "true" && \
        "$final_text_has_final_result" == "false" && \
        "$existing_structured_output" == "false" && \
        -n "$final_text" ]]; then
    output_was_normalized="true"
  fi

  local persisted_final_text
  if [[ "$output_was_normalized" == "true" ]]; then
    persisted_final_text="$(convert_claude_delegate_unstructured_final_text "$final_text")"
  else
    persisted_final_text="$final_text"
  fi

  local persisted_text_has_final_result="false"
  if test_claude_delegate_text_has_final_result_heading "$persisted_final_text" 2>/dev/null; then
    persisted_text_has_final_result="true"
  fi

  local should_persist_final_text="false"
  if [[ "$persisted_text_has_final_result" == "true" ]]; then
    should_persist_final_text="true"
  elif [[ "$existing_structured_output" == "false" && -n "$final_text" ]]; then
    should_persist_final_text="true"
  fi

  local delegate_succeeded="false"
  if [[ "$exit_code" -eq 0 && "$saw_result_success" == "true" ]]; then
    if [[ "$captured_final_result_heading" == "true" || \
          "$persisted_text_has_final_result" == "true" || \
          "$existing_structured_output" == "true" ]]; then
      delegate_succeeded="true"
    fi
  fi

  # Export results via global variables (bash limitation for complex returns)
  _RESOLUTION_FINAL_TEXT_HAS_FINAL_RESULT="$final_text_has_final_result"
  _RESOLUTION_EXISTING_STRUCTURED_OUTPUT="$existing_structured_output"
  _RESOLUTION_OUTPUT_WAS_NORMALIZED="$output_was_normalized"
  _RESOLUTION_PERSISTED_FINAL_TEXT="$persisted_final_text"
  _RESOLUTION_SHOULD_PERSIST_FINAL_TEXT="$should_persist_final_text"
  _RESOLUTION_DELEGATE_SUCCEEDED="$delegate_succeeded"
}

# test_claude_delegate_pid_alive PID
# Returns 0 if the process is alive.
test_claude_delegate_pid_alive() {
  local pid="${1:-}"
  if [[ -z "$pid" || "$pid" -le 0 ]] 2>/dev/null; then
    return 1
  fi
  kill -0 "$pid" 2>/dev/null
}

# test_claude_delegate_path_writable PATH
# Checks the path is writable. Exits with error if not.
test_claude_delegate_path_writable() {
  local path="$1"
  local full_path
  full_path="$(cd "$(dirname "$path")" 2>/dev/null && pwd)/$(basename "$path")" || full_path="$path"
  local dir
  dir="$(dirname "$full_path")"
  mkdir -p "$dir"

  local probe_path="${dir}/.write_probe_$(uuidgen | tr -d '-' | head -c 12).tmp"
  if ! printf 'ok' > "$probe_path" 2>/dev/null; then
    echo "ERROR: Path is not writable: $full_path" >&2
    exit 1
  fi
  rm -f "$probe_path"
}

# update_claude_delegate_stream_capture RECORD_JSON
# Processes a stream-json record and updates global capture state variables.
# Global state variables (must be initialized before first call):
#   _CAPTURE_ASSISTANT_TEXTS (newline-separated)
#   _CAPTURE_TRACE_LINES (newline-separated)
#   _CAPTURE_FINAL_TEXT
#   _CAPTURE_SAW_ASSISTANT_TEXT (true/false)
#   _CAPTURE_SAW_RESULT_SUCCESS (true/false)
#   _CAPTURE_CAPTURED_FINAL_RESULT_HEADING (true/false)
# Returns trace lines via _STREAM_TRACE_LINES
update_claude_delegate_stream_capture() {
  local record_json="$1"
  _STREAM_TRACE_LINES=""

  local record_type
  record_type="$(echo "$record_json" | jq -r '.type // ""' 2>/dev/null)" || record_type=""

  case "$record_type" in
    system)
      local subtype status
      subtype="$(echo "$record_json" | jq -r '.subtype // ""' 2>/dev/null)" || subtype=""
      status="$(echo "$record_json" | jq -r '.status // ""' 2>/dev/null)" || status=""
      local line="[system]"
      [[ -n "$subtype" ]] && line="$line $subtype"
      [[ -n "$status" ]] && line="$line $status"
      _STREAM_TRACE_LINES="$line"
      ;;
    assistant)
      local message_id texts
      message_id="$(echo "$record_json" | jq -r '.message.id // ""' 2>/dev/null)" || message_id=""
      # Extract text blocks from message.content array
      texts="$(echo "$record_json" | jq -r '
        [.message.content[]? | select(.type == "text" and .text != null and .text != "") | .text] | join("\n")
      ' 2>/dev/null)" || texts=""

      if [[ -n "$message_id" ]]; then
        _STREAM_TRACE_LINES="[assistant] message=$message_id"
      else
        _STREAM_TRACE_LINES="[assistant]"
      fi

      local trimmed_text
      trimmed_text="$(echo "$texts" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
      if [[ -n "$trimmed_text" ]]; then
        _CAPTURE_SAW_ASSISTANT_TEXT="true"
        if test_claude_delegate_text_has_final_result_heading "$trimmed_text" 2>/dev/null; then
          _CAPTURE_CAPTURED_FINAL_RESULT_HEADING="true"
        fi
        if [[ -n "$_CAPTURE_ASSISTANT_TEXTS" ]]; then
          _CAPTURE_ASSISTANT_TEXTS="${_CAPTURE_ASSISTANT_TEXTS}
---ASSISTANT_TEXT_SEPARATOR---
${trimmed_text}"
        else
          _CAPTURE_ASSISTANT_TEXTS="$trimmed_text"
        fi
        _CAPTURE_FINAL_TEXT="$trimmed_text"
      fi
      ;;
    result)
      local subtype cost
      subtype="$(echo "$record_json" | jq -r '.subtype // ""' 2>/dev/null)" || subtype=""
      cost="$(echo "$record_json" | jq -r '.cost_usd // ""' 2>/dev/null)" || cost=""
      local line="[result]"
      [[ -n "$subtype" ]] && line="$line $subtype"
      [[ -n "$cost" ]] && line="$line cost=$cost"
      if [[ "$subtype" == "success" ]]; then
        _CAPTURE_SAW_RESULT_SUCCESS="true"
      fi
      _STREAM_TRACE_LINES="$line"
      ;;
    stream_event)
      local event_type
      event_type="$(echo "$record_json" | jq -r '.event.type // ""' 2>/dev/null)" || event_type=""
      if [[ -n "$event_type" ]]; then
        _STREAM_TRACE_LINES="[stream] $event_type"
      else
        _STREAM_TRACE_LINES="[stream]"
      fi
      ;;
    *)
      if [[ -n "$record_type" ]]; then
        _STREAM_TRACE_LINES="[$record_type]"
      else
        _STREAM_TRACE_LINES="[unknown-record]"
      fi
      ;;
  esac

  # Append trace lines to global trace
  if [[ -n "$_STREAM_TRACE_LINES" ]]; then
    if [[ -n "$_CAPTURE_TRACE_LINES" ]]; then
      _CAPTURE_TRACE_LINES="${_CAPTURE_TRACE_LINES}
${_STREAM_TRACE_LINES}"
    else
      _CAPTURE_TRACE_LINES="$_STREAM_TRACE_LINES"
    fi
  fi
}

# new_claude_delegate_cli_args MODEL SESSION_NAME SESSION_ID RESUME MAX_BUDGET_USD BYPASS_PERMISSIONS PROMPT_TEXT
# Prints CLI arguments, one per line.
new_claude_delegate_cli_args() {
  local model="$1"
  local session_name="$2"
  local session_id="$3"
  local resume="$4"
  local max_budget_usd="${5:-}"
  local bypass_permissions="$6"
  local prompt_text="$7"

  echo "--verbose"
  echo "--print"
  echo "--output-format"
  echo "stream-json"
  echo "--model"
  echo "$model"
  echo "--name"
  echo "$session_name"
  echo "--permission-mode"
  echo "acceptEdits"

  if [[ "$resume" == "true" ]]; then
    echo "--resume"
    echo "$session_id"
  else
    echo "--session-id"
    echo "$session_id"
  fi

  if [[ -n "$max_budget_usd" && "$max_budget_usd" != "null" ]]; then
    echo "--max-budget-usd"
    echo "$max_budget_usd"
  fi

  if [[ "$bypass_permissions" == "true" ]]; then
    echo "--dangerously-skip-permissions"
  fi

  echo "$prompt_text"
}

# get_claude_delegate_non_json_raw_lines RAW_LINES_FILE
# Extracts non-JSON lines from a file of raw output lines.
# Prints non-JSON lines to stdout.
get_claude_delegate_non_json_raw_lines_from_file() {
  local file="$1"
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "${line// /}" ]] && continue
    if ! echo "$line" | jq empty 2>/dev/null; then
      echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
    fi
  done < "$file"
}

# get_claude_delegate_non_json_raw_lines_from_string RAW_LINES_STRING
# Same as above but from a string (lines separated by newlines).
get_claude_delegate_non_json_raw_lines_from_string() {
  local raw="$1"
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "${line// /}" ]] && continue
    if ! echo "$line" | jq empty 2>/dev/null; then
      echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
    fi
  done <<< "$raw"
}

# get_claude_delegate_retry_decision RAW_LINES_STRING RESUME_ATTEMPT EXIT_CODE SAW_ASSISTANT_TEXT SAW_RESULT_SUCCESS CAPTURED_FINAL_RESULT_HEADING
# Sets global variables for the decision:
#   _RETRY_SHOULD_RETRY (true/false)
#   _RETRY_REASON
#   _RETRY_WITH_FRESH_SESSION (true/false)
#   _RETRY_SAW_STALE_SESSION_TEXT (true/false)
#   _RETRY_SAW_STREAM_JSON_VERBOSE_ERROR (true/false)
#   _RETRY_HAS_STRUCTURED_SUCCESS (true/false)
get_claude_delegate_retry_decision() {
  local raw_lines="$1"
  local resume_attempt="$2"
  local exit_code="$3"
  local saw_assistant_text="$4"
  local saw_result_success="$5"
  local captured_final_result_heading="$6"

  local joined
  joined="$(get_claude_delegate_non_json_raw_lines_from_string "$raw_lines")"

  local saw_stale="false"
  if echo "$joined" | grep -q 'No conversation found.*session ID'; then
    saw_stale="true"
  fi

  local saw_stream_json="false"
  if echo "$joined" | grep -q 'stream-json.*requires.*--verbose'; then
    saw_stream_json="true"
  fi

  local has_structured_success="false"
  if [[ "$saw_result_success" == "true" && "$captured_final_result_heading" == "true" ]]; then
    has_structured_success="true"
  fi

  _RETRY_SHOULD_RETRY="false"
  _RETRY_REASON=""
  _RETRY_WITH_FRESH_SESSION="false"
  _RETRY_SAW_STALE_SESSION_TEXT="$saw_stale"
  _RETRY_SAW_STREAM_JSON_VERBOSE_ERROR="$saw_stream_json"
  _RETRY_HAS_STRUCTURED_SUCCESS="$has_structured_success"

  if [[ "$resume_attempt" == "true" && "$saw_stale" == "true" && "$has_structured_success" == "false" ]]; then
    _RETRY_SHOULD_RETRY="true"
    _RETRY_REASON="stale_claude_session"
    _RETRY_WITH_FRESH_SESSION="true"
    return
  fi

  if [[ "$saw_stream_json" == "true" && "$has_structured_success" == "false" ]]; then
    _RETRY_SHOULD_RETRY="true"
    _RETRY_REASON="stream_json_startup"
    _RETRY_WITH_FRESH_SESSION="false"
    return
  fi
}

# get_claude_delegate_failure_summary RAW_LINES_STRING RETRY_REASON ATTEMPT_COUNT MAX_RETRY_COUNT EXIT_CODE
# Prints failure summary to stdout.
get_claude_delegate_failure_summary() {
  local raw_lines="$1"
  local retry_reason="${2:-unknown_retry_condition}"
  local attempt_count="$3"
  local max_retry_count="$4"
  local exit_code="$5"

  [[ -z "$retry_reason" ]] && retry_reason="unknown_retry_condition"

  local error_lines
  error_lines="$(get_claude_delegate_non_json_raw_lines_from_string "$raw_lines" | sort -u | head -2)"
  local error_snippet
  if [[ -n "$error_lines" ]]; then
    error_snippet="$(echo "$error_lines" | tr '\n' '|' | sed 's/|$//; s/|/ | /g')"
  else
    error_snippet="No non-JSON stderr summary was captured."
  fi

  local max_attempts=$((max_retry_count + 1))
  echo "NEED_HUMAN_INTERVENTION after exhausting retry budget. retryReason=${retry_reason}. attempt ${attempt_count}/${max_attempts}. exitCode=${exit_code}. ${error_snippet}"
}

# test_claude_delegate_needs_fresh_session_retry RAW_LINES_STRING RESUME_ATTEMPT
# Returns 0 (true) if a fresh session retry is needed.
test_claude_delegate_needs_fresh_session_retry() {
  local raw_lines="$1"
  local resume_attempt="$2"

  get_claude_delegate_retry_decision "$raw_lines" "$resume_attempt" 1 "false" "false" "false"
  [[ "$_RETRY_SHOULD_RETRY" == "true" && "$_RETRY_WITH_FRESH_SESSION" == "true" ]]
}
