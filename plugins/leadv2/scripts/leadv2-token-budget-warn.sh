#!/usr/bin/env bash
# leadv2-token-budget-warn.sh — increment a per-turn tool-call counter and emit
# a visible warning when the lead exceeds the per-turn budget.
#
# Drop-in as a PreToolUse hook for the Bash / Agent / Write / Edit tools (or
# globally). Designed to be cheap (<10ms) and never block.
#
# State file: /tmp/leadv2-tool-counter.json — { "turn_id": "<id>", "count": N }
# Turn ID is read from $CLAUDE_TURN_ID if set, otherwise from $CLAUDE_SESSION_ID,
# otherwise from a hash of the parent pid (best-effort).
#
# Thresholds: 25 = soft warn, 50 = strong warn, 75 = hard reminder (suggest
# delegating to single subagent or writing directly).
#
# To enable, add to .claude/settings.json hooks:
#   "PreToolUse": [{ "matcher": "Bash|Agent|Write|Edit",
#     "command": ".claude/scripts/leadv2-token-budget-warn.sh" }]
#
# Or invoke manually at chat time:
#   bash .claude/scripts/leadv2-token-budget-warn.sh status

set -euo pipefail

STATE_FILE="/tmp/leadv2-tool-counter.json"
SOFT_WARN=25
STRONG_WARN=50
HARD_WARN=75

_turn_id() {
  echo "${CLAUDE_TURN_ID:-${CLAUDE_SESSION_ID:-$(echo "$PPID" | sha1sum | cut -c1-12)}}"
}

_emit_warning() {
  local count="$1"
  local turn_id="$2"
  local level="$3"
  cat >&2 <<EOF
[leadv2-token-budget] turn=$turn_id tool_calls=$count level=$level
  Per-founder-turn budget is <10. You are at $count.
  Options:
    - Delegate remaining work to ONE combined subagent mission (1 spawn).
    - Write/Edit small isolated files directly (no agent spawn).
    - STOP, summarize, ask founder.
  See docs/leadv2-guide.md / .claude/leadv2-overrides/extensions.md.
EOF
}

# Status mode
if [[ "${1:-}" == "status" ]]; then
  if [[ -f "$STATE_FILE" ]]; then
    jq . "$STATE_FILE"
  else
    echo '{ "turn_id": "none", "count": 0 }'
  fi
  exit 0
fi

# Reset mode (called at start of new turn)
if [[ "${1:-}" == "reset" ]]; then
  TURN_ID="$(_turn_id)"
  echo "{\"turn_id\":\"$TURN_ID\",\"count\":0}" > "$STATE_FILE"
  exit 0
fi

# Normal mode — increment + warn
TURN_ID="$(_turn_id)"
COUNT=0
if [[ -f "$STATE_FILE" ]]; then
  PREV_TURN=$(jq -r .turn_id "$STATE_FILE" 2>/dev/null || echo "")
  PREV_COUNT=$(jq -r .count "$STATE_FILE" 2>/dev/null || echo 0)
  if [[ "$PREV_TURN" == "$TURN_ID" ]]; then
    COUNT=$(( PREV_COUNT + 1 ))
  else
    COUNT=1
  fi
fi

echo "{\"turn_id\":\"$TURN_ID\",\"count\":$COUNT}" > "$STATE_FILE"

if (( COUNT == SOFT_WARN )); then
  _emit_warning "$COUNT" "$TURN_ID" "SOFT"
elif (( COUNT == STRONG_WARN )); then
  _emit_warning "$COUNT" "$TURN_ID" "STRONG"
elif (( COUNT == HARD_WARN )); then
  _emit_warning "$COUNT" "$TURN_ID" "HARD"
fi

# Never block — always exit 0
exit 0
