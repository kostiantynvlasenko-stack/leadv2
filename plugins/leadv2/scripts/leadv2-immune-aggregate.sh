#!/usr/bin/env bash
# leadv2-immune-aggregate.sh — extract pattern_for_immune from task STATE.md files
# and write consolidated docs/leadv2/immune-patterns.yaml
set -euo pipefail
trap 'echo "[$(basename "$0")] err line $LINENO" >&2; exit 0' ERR

REPO_ROOT="${LEADV2_PROJECT_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
TASKS_DIR="$REPO_ROOT/docs/leadv2/tasks"
OUTPUT="$REPO_ROOT/docs/leadv2/immune-patterns.yaml"
# Prefer plugin canonical copy; fallback to project .claude/scripts/
if [[ -n "${CLAUDE_PLUGIN_ROOT:-}" && -f "${CLAUDE_PLUGIN_ROOT}/scripts/leadv2-immune-aggregate.py" ]]; then
  EXTRACTOR="${CLAUDE_PLUGIN_ROOT}/scripts/leadv2-immune-aggregate.py"
else
  EXTRACTOR="${REPO_ROOT}/.claude/scripts/leadv2-immune-aggregate.py"
fi

python3 "$EXTRACTOR" "$TASKS_DIR" "$OUTPUT"
echo "[immune-aggregate] done → $OUTPUT"
