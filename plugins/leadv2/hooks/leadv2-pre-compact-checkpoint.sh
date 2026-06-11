#!/usr/bin/env bash
# PreCompact hook: copy checkpoint.md -> pre-compact-resume.md before compaction.
# Resolves active task from active.yaml (same logic as leadv2-user-prompt-context.sh).
# Always exits 0 — never blocks compaction.
set -euo pipefail
trap 'exit 0' ERR

INPUT="$(cat 2>/dev/null || true)"
[[ -z "$INPUT" ]] && exit 0

CWD="$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || echo "")"
[[ -z "$CWD" ]] && CWD="$PWD"

# Resolve leadv2_dir from state-paths.yaml (mirrors user-prompt-context.sh logic)
_lv2_sp_yaml="${CWD}/.claude/leadv2-overrides/state-paths.yaml"
_lv2_leadv2_dir=$(grep -E "^[[:space:]]*leadv2_dir[[:space:]]*:" "$_lv2_sp_yaml" 2>/dev/null | head -1 | sed -E "s/^[[:space:]]*leadv2_dir[[:space:]]*:[[:space:]]*//" | sed -E "s/^['\"']//; s/['\"'][[:space:]]*$//" | tr -d '\r' || true)
[[ -z "$_lv2_leadv2_dir" || "$_lv2_leadv2_dir" == "null" || "$_lv2_leadv2_dir" == "~" ]] && _lv2_leadv2_dir="docs/leadv2"

_lv2_handoff_dir=$(grep -E "^[[:space:]]*handoff_dir[[:space:]]*:" "$_lv2_sp_yaml" 2>/dev/null | head -1 | sed -E "s/^[[:space:]]*handoff_dir[[:space:]]*:[[:space:]]*//" | sed -E "s/^['\"']//; s/['\"'][[:space:]]*$//" | tr -d '\r' || true)
[[ -z "$_lv2_handoff_dir" || "$_lv2_handoff_dir" == "null" || "$_lv2_handoff_dir" == "~" ]] && _lv2_handoff_dir="docs/handoff"

# Find active.yaml
ACTIVE_FILE=""
for f in "${CWD}/.claude/leadv2-tasks/active.yaml" "${CWD}/${_lv2_leadv2_dir}/active.yaml"; do
  [[ -f "$f" ]] && ACTIVE_FILE="$f" && break
done
[[ -z "$ACTIVE_FILE" ]] && exit 0

# Extract task_id and phase from active.yaml (same python3 inline as user-prompt-context.sh)
TID="$(python3 -c "
import yaml
try:
    d = yaml.safe_load(open('$ACTIVE_FILE')) or {}
    s = (d.get('sessions') or [])
    print(s[0].get('task_id','') if s else '')
except: print('')
" 2>/dev/null || echo "")"
[[ -z "$TID" ]] && exit 0

PHASE_NOW="$(python3 -c "
import yaml
try:
    d = yaml.safe_load(open('$ACTIVE_FILE')) or {}
    s = (d.get('sessions') or [])
    print(s[0].get('phase','?') if s else '?')
except: print('?')
" 2>/dev/null || echo "?")"

TASK_DIR="${CWD}/${_lv2_leadv2_dir}/tasks/${TID}"
CHECKPOINT="${TASK_DIR}/checkpoint.md"
RESUME="${TASK_DIR}/pre-compact-resume.md"

[[ ! -f "$CHECKPOINT" ]] && exit 0

mkdir -p "$TASK_DIR" 2>/dev/null || true

# Copy checkpoint content and append the standard post-compact instruction block
{
  cat "$CHECKPOINT"
  printf -- '\n---\n'
  printf -- 'After /compact: read %s/tasks/%s/STATE.md limit=20 and %s/%s/context.yaml limit=30.\n' \
    "$_lv2_leadv2_dir" "$TID" "$_lv2_handoff_dir" "$TID"
  printf -- 'NEVER write .py/.sh/.ts/.tsx/.sql directly. Delegate ALL code changes to developer subagents.\n'
} > "$RESUME" 2>/dev/null || true

exit 0
