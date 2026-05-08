#!/usr/bin/env bash
# install_codex_with_cc.sh — macOS installer for codex_with_cc workflow.
# Ported from install_codex_with_cc.ps1.
set -euo pipefail

INSTALLER_ROOT="$(cd "$(dirname "$0")" && pwd)"
TARGET_ROOT=""
PLATFORM="Auto"
SKIP_AGENT_ENTRYPOINTS=false

usage() {
  echo "Usage: $0 [--target-root PATH] [--platform Auto|macOS|Windows] [--skip-agent-entrypoints]"
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target-root|-t) TARGET_ROOT="$2"; shift 2 ;;
    --platform|-p) PLATFORM="$2"; shift 2 ;;
    --skip-agent-entrypoints) SKIP_AGENT_ENTRYPOINTS=true; shift ;;
    -h|--help) usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

[[ -z "$TARGET_ROOT" ]] && TARGET_ROOT="$(pwd)"

resolve_platform() {
  if [[ "$PLATFORM" != "Auto" ]]; then echo "$PLATFORM"; return; fi
  case "$(uname -s)" in
    Darwin) echo "macOS" ;;
    MINGW*|MSYS*|CYGWIN*) echo "Windows" ;;
    *) echo "ERROR: Unsupported platform. Use --platform macOS or --platform Windows." >&2; exit 1 ;;
  esac
}

INSTALL_PLATFORM="$(resolve_platform)"
SOURCE_WORKFLOW_ROOT="$INSTALLER_ROOT/codex_with_cc"

if [[ ! -d "$SOURCE_WORKFLOW_ROOT" ]]; then
  echo "ERROR: Workflow source not found: $SOURCE_WORKFLOW_ROOT" >&2; exit 1
fi

SOURCE_WORKFLOW_ROOT="$(cd "$SOURCE_WORKFLOW_ROOT" && pwd)"
mkdir -p "$TARGET_ROOT"
TARGET_ROOT="$(cd "$TARGET_ROOT" && pwd)"
INSTALLER_ROOT="$(cd "$INSTALLER_ROOT" && pwd)"

if [[ "$INSTALLER_ROOT" == "$TARGET_ROOT" ]]; then
  echo "ERROR: Refusing to install into source repository. Choose a different --target-root." >&2; exit 1
fi

# Determine docs directory
DOCS_CANDIDATE="$TARGET_ROOT/docs"
DOC_CANDIDATE="$TARGET_ROOT/doc"
if [[ -d "$DOCS_CANDIDATE" ]] || [[ ! -d "$DOC_CANDIDATE" ]]; then
  DOCS_ROOT="$DOCS_CANDIDATE"
else
  DOCS_ROOT="$DOC_CANDIDATE"
fi

DOCS_LEAF="$(basename "$DOCS_ROOT")"
WORKFLOW_RELATIVE_PATH="${DOCS_LEAF}/codex_with_cc"
WORKFLOW_ROOT="$DOCS_ROOT/codex_with_cc"
RESOLVED_WORKFLOW_ROOT="$(mkdir -p "$WORKFLOW_ROOT" && cd "$WORKFLOW_ROOT" && pwd)"

if [[ "$SOURCE_WORKFLOW_ROOT" == "$RESOLVED_WORKFLOW_ROOT" ]]; then
  echo "ERROR: Refusing to install into source repository." >&2; exit 1
fi

# Clean old installations
for candidate in "$DOCS_CANDIDATE/codex_with_cc" "$DOC_CANDIDATE/codex_with_cc"; do
  if [[ -d "$candidate" ]]; then
    candidate_resolved="$(cd "$candidate" && pwd)"
    if [[ "$candidate_resolved" == "$SOURCE_WORKFLOW_ROOT" ]]; then
      echo "ERROR: Refusing to remove source workflow directory." >&2; exit 1
    fi
    # Ensure it's inside target root
    case "$candidate_resolved" in
      "$TARGET_ROOT"/*) rm -rf "$candidate" ;;
      *) echo "ERROR: Refusing to remove directory outside target: $candidate" >&2; exit 1 ;;
    esac
  fi
done

# Copy workflow files (platform-filtered)
EXCLUDED_DIR="windows_scripts"
EXCLUDED_ENTRY_DOC=""
PLATFORM_ENTRY_DOC=""
if [[ "$INSTALL_PLATFORM" == "Windows" ]]; then
  EXCLUDED_DIR="macos_scripts"
  EXCLUDED_ENTRY_DOC="CODEX_WITH_CC_MACOS.md"
else
  EXCLUDED_DIR="windows_scripts"
  EXCLUDED_ENTRY_DOC="CODEX_WITH_CC.md"
  PLATFORM_ENTRY_DOC="CODEX_WITH_CC_MACOS.md"
fi

mkdir -p "$DOCS_ROOT" "$WORKFLOW_ROOT"
for item in "$SOURCE_WORKFLOW_ROOT"/*; do
  local_name="$(basename "$item")"
  [[ "$local_name" == "$EXCLUDED_DIR" ]] && continue
  [[ -n "$EXCLUDED_ENTRY_DOC" && "$local_name" == "$EXCLUDED_ENTRY_DOC" ]] && continue
  cp -R "$item" "$WORKFLOW_ROOT/"
done

# On macOS, rename CODEX_WITH_CC_MACOS.md -> CODEX_WITH_CC.md
if [[ -n "$PLATFORM_ENTRY_DOC" && -f "$WORKFLOW_ROOT/$PLATFORM_ENTRY_DOC" ]]; then
  mv -f "$WORKFLOW_ROOT/$PLATFORM_ENTRY_DOC" "$WORKFLOW_ROOT/CODEX_WITH_CC.md"
fi

# Update path references in installed files
CANONICAL_PATH="docs/codex_with_cc"
if [[ "$WORKFLOW_RELATIVE_PATH" != "$CANONICAL_PATH" ]]; then
  find "$WORKFLOW_ROOT" -type f \( -name '*.md' -o -name '*.sh' -o -name '*.ps1' \) | while read -r file; do
    if grep -q "$CANONICAL_PATH" "$file" 2>/dev/null; then
      sed -i '' "s|${CANONICAL_PATH}|${WORKFLOW_RELATIVE_PATH}|g" "$file" 2>/dev/null || \
      sed -i "s|${CANONICAL_PATH}|${WORKFLOW_RELATIVE_PATH}|g" "$file"
    fi
  done
fi

# Set execute permissions on macOS scripts
if [[ "$INSTALL_PLATFORM" == "macOS" && -d "$WORKFLOW_ROOT/macos_scripts" ]]; then
  chmod +x "$WORKFLOW_ROOT/macos_scripts"/*.sh 2>/dev/null || true
fi

# Create task directory
TASK_ROOT="$TARGET_ROOT/.codex/codex_with_cc/tasks"
mkdir -p "$TASK_ROOT"
rm -f "$TASK_ROOT/.gitkeep" 2>/dev/null || true

# Update .gitignore
GITIGNORE_PATH="$TARGET_ROOT/.gitignore"
GITIGNORE_ENTRY=".codex/codex_with_cc"
if [[ -f "$GITIGNORE_PATH" ]]; then
  if ! grep -qxF "$GITIGNORE_ENTRY" "$GITIGNORE_PATH" && \
     ! grep -qxF "$GITIGNORE_ENTRY/" "$GITIGNORE_PATH"; then
    echo "" >> "$GITIGNORE_PATH"
    echo "$GITIGNORE_ENTRY" >> "$GITIGNORE_PATH"
  fi
else
  echo "$GITIGNORE_ENTRY" > "$GITIGNORE_PATH"
fi

# Update AGENTS.md
if [[ "$SKIP_AGENT_ENTRYPOINTS" != "true" ]]; then
  AGENTS_PATH="$TARGET_ROOT/AGENTS.md"
  BEGIN_MARKER="<!-- BEGIN CODEX_WITH_CC -->"
  END_MARKER="<!-- END CODEX_WITH_CC -->"
  BLOCK="${BEGIN_MARKER}
Codex with Claude Code workflow: before using this workflow, read \`${WORKFLOW_RELATIVE_PATH}/CODEX_WITH_CC.md\`.
If the task involves child agents, subagents, delegation, or any worker-execution step, you must read that file first and follow the custom \`Codex main thread -> Codex child agent -> delegate_to_claude.* -> Claude Code CLI\` workflow defined there.
${END_MARKER}"

  if [[ -f "$AGENTS_PATH" ]]; then
    content="$(cat "$AGENTS_PATH")"
    if echo "$content" | grep -q "$BEGIN_MARKER"; then
      # Replace existing block: extract before/after and reassemble
      before="$(echo "$content" | sed -n '1,/<!-- BEGIN CODEX_WITH_CC -->/{ /<!-- BEGIN CODEX_WITH_CC -->/d; p; }')"
      after="$(echo "$content" | sed -n '/<!-- END CODEX_WITH_CC -->/,${  /<!-- END CODEX_WITH_CC -->/d; p; }')"
      {
        [[ -n "$before" ]] && printf '%s\n' "$before"
        printf '%s\n' "$BLOCK"
        [[ -n "$after" ]] && printf '%s' "$after"
      } > "$AGENTS_PATH"
    else
      printf '\n\n%s\n' "$BLOCK" >> "$AGENTS_PATH"
    fi
  else
    printf '%s\n' "$BLOCK" > "$AGENTS_PATH"
  fi
  echo "Agent entrypoints updated: AGENTS.md"
fi

echo "codex_with_cc installed into: $WORKFLOW_ROOT"
echo "Next: read ${WORKFLOW_RELATIVE_PATH}/CODEX_WITH_CC.md and use it as the single workflow contract."
