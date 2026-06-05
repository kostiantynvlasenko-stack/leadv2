#!/usr/bin/env bash
# PreToolUse hook - wire leadv2-loop-detect.py as plugin-default tool-cap guard.
#
# Defaults (no env setup required for fresh install):
#   LEADV2_TOOL_HARD_LIMIT=50  block at 50 total calls per tool type
#   LEADV2_TOOL_FREQ_WARN=30   warn at 30 total calls per tool type
#   LEADV2_LOOP_DETECT=1       on by default (set to 0 to disable)
#
# WARN -> non-blocking advisory on stderr (exit 0)
# BLOCK -> deny decision JSON
# Fail-safe: any internal error exits 0 (never bricks the session).

set -euo pipefail
_LV2_D="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
trap 'echo "[$(basename "$0")] error at line $LINENO — continuing" >&2; exit 0' ERR

DETECT="${LEADV2_LOOP_DETECT:-1}"
[[ "$DETECT" == "0" ]] && exit 0

INPUT="$(cat 2>/dev/null || true)"
[[ -z "$INPUT" ]] && exit 0

TOOL_NAME="$(printf -- '%s' "$INPUT" | python3 -c "
import sys, json
try:
    r = json.loads(sys.stdin.read())
    print(r.get('tool_name', ''))
except Exception:
    pass
" 2>/dev/null || true)"
[[ -z "$TOOL_NAME" ]] && exit 0

SESSION_ID="$(printf -- '%s' "$INPUT" | python3 -c "
import sys, json
try:
    r = json.loads(sys.stdin.read())
    print(r.get('session_id', ''))
except Exception:
    pass
" 2>/dev/null || true)"
[[ -z "$SESSION_ID" ]] && exit 0

ARGS_JSON="$(printf -- '%s' "$INPUT" | python3 -c "
import sys, json
try:
    r = json.loads(sys.stdin.read())
    print(json.dumps(r.get('tool_input', {})))
except Exception:
    print('{}')
" 2>/dev/null || true)"

TASK_ID="${LEADV2_TASK_ID:-default}"

DETECT_SCRIPT=""
if [[ -n "${CLAUDE_PLUGIN_ROOT:-}" && -f "${CLAUDE_PLUGIN_ROOT}/scripts/leadv2-loop-detect.py" ]]; then
    DETECT_SCRIPT="${CLAUDE_PLUGIN_ROOT}/scripts/leadv2-loop-detect.py"
elif [[ -f "$_LV2_D/../scripts/leadv2-loop-detect.py" ]]; then
    DETECT_SCRIPT="$_LV2_D/../scripts/leadv2-loop-detect.py"
fi
[[ -z "$DETECT_SCRIPT" ]] && exit 0

export LEADV2_LOOP_DETECT="$DETECT"
export LEADV2_TOOL_FREQ_WARN="${LEADV2_TOOL_FREQ_WARN:-30}"
export LEADV2_TOOL_HARD_LIMIT="${LEADV2_TOOL_HARD_LIMIT:-50}"

# Build JSON payload safely via python3 to avoid shell quoting issues
VERDICT="$(python3 -c "
import sys, json, subprocess
tool_name = sys.argv[1]
args_json = sys.argv[2]
session_id = sys.argv[3]
task_id = sys.argv[4]
detect_script = sys.argv[5]
payload = json.dumps({
    'tool_name': tool_name,
    'args_canonical_json': args_json,
    'session_id': session_id,
    'task_id': task_id,
})
import subprocess
result = subprocess.run(['python3', detect_script], input=payload, capture_output=True, text=True, timeout=10)
print(result.stdout.strip() or 'CLEAR')
" -- "$TOOL_NAME" "$ARGS_JSON" "$SESSION_ID" "$TASK_ID" "$DETECT_SCRIPT" 2>/dev/null || echo "CLEAR")"

case "$VERDICT" in
  CLEAR*) exit 0 ;;
  WARN*)
    printf '[leadv2-loop-detect] %s\n' "$VERDICT" >&2
    exit 0
    ;;
  BLOCK*)
    python3 -c "
import sys, json
reason = sys.argv[1]
print(json.dumps({'hookSpecificOutput':{'hookEventName':'PreToolUse','permissionDecision':'deny','permissionDecisionReason':f'TOOL_CAP: {reason}. Override: export LEADV2_TOOL_HARD_LIMIT=<n> or LEADV2_LOOP_DETECT=0'}}))
" -- "$VERDICT"
    exit 0
    ;;
  *) exit 0 ;;
esac
