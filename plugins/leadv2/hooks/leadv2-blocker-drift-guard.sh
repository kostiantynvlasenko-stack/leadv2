#!/usr/bin/env bash
# PreToolUse:Agent hook — hard-block developer spawns when the active blocker has
# shifted >= 2 times with no publish between shifts (indicates aimless chasing).
# Requires a completed Diverge phase (diverge-verdict.md) to clear the guard.
#
# State file: docs/handoff/$TASK_ID/blocker-drift.yaml
# Guard clears automatically when diverge-verdict.md exists.
#
# HARD BLOCK: exit 2 with deny JSON when shift_count >= 2 and no diverge-verdict.md.
# Fail-safe: any internal error exits 0 (never blocks session on hook crash).
#
# Override: LEADV2_BLOCKER_DRIFT_ENFORCE=0 disables this hook entirely.

set -euo pipefail
trap 'exit 0' ERR

[[ "${LEADV2_BLOCKER_DRIFT_ENFORCE:-1}" == "0" ]] && exit 0

INPUT="$(cat 2>/dev/null || true)"
[[ -z "$INPUT" ]] && exit 0

# shellcheck source=leadv2-mode-isolation.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/leadv2-mode-isolation.sh"
leadv2_hook_is_supervisor_session "$INPUT" && exit 0

# Parse subagent_type and cwd from hook input JSON
PARSED="$(python3 -c "
import sys, json
try:
    d = json.loads(sys.argv[1])
    inp = d.get('tool_input') or {}
    stype = (inp.get('subagent_type') or '').strip().lower()
    cwd   = (d.get('cwd') or '').strip()
    print(stype)
    print(cwd)
except Exception:
    pass
" "$INPUT" 2>/dev/null || true)"

[[ -z "$PARSED" ]] && exit 0

SUBTYPE="$(printf '%s' "$PARSED" | sed -n '1p')"
CWD="$(printf '%s' "$PARSED" | sed -n '2p')"
[[ -z "$CWD" ]] && CWD="$PWD"

# Only applies to build-role subagent types
case "$SUBTYPE" in
  developer|frontend-developer) ;;
  *) exit 0 ;;
esac

# Determine the phase for this lead only; active.yaml is shared.
ACTIVE_YAML=""
for _cand in "$CWD/docs/leadv2/active.yaml" "$CWD/.claude/leadv2-tasks/active.yaml"; do
  [[ -f "$_cand" ]] && { ACTIVE_YAML="$_cand"; break; }
done
ACTIVE_PHASE="$(leadv2_hook_resolve_phase "$INPUT" "$ACTIVE_YAML" 2>/dev/null || true)"

# Only enforce during build phase
case "${ACTIVE_PHASE:-}" in
  build) ;;
  *) exit 0 ;;
esac

# Resolve TASK_ID for this lead process tree.
TASK_ID="$(leadv2_hook_resolve_task_id "$INPUT" "$ACTIVE_YAML" 2>/dev/null || true)"
TASK_ID="$(printf '%s' "$TASK_ID" | tr -cd 'A-Za-z0-9._-')"
[[ -z "$TASK_ID" ]] && exit 0

HANDOFF_DIR="$CWD/docs/handoff/$TASK_ID"
DIVERGE_VERDICT="$HANDOFF_DIR/diverge-verdict.md"
DRIFT_STATE="$HANDOFF_DIR/blocker-drift.yaml"
CONTEXT_YAML="$HANDOFF_DIR/context.yaml"

# Guard clears if diverge-verdict.md exists
[[ -f "$DIVERGE_VERDICT" ]] && exit 0

# Read current_blocker and publish_count from context.yaml (fail-open on missing fields)
CURRENT_BLOCKER=""
PUBLISH_COUNT=0
if [[ -f "$CONTEXT_YAML" ]]; then
  FIELDS="$(python3 -c "
import sys
try:
    try:
        import yaml
        d = yaml.safe_load(open(sys.argv[1])) or {}
    except ImportError:
        d = {}
    print(d.get('current_blocker') or '')
    print(str(d.get('publish_count') or 0))
except Exception:
    print('')
    print('0')
" "$CONTEXT_YAML" 2>/dev/null || printf '\n0')"
  CURRENT_BLOCKER="$(printf '%s' "$FIELDS" | sed -n '1p')"
  PUBLISH_COUNT="$(printf '%s' "$FIELDS" | sed -n '2p')"
  [[ ! "$PUBLISH_COUNT" =~ ^[0-9]+$ ]] && PUBLISH_COUNT=0
fi

# Compute sha256[:12] of normalized blocker text
CURRENT_SIG=""
if [[ -n "$CURRENT_BLOCKER" ]]; then
  CURRENT_SIG="$(printf '%s' "$CURRENT_BLOCKER" | tr '[:upper:]' '[:lower:]' | tr -s ' ' | python3 -c "
import sys, hashlib
text = sys.stdin.read().strip()
print(hashlib.sha256(text.encode()).hexdigest()[:12])
" 2>/dev/null || true)"
fi

# Read or initialize drift state
LAST_SIG=""
SHIFT_COUNT=0
PUB_AT_LAST_SHIFT=0

if [[ -f "$DRIFT_STATE" ]]; then
  STATE_FIELDS="$(python3 -c "
import sys
try:
    try:
        import yaml
        d = yaml.safe_load(open(sys.argv[1])) or {}
    except ImportError:
        import re
        src = open(sys.argv[1]).read()
        def _get(k, src, default=''):
            m = re.search(rf'{k}\s*:\s*(.+)', src)
            return m.group(1).strip().strip('\"\'') if m else default
        d = {
            'last_blocker_sig': _get('last_blocker_sig', src, ''),
            'shift_count': _get('shift_count', src, '0'),
            'publish_count_at_last_shift': _get('publish_count_at_last_shift', src, '0'),
        }
    print(d.get('last_blocker_sig') or '')
    print(str(d.get('shift_count') or 0))
    print(str(d.get('publish_count_at_last_shift') or 0))
except Exception:
    print('')
    print('0')
    print('0')
" "$DRIFT_STATE" 2>/dev/null || printf '\n0\n0')"
  LAST_SIG="$(printf '%s' "$STATE_FIELDS" | sed -n '1p')"
  SHIFT_COUNT="$(printf '%s' "$STATE_FIELDS" | sed -n '2p')"
  PUB_AT_LAST_SHIFT="$(printf '%s' "$STATE_FIELDS" | sed -n '3p')"
  [[ ! "$SHIFT_COUNT" =~ ^[0-9]+$ ]] && SHIFT_COUNT=0
  [[ ! "$PUB_AT_LAST_SHIFT" =~ ^[0-9]+$ ]] && PUB_AT_LAST_SHIFT=0
fi

# Update drift state if blocker has shifted (new sig AND no publish since last shift)
if [[ -n "$CURRENT_SIG" && "$CURRENT_SIG" != "$LAST_SIG" ]]; then
  if [[ "$PUBLISH_COUNT" -le "$PUB_AT_LAST_SHIFT" ]]; then
    SHIFT_COUNT=$(( SHIFT_COUNT + 1 ))
  fi
  # Record new sig and current publish count as baseline for next comparison
  mkdir -p "$HANDOFF_DIR" 2>/dev/null || true
  python3 -c "
import sys
task_dir, sig, sc, pc = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
out = ('last_blocker_sig: ' + sig + '\n'
       'shift_count: ' + sc + '\n'
       'publish_count_at_last_shift: ' + pc + '\n')
open(task_dir + '/blocker-drift.yaml', 'w').write(out)
" -- "$HANDOFF_DIR" "$CURRENT_SIG" "$SHIFT_COUNT" "$PUBLISH_COUNT" 2>/dev/null || true
fi

# Check trigger condition
if [[ "$SHIFT_COUNT" -ge 2 ]]; then
  python3 -c "
import sys, json
task_id = sys.argv[1]
reason = (
    '[BLOCKER-DRIFT-GUARD] DENY: Blocker has shifted 2 times with no publish between shifts. '
    'Shift log: docs/handoff/' + task_id + '/blocker-drift.yaml. '
    'A Diverge phase is required before further Build. '
    'Create docs/handoff/' + task_id + '/diverge-verdict.md via /leadv2 diverge. '
    'Once diverge-verdict.md exists, this guard clears automatically. '
    'Override: LEADV2_BLOCKER_DRIFT_ENFORCE=0'
)
print(json.dumps({'hookSpecificOutput': {'hookEventName': 'PreToolUse', 'permissionDecision': 'deny', 'permissionDecisionReason': reason}}))
" -- "$TASK_ID"
  exit 2
fi

exit 0
