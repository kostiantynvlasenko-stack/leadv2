#!/usr/bin/env bash
# PreToolUse:Bash -- G3 anti-polling guard.
# Blocks a second `codex-task.sh status` within 5 tool calls.
# Disable knob: LEADV2_CODEX_NOPOLL=0 (default active when unset or non-zero).
set -euo pipefail
_LV2_D="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
trap 'echo "[$(basename "$0")] error at line $LINENO" >&2; exit 0' ERR

# Respect disable knob
[[ "${LEADV2_CODEX_NOPOLL:-1}" == "0" ]] && exit 0

INPUT="$(cat 2>/dev/null || true)"
[[ -z "$INPUT" ]] && exit 0

CMD="$(printf '%s' "$INPUT" | python3 -c "
import sys, json
try:
    r = json.loads(sys.stdin.read())
    print(r.get('tool_input', {}).get('command', ''))
except Exception:
    pass
" 2>/dev/null || true)"

[[ -z "$CMD" ]] && exit 0

# Only fire on codex-task.sh status calls
[[ "$CMD" != *"codex-task.sh status"* ]] && exit 0

# State dir: use LEADV2_TASK_STATE_DIR if set, else ~/.claude/leadv2-state
_STATE_DIR="${LEADV2_TASK_STATE_DIR:-${HOME}/.claude/leadv2-state}"
mkdir -p "$_STATE_DIR"
_POLL_FILE="$_STATE_DIR/codex-nopoll-counter"

# LEADV2_TOOL_CALL_COUNT is incremented by leadv2-tool-counter.sh PostToolUse hook
_TOOL_CALL="${LEADV2_TOOL_CALL_COUNT:-0}"

_last_poll_call=0
if [[ -f "$_POLL_FILE" ]]; then
    _last_poll_call="$(cat "$_POLL_FILE" 2>/dev/null || echo 0)"
fi

_calls_since=$(( _TOOL_CALL - _last_poll_call ))

if [[ "$_last_poll_call" -gt 0 && "$_calls_since" -le 5 ]]; then
    printf '%s' "$_TOOL_CALL" > "$_POLL_FILE"
    python3 -c "
import json
print(json.dumps({
    'hookSpecificOutput': {
        'hookEventName': 'PreToolUse',
        'permissionDecision': 'deny',
        'permissionDecisionReason': (
            'leadv2-codex-nopoll-guard: codex-task.sh status was already called '
            'within the last 5 tool calls. Wait for the task-notification instead '
            'of polling. Set LEADV2_CODEX_NOPOLL=0 to disable this guard.'
        )
    }
}))
"
    exit 0
fi

# Record this poll call number
printf '%s' "$_TOOL_CALL" > "$_POLL_FILE"
exit 0
