#!/usr/bin/env bash
# run_real_delegate_chain_validation.sh — Scaffolds a set of real delegate tasks to validate the entire subagent chain.
# Ported from windows_scripts/run_real_delegate_chain_validation.ps1.

set -euo pipefail

usage() {
  echo "Usage: run_real_delegate_chain_validation.sh [--validation-root PATH] [--name NAME] [--session-key KEY]"
  exit 1
}

VALIDATION_ROOT=""
NAME=""
SESSION_KEY=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --validation-root|-ValidationRoot) VALIDATION_ROOT="$2"; shift 2 ;;
    --name|-Name) NAME="$2"; shift 2 ;;
    --session-key|-SessionKey) SESSION_KEY="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

if [[ -z "$VALIDATION_ROOT" ]]; then
  VALIDATION_ROOT="$REPO_ROOT/.codex/codex_with_cc/claude-delegate-validation"
fi
if [[ -z "$NAME" ]]; then
  NAME="$(date +"%Y%m%d-%H%M%S")-real-chain"
fi
if [[ -z "$SESSION_KEY" ]]; then
  SESSION_KEY="delegate-real-chain-$(uuidgen | tr -d '-' | head -c 12 | tr '[:upper:]' '[:lower:]')"
fi

RESOLVED_VALIDATION_ROOT="$(cd "$(dirname "$VALIDATION_ROOT")" 2>/dev/null && pwd || echo "$PWD")/$(basename "$VALIDATION_ROOT")"
if [[ -d "$VALIDATION_ROOT" ]]; then
  RESOLVED_VALIDATION_ROOT="$(cd "$VALIDATION_ROOT" && pwd)"
fi

CHAIN_ROOT="$RESOLVED_VALIDATION_ROOT/$NAME"
ARTIFACT_ROOT="$CHAIN_ROOT/artifacts"
TASK_ROOT="$CHAIN_ROOT/tasks"
TASK_DATE="$(date +"%Y%m%d")"
TASK_BATCH_ID="$(date +"%H%M%S")-$(uuidgen | tr -d '-' | head -c 6 | tr '[:upper:]' '[:lower:]')"
DATED_TASK_ROOT="$TASK_ROOT/$TASK_DATE"

mkdir -p "$ARTIFACT_ROOT"
mkdir -p "$DATED_TASK_ROOT"

# Arrays of task definitions
declare -a TASK_FILES=(
  "anchor-read-protocol.md"
  "parallel-artifact-audit.md"
  "parallel-stream-audit.md"
  "reuse-cross-check-1.md"
  "reuse-cross-check-2.md"
)

get_task_mode() {
  case "$1" in
    "anchor-read-protocol.md") echo "PrimaryAnchor" ;;
    "parallel-artifact-audit.md") echo "ParallelPool" ;;
    "parallel-stream-audit.md") echo "ParallelPool" ;;
    "reuse-cross-check-1.md") echo "PrimaryReuse" ;;
    "reuse-cross-check-2.md") echo "PrimaryReuse" ;;
  esac
}

get_task_flags() {
  case "$1" in
    "anchor-read-protocol.md") echo "--session-mode PrimaryAnchor --allow-parallel" ;;
    "parallel-artifact-audit.md") echo "--session-mode ParallelPool --allow-parallel" ;;
    "parallel-stream-audit.md") echo "--session-mode ParallelPool --allow-parallel" ;;
    "reuse-cross-check-1.md") echo "--session-mode PrimaryReuse" ;;
    "reuse-cross-check-2.md") echo "--session-mode PrimaryReuse" ;;
  esac
}

get_task_scopes() {
  case "$1" in
    "anchor-read-protocol.md") echo "docs/codex_with_cc/macos_scripts/delegate_to_claude.sh;docs/codex_with_cc/macos_scripts/claude_session_pool.sh;docs/codex_with_cc/CODEX_WITH_CC.md" ;;
    "parallel-artifact-audit.md") echo "docs/codex_with_cc/macos_scripts/verify_delegate_artifacts.sh;docs/codex_with_cc/macos_scripts/verify_delegate_chain.sh;.codex/codex_with_cc/claude-delegate" ;;
    "parallel-stream-audit.md") echo "docs/codex_with_cc/macos_scripts/claude_delegate_backend_helpers.sh;.codex/codex_with_cc/claude-delegate" ;;
    "reuse-cross-check-1.md") echo "docs/codex_with_cc/macos_scripts/delegate_to_claude.sh;docs/codex_with_cc/macos_scripts/claude_delegate_backend_helpers.sh;docs/codex_with_cc/macos_scripts/claude_session_pool.sh;docs/codex_with_cc/macos_scripts/verify_delegate_artifacts.sh;docs/codex_with_cc/macos_scripts/verify_delegate_chain.sh;docs/codex_with_cc/macos_scripts/run_real_delegate_chain_validation.sh;docs/codex_with_cc/macos_scripts/test_delegate_runtime.sh;docs/codex_with_cc/macos_scripts/test_delegate_session_pool.sh;docs/codex_with_cc/CODEX_WITH_CC.md" ;;
    "reuse-cross-check-2.md") echo "docs/codex_with_cc/macos_scripts/delegate_to_claude.sh;docs/codex_with_cc/macos_scripts/claude_delegate_backend_helpers.sh;docs/codex_with_cc/macos_scripts/claude_session_pool.sh;docs/codex_with_cc/macos_scripts/verify_delegate_artifacts.sh;docs/codex_with_cc/macos_scripts/verify_delegate_chain.sh;docs/codex_with_cc/macos_scripts/run_real_delegate_chain_validation.sh;docs/codex_with_cc/macos_scripts/test_delegate_runtime.sh;docs/codex_with_cc/macos_scripts/test_delegate_session_pool.sh;docs/codex_with_cc/CODEX_WITH_CC.md" ;;
  esac
}

get_task_tests() {
  case "$1" in
    "anchor-read-protocol.md") echo "bash docs/codex_with_cc/macos_scripts/verify_delegate_artifacts.sh --run-id <anchor-run-id> --artifact-root '\$ARTIFACT_ROOT'" ;;
    "parallel-artifact-audit.md") echo "bash docs/codex_with_cc/macos_scripts/verify_delegate_artifacts.sh --run-id <parallel-a-run-id> --artifact-root '\$ARTIFACT_ROOT'" ;;
    "parallel-stream-audit.md") echo "bash docs/codex_with_cc/macos_scripts/verify_delegate_artifacts.sh --run-id <parallel-b-run-id> --artifact-root '\$ARTIFACT_ROOT'" ;;
    "reuse-cross-check-1.md") echo "bash docs/codex_with_cc/macos_scripts/verify_delegate_artifacts.sh --run-id <reuse-1-run-id> --artifact-root '\$ARTIFACT_ROOT'" ;;
    "reuse-cross-check-2.md") echo "bash docs/codex_with_cc/macos_scripts/verify_delegate_artifacts.sh --run-id <reuse-2-run-id> --artifact-root '\$ARTIFACT_ROOT'" ;;
  esac
}

get_task_desc() {
  case "$1" in
    "anchor-read-protocol.md") echo "只读验证任务：通过 Codex spawn_agent 子线程承载 Claude worker，审查 delegate_to_claude.sh 与 claude_session_pool.sh 的主线锚点行为。

要求：
- 只读，不修改任何仓库文件。
- 聚焦 PrimaryAnchor 如何建立主线 session、如何与后续 PrimaryReuse 续接。
- 输出必须包含 Process Log / Summary / Changed Files / Verification / Final Result / Risks Or Follow-ups。" ;;
    "parallel-artifact-audit.md") echo "只读验证任务：审查新 schema delegate artifacts 与 verify_delegate_artifacts.sh 的契约要求。

要求：
- 只读，不修改任何仓库文件。
- 聚焦 artifactSchema / invocationContract / attempts[] / initialSessionId / initialResume 等字段是否支撑新链路验收。
- 输出必须包含 Process Log / Summary / Changed Files / Verification / Final Result / Risks Or Follow-ups。" ;;
    "parallel-stream-audit.md") echo "只读验证任务：审查 claude_delegate_backend_helpers.sh 的 stream capture、retry decision 与 trace/rawStream 行为。

要求：
- 只读，不修改任何仓库文件。
- 聚焦 stale-session、stream-json startup、structured Final Result 判定与日志可读性。
- 输出必须包含 Process Log / Summary / Changed Files / Verification / Final Result / Risks Or Follow-ups。" ;;
    "reuse-cross-check-1.md") echo "真实复核/返工任务：在锚点与并发旁路完成后，使用同一 SessionKey 续接主线，对前三份结果做交叉复核。

要求：
- 先复核，不做无关修改。
- 必须确认 PrimaryReuse 优先尝试 resume=true；如果恢复为 fresh session，必须解释审计链。
- 如果发现真实缺陷，允许在允许范围内修改仓库文件，并补齐最小必要测试。
- 如果修改任何仓库文件，必须遵守 docs/codex_with_cc/CODEX_WITH_CC.md 中的工作流约束，并在 Verification 中列出实际运行的验证命令。
- 输出必须包含 Process Log / Summary / Changed Files / Verification / Final Result / Risks Or Follow-ups。" ;;
    "reuse-cross-check-2.md") echo "只读验证任务：再次在同一 SessionKey 下顺序续接主线，验证高缓存命中不是偶发成功。

要求：
- 只读，不修改任何仓库文件。
- 必须复核主线 session 是否连续、并发池租约是否释放、lastTaskFingerprint 是否保留。
- 如果发现仍有问题，明确指出需要进入新的串行返工轮次，不要做范围外修改。
- 输出必须包含 Process Log / Summary / Changed Files / Verification / Final Result / Risks Or Follow-ups。" ;;
  esac
}

for file in "${TASK_FILES[@]}"; do
  task_file_name="${TASK_BATCH_ID}-${file}"
  task_path="$DATED_TASK_ROOT/$task_file_name"
  
  t_mode="$(get_task_mode "$file")"
  t_flags="$(get_task_flags "$file")"
  t_scopes="$(get_task_scopes "$file")"
  t_tests="$(get_task_tests "$file")"
  t_desc="$(get_task_desc "$file")"
  
  cat <<EOF > "$task_path"
# Real Delegate Chain Validation Task

- SessionKey: $SESSION_KEY
- ArtifactRoot: $ARTIFACT_ROOT
- SessionMode: ${t_mode}
- Child-thread only: This task must run inside a Codex spawn_agent child thread with model 'gpt-5.3-codex', reasoning_effort 'medium', fork_context 'false'.
- Required child-thread marker: set process environment CODEX_CLAUDE_CHILD_THREAD=1 before invoking the worker entry script.
- Worker entry script: docs/codex_with_cc/macos_scripts/delegate_to_claude.sh
- Required worker arguments: --task-file "$task_path" --artifact-root "$ARTIFACT_ROOT" --session-key "$SESSION_KEY" ${t_flags} --bypass-permissions

Allowed scope:
${t_scopes}

Verification command to run after this task completes:
${t_tests}

${t_desc}
EOF
done

cat <<EOF
Real delegate chain validation scaffold created.

Validation Root: $CHAIN_ROOT
Artifact Root: $ARTIFACT_ROOT
Task Root: $TASK_ROOT
Task Date Root: $DATED_TASK_ROOT
Session Key: $SESSION_KEY

Required Codex orchestration rules:
- The Codex main thread may only create spawn_agent child threads and collect results.
- Every Claude worker must run inside a child thread with:
  - model: gpt-5.3-codex
  - reasoning_effort: medium
  - fork_context: false
- Every child thread must set CODEX_CLAUDE_CHILD_THREAD=1 and then call docs/codex_with_cc/macos_scripts/delegate_to_claude.sh with --task-file.
- Do not run Claude CLI or delegate_to_claude.sh directly from the main thread.

Recommended execution order:
1. Child thread: ${TASK_BATCH_ID}-anchor-read-protocol.md (PrimaryAnchor)
2. Child thread: ${TASK_BATCH_ID}-parallel-artifact-audit.md (ParallelPool)
3. Child thread: ${TASK_BATCH_ID}-parallel-stream-audit.md (ParallelPool)
4. Wait for the anchor + both parallel runs to finish
5. Child thread: ${TASK_BATCH_ID}-reuse-cross-check-1.md (PrimaryReuse)
6. Child thread: ${TASK_BATCH_ID}-reuse-cross-check-2.md (PrimaryReuse)

Post-run verification commands:
- bash docs/codex_with_cc/macos_scripts/verify_delegate_artifacts.sh --run-id <anchor-run-id> --artifact-root "$ARTIFACT_ROOT"
- bash docs/codex_with_cc/macos_scripts/verify_delegate_artifacts.sh --run-id <parallel-a-run-id> --artifact-root "$ARTIFACT_ROOT"
- bash docs/codex_with_cc/macos_scripts/verify_delegate_artifacts.sh --run-id <parallel-b-run-id> --artifact-root "$ARTIFACT_ROOT"
- bash docs/codex_with_cc/macos_scripts/verify_delegate_artifacts.sh --run-id <reuse-1-run-id> --artifact-root "$ARTIFACT_ROOT"
- bash docs/codex_with_cc/macos_scripts/verify_delegate_artifacts.sh --run-id <reuse-2-run-id> --artifact-root "$ARTIFACT_ROOT"
- bash docs/codex_with_cc/macos_scripts/verify_delegate_chain.sh --artifact-root "$ARTIFACT_ROOT" --session-key "$SESSION_KEY" --anchor-run-id <anchor-run-id> --parallel-run-ids "<parallel-a-run-id>,<parallel-b-run-id>" --reuse-run-ids "<reuse-1-run-id>,<reuse-2-run-id>"
EOF
