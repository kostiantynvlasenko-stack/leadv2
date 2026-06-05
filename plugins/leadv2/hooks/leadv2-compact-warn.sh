#!/usr/bin/env bash
# UserPromptSubmit hook — track per-session turn count; warn at >=80 turns (re-warn +40).
# NON-BLOCKING: exit 0 always. Never forces /compact.
# State file: /tmp/leadv2-turn-count-${SESSION_ID}
# Fresh install default: active with no env vars required.
#
# Disable: export LEADV2_COMPACT_WARN=0
# Change threshold: export LEADV2_COMPACT_THRESHOLD=80 (default 80)
# Change re-warn interval: export LEADV2_COMPACT_REWARN=40 (default 40)

set -euo pipefail
trap 'echo "["$0"] error at line $LINENO" >&2; exit 0' ERR

[[ "${LEADV2_COMPACT_WARN:-1}" == "0" ]] && exit 0

INPUT="$(cat 2>/dev/null || true)"
[[ -z "$INPUT" ]] && exit 0

SESSION_ID="$(printf -- '%s' "$INPUT" | python3 -c "
import sys, json
try:
    r = json.loads(sys.stdin.read())
    print(r.get('session_id', ''))
except Exception:
    pass
" 2>/dev/null || true)"
[[ -z "$SESSION_ID" ]] && exit 0

THRESHOLD="${LEADV2_COMPACT_THRESHOLD:-80}"
REWARN="${LEADV2_COMPACT_REWARN:-40}"

STATE_FILE="/tmp/leadv2-turn-count-${SESSION_ID}"
PREV="$(cat "$STATE_FILE" 2>/dev/null || echo '0')"
PREV="${PREV// /}"
[[ ! "$PREV" =~ ^[0-9]+$ ]] && PREV=0
NEW_COUNT=$(( PREV + 1 ))
printf '%d\n' "$NEW_COUNT" > "$STATE_FILE"

# Check if we should warn
if [[ "$NEW_COUNT" -ge "$THRESHOLD" ]]; then
    OVER=$(( NEW_COUNT - THRESHOLD ))
    # Warn at threshold, then re-warn every REWARN turns
    if [[ "$OVER" -eq 0 ]] || [[ $(( OVER % REWARN )) -eq 0 ]]; then
        python3 -c "
import sys, json
n, t = sys.argv[1], sys.argv[2]
print(json.dumps({
    'hookSpecificOutput': {
        'hookEventName': 'UserPromptSubmit',
        'additionalContext': f'[COMPACT_WARN] {n} turns in this session (threshold {t}) — run /compact to reset context and cut token cost.'
    }
}))
" -- "$NEW_COUNT" "$THRESHOLD"
    fi
fi

exit 0
