# Codex With Claude Code

This document is the portable entry point for the Codex -> Codex child agent -> Claude Code CLI workflow.

## Required Reading
1. Read this file before using the workflow in this repository.

## Core Contract
1. The Codex main thread must not run `claude` directly.
2. The Codex main thread must not run `docs/codex_with_cc/macos_scripts/delegate_to_claude.sh` directly, except for the trusted local terminal fallback below.
3. Every Claude Code delegation must be carried by a Codex `spawn_agent` child thread.
4. The child thread must set `CODEX_CLAUDE_CHILD_THREAD=1` before invoking `delegate_to_claude.sh`.
5. The child thread should use `model: gpt-5.3-codex`, `reasoning_effort: medium`, and `fork_context: false`.
6. `delegate_to_claude.sh` must not pass `--effort`; Claude Code should use its configured default effort.
7. Medium and large tasks should be written to a dated, uniquely named task file under `.codex/codex_with_cc/tasks/<yyyyMMdd>/<HHmmssfff>-<short-id>-<task-name>.md` and passed with `--task-file`.
8. Claude workers must keep changes inside the delegated scope, run the required verification, and finish with the exact report headings defined in this document.
9. If the Codex sandbox or delegated runner cannot execute the same worker command, run that exact command in a trusted local terminal instead.
10. Claude workers must read and follow all applicable Codex project skills under `.codex` before implementing or changing behavior.

## Trusted Local Terminal Fallback
This fallback is an execution-location fallback only. Preserve the same `CODEX_CLAUDE_CHILD_THREAD=1` marker, task file, session mode, session key, artifact root, and permission flags that the child thread would have used.

Do not replace this with the default Codex subagent flow, a direct `claude` command, or a modified worker command. Report that the trusted terminal fallback was used and include the command outcome in verification.

## Roles
- Codex main thread: understand the request, define scope, create child threads, review results, and decide final acceptance.
- Codex child thread: provide a visible conversation-tree node and invoke the worker script.
- Claude Code CLI: execute the delegated task, run verification, and produce a structured report.

## Session Modes
- `PrimaryReuse`: default serial mode. Reuses the main Claude session for continuity.
- `PrimaryAnchor`: parallel-batch anchor. Its result becomes the main reusable context for later serial work.
- `ParallelPool`: independent parallel side work. Uses reusable pool sessions without writing to the main session.

Only use `--allow-parallel` when task scopes are independent.

## Worker Output
Claude Code must finish with these exact headings:

```text
Process Log
Summary
Changed Files
Verification
Final Result
Risks Or Follow-ups
```

Verification must list the commands actually run and their outcomes. If verification is blocked, the report must explain the blocker and whether it is unrelated to the delegated change.

## Artifacts
Delegation artifacts are written under `.codex/codex_with_cc/claude-delegate` by default:
- `claude_<RunId>.md`
- `status_<RunId>.json`
- `config_<RunId>.json`
- `prompt_<RunId>.md`
- `stream_<RunId>.jsonl`
- `trace_<RunId>.log`
- `session-pools/<SessionKey>.json`

Use `verify_delegate_artifacts.sh` for each run and `verify_delegate_chain.sh` for multi-run continuity checks.

## Standard Worker Command
Normally run this inside a Codex child thread. If the Codex sandbox or delegated runner cannot execute it, use the trusted local terminal fallback above:

```bash
export CODEX_CLAUDE_CHILD_THREAD=1
bash ./docs/codex_with_cc/macos_scripts/delegate_to_claude.sh \
  --task-file ./.codex/codex_with_cc/tasks/<yyyyMMdd>/<HHmmssfff>-<short-id>-<task-file>.md \
  --session-mode PrimaryReuse \
  --session-key <stable-session-key> \
  --bypass-permissions
```

Use `--session-mode PrimaryAnchor --allow-parallel` for the main branch of a parallel batch and `--session-mode ParallelPool --allow-parallel` for independent side work.

## Verification
Run the local regression tests after installing or changing this workflow:

```bash
bash ./docs/codex_with_cc/macos_scripts/test_delegate_runtime.sh
bash ./docs/codex_with_cc/macos_scripts/test_delegate_session_pool.sh
```

Generate a real chain validation scaffold with:

```bash
bash ./docs/codex_with_cc/macos_scripts/run_real_delegate_chain_validation.sh
```
