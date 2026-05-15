#!/usr/bin/env bash
# leadv2-immune-aggregate.sh — extract pattern_for_immune from task STATE.md files
# and write consolidated docs/leadv2/immune-patterns.yaml
set -euo pipefail
trap 'echo "[$(basename "$0")] err line $LINENO" >&2; exit 0' ERR

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TASKS_DIR="$REPO_ROOT/docs/leadv2/tasks"
OUTPUT="$REPO_ROOT/docs/leadv2/immune-patterns.yaml"
EXTRACTOR="$REPO_ROOT/.claude/scripts/leadv2-immune-aggregate.py"

python3 "$EXTRACTOR" "$TASKS_DIR" "$OUTPUT"
echo "[immune-aggregate] done → $OUTPUT"
