#!/usr/bin/env bash
# SessionStart hook: scan for pending-close.yaml and inject a close obligation reminder.
# [R3-3 COMPACT-SURVIVE-03] Ensures the lead cannot forget phase8-close after /compact.
#
# Written by: Phase 7 verify SKILL §6a when probe_ok is reached.
# Deleted by: leadv2-phase8-close.sh on successful close.
# Contract: non-blocking, exit 0 always. stdout = JSON {additionalContext: "..."}.
set -euo pipefail
export PYTHONWARNINGS="ignore::DeprecationWarning"  # LEAD-ANCHOR-01: never let py warnings hit stderr as a hook error
trap 'exit 0' ERR

INPUT="$(cat 2>/dev/null || true)"

CWD="$(printf -- '%s' "$INPUT" | python3 -c "
import sys, json
try:
    d = json.loads(sys.stdin.read() or '{}')
    print(d.get('cwd', ''))
except Exception:
    print('')
" 2>/dev/null || true)"
[[ -z "$CWD" ]] && CWD="${CLAUDE_PROJECT_DIR:-${PWD:-}}"

# Resolve leadv2_dir (mirror pattern from leadv2-postcompact-goal-reinject.sh)
_sp_yaml="${CWD}/.claude/leadv2-overrides/state-paths.yaml"
_leadv2_dir=$(python3 -c "
import sys, re
try:
    for line in open(sys.argv[1]):
        m = re.match(r\"^\s*leadv2_dir\s*:\s*['\\\"]*([\w/._-]+)['\\\"]*(\\s.*)?$\", line)
        if m:
            print(m.group(1)); sys.exit(0)
except Exception:
    pass
print('docs/leadv2')
" "$_sp_yaml" 2>/dev/null || printf 'docs/leadv2')

_tasks_dir="${CWD}/${_leadv2_dir}/tasks"
[[ -d "$_tasks_dir" ]] || exit 0

# Find all pending-close.yaml files across all task dirs
_found="$(find "$_tasks_dir" -maxdepth 2 -name "pending-close.yaml" 2>/dev/null || true)"
[[ -z "$_found" ]] && exit 0

# Build obligation message
python3 - "$_found" << 'PYEOF'
import sys, yaml, pathlib, json

files_arg = sys.argv[1]
files = [f.strip() for f in files_arg.splitlines() if f.strip()]

msgs = []
for fp in files:
    try:
        d = yaml.safe_load(pathlib.Path(fp).read_text()) or {}
        task_id = d.get('task_id', fp)
        ctx = d.get('phase8_context', {})
        verdict = ctx.get('verdict', '?')
        created = ctx.get('created_at', '?')
        msgs.append(
            f'[CLOSE OBLIGATION] Task {task_id} completed Phase 7 (verdict={verdict}, at={created}). '
            f'You MUST run phase8-close BEFORE starting new work:\n'
            f'  bash "$(bash .claude/scripts/lv2 --path leadv2-phase8-close.sh)" {task_id}\n'
            f'  (or: LEADV2_TASK_ID={task_id} bash ... leadv2-phase8-close.sh)\n'
            f'This obligation will auto-clear when phase8-close completes.'
        )
    except Exception:
        pass

if msgs:
    full = '\n\n'.join(msgs)
    print(json.dumps({'additionalContext': full}))
PYEOF

exit 0
