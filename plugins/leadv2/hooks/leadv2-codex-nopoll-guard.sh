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

# Resolve task_id the same way leadv2-tool-counter.sh does (hook-input cwd ->
# active.yaml sessions[0].task_id), then read its real tool-count file.
# LEADV2_TOOL_CALL_COUNT does NOT exist (hooks are separate processes, nothing
# exports it) -- that made this guard a permanent no-op. Fail-open throughout.
_CWD="$(printf '%s' "$INPUT" | python3 -c "
import sys, json
try:
    print(json.load(sys.stdin).get('cwd', '') or '')
except Exception:
    pass
" 2>/dev/null || true)"
[[ -z "$_CWD" ]] && _CWD="$PWD"

_ACTIVE_YAML=""
for _f in "$_CWD/docs/leadv2/active.yaml" "$_CWD/.claude/leadv2-tasks/active.yaml"; do
    [[ -f "$_f" ]] && _ACTIVE_YAML="$_f" && break
done

_TASK_ID=""
if [[ -n "$_ACTIVE_YAML" ]]; then
    _TASK_ID="$(python3 - "$_ACTIVE_YAML" <<'PYEOF' 2>/dev/null || true
import sys, yaml
try:
    d = yaml.safe_load(open(sys.argv[1])) or {}
    sessions = d.get('sessions') or []
    if sessions:
        print(sessions[0].get('task_id', '').strip())
except Exception:
    pass
PYEOF
)"
fi

_TOOL_CALL=0
if [[ -n "$_TASK_ID" ]]; then
    _SAFE_ID="$(printf '%s' "$_TASK_ID" | tr -cd 'A-Za-z0-9._-')"
    if [[ -n "$_SAFE_ID" ]]; then
        _COUNT_FILE="${HOME}/.claude/state/leadv2/${_SAFE_ID}.tool-count"
        if [[ -f "$_COUNT_FILE" ]]; then
            _TOOL_CALL="$(wc -l < "$_COUNT_FILE" 2>/dev/null || echo 0)"
            _TOOL_CALL="${_TOOL_CALL// /}"
        fi
    fi
fi
[[ -z "$_TOOL_CALL" ]] && _TOOL_CALL=0

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
