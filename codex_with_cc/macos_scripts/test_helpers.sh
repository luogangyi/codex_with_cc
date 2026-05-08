#!/usr/bin/env bash
# test_helpers.sh — Test assertion functions and delegate worker invocation helper.
# Ported from windows_scripts/test_helpers.ps1.
set -euo pipefail

assert_true() {
  local condition="$1"
  local name="$2"
  if [[ "$condition" != "true" ]]; then
    echo "FAIL [$name] assertion failed" >&2
    exit 1
  fi
}

assert_equal() {
  local actual="$1"
  local expected="$2"
  local name="$3"
  if [[ "$actual" != "$expected" ]]; then
    echo "FAIL [$name] expected '$expected' but got '$actual'" >&2
    exit 1
  fi
}

assert_contains() {
  local text="$1"
  local needle="$2"
  local name="$3"
  if [[ "$text" != *"$needle"* ]]; then
    echo "FAIL [$name] text does not contain '$needle'" >&2
    exit 1
  fi
}

assert_not_contains() {
  local text="$1"
  local needle="$2"
  local name="$3"
  if [[ "$text" == *"$needle"* ]]; then
    echo "FAIL [$name] text unexpectedly contains '$needle'" >&2
    exit 1
  fi
}

# invoke_delegate_worker_script runs delegate_to_claude.sh with optional
# child-thread marker and captures exit code + output.
# Usage: invoke_delegate_worker_script [--set-child-thread-marker] [--script PATH] -- ARGS...
# Returns via global variables:
#   DELEGATE_EXIT_CODE — exit code of the delegate script
#   DELEGATE_OUTPUT    — combined stdout+stderr
invoke_delegate_worker_script() {
  local set_marker=false
  local script_path=""
  local -a args=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --set-child-thread-marker) set_marker=true; shift ;;
      --script) script_path="$2"; shift 2 ;;
      --) shift; args=("$@"); break ;;
      *) args+=("$1"); shift ;;
    esac
  done

  if [[ -z "$script_path" ]]; then
    script_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/delegate_to_claude.sh"
  fi

  local marker_name="CODEX_CLAUDE_CHILD_THREAD"
  local original_marker="${!marker_name:-}"

  DELEGATE_EXIT_CODE=0
  DELEGATE_OUTPUT=""

  if $set_marker; then
    export CODEX_CLAUDE_CHILD_THREAD="1"
  else
    unset CODEX_CLAUDE_CHILD_THREAD 2>/dev/null || true
  fi

  DELEGATE_OUTPUT=$(bash "$script_path" "${args[@]}" 2>&1) || DELEGATE_EXIT_CODE=$?

  # Restore original marker
  if [[ -n "$original_marker" ]]; then
    export CODEX_CLAUDE_CHILD_THREAD="$original_marker"
  else
    unset CODEX_CLAUDE_CHILD_THREAD 2>/dev/null || true
  fi
}
