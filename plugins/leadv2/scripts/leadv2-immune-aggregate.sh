#!/usr/bin/env bash
# leadv2-immune-aggregate.sh — extract pattern_for_immune from task STATE.md files
# and write consolidated docs/leadv2/immune-patterns.yaml
set -euo pipefail
trap 'echo "[$(basename "$0")] err line $LINENO" >&2; exit 0' ERR

# Durable-root (fix round 1, item 8): `git rev-parse --show-toplevel` returns
# the EPHEMERAL worktree root, not the durable repo root -- the exact T1
# incident this project's CLAUDE.md warns about. Sibling script
# leadv2-immune-lookup.sh already uses the correct durable-root pattern;
# this one was never fixed when that one was. Matches it now so aggregate
# WRITES to the same path lookup READS from.
REPO_ROOT="${LEADV2_PROJECT_ROOT:-$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null | xargs dirname 2>/dev/null || pwd)}"
TASKS_DIR="$REPO_ROOT/docs/leadv2/tasks"
OUTPUT="$REPO_ROOT/docs/leadv2/immune-patterns.yaml"
# Prefer plugin canonical copy; fallback to project .claude/scripts/
if [[ -n "${CLAUDE_PLUGIN_ROOT:-}" && -f "${CLAUDE_PLUGIN_ROOT}/scripts/leadv2-immune-aggregate.py" ]]; then
  EXTRACTOR="${CLAUDE_PLUGIN_ROOT}/scripts/leadv2-immune-aggregate.py"
else
  EXTRACTOR="${REPO_ROOT}/.claude/scripts/leadv2-immune-aggregate.py"
fi

# MEM-BACKUP-RESTORE-01: flag-gated backup+integrity+restore around the
# write of $OUTPUT. Byte-identical no-op when LEADV2_MEM_BACKUP is unset/0
# (see scripts/leadv2-mem-backup.sh header for the full contract).
_MEM_BACKUP_HELPER="${_SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/leadv2-mem-backup.sh"
if [[ -f "$_MEM_BACKUP_HELPER" ]]; then
  # shellcheck source=/dev/null
  source "$_MEM_BACKUP_HELPER"
fi
# fix round 1, item 2: trailing `|| true` is load-bearing -- without it,
# mem_backup_snapshot/verify_or_restore being the FINAL command in this
# `&&` list would let a real (if currently unreachable) internal failure
# abort this set -e script before the writer/restore ever runs.
command -v mem_backup_snapshot >/dev/null 2>&1 && mem_backup_snapshot "$OUTPUT" "patterns" || true

python3 "$EXTRACTOR" "$TASKS_DIR" "$OUTPUT"

command -v mem_backup_verify_or_restore >/dev/null 2>&1 && mem_backup_verify_or_restore "$OUTPUT" "patterns" || true
echo "[immune-aggregate] done → $OUTPUT"
