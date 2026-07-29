#!/usr/bin/env bash
# PostToolUse hook (matcher ".*") — LANE-TURNCAP-CHECKPOINT-01.
#
# Runs only inside a lane dispatched by leadv2-session-runner.sh, which is
# the only caller that exports LEADV2_CLAUDE_MAX_TURNS_EFFECTIVE (the actual
# --max-turns value passed to this attempt's `claude -p`). Interactive lead
# sessions and everything else see an empty/zero value and no-op.
#
# Two jobs, both keyed off the same per-task state directory:
#   1. Append every Write/Edit/MultiEdit file_path to a touched-files
#      manifest. leadv2-turncap-checkpoint-commit.sh reads this after a
#      turn-cap death to know exactly which files belong to this lane —
#      the whole point being it must never stage another lane's work in
#      this shared tree.
#   2. Warn the model as its own per-attempt turn count approaches the cap:
#      one early heads-up, then every turn inside the reserved close-out
#      tail with an explicit "stop starting new work, commit + write
#      CHECKPOINT.md" instruction.
#
# The turn counter here is attempt-scoped: leadv2-session-runner.sh removes
# COUNT_FILE before launching each attempt, so a resumed attempt starts back
# at 0 with its own fresh --max-turns budget, matching what the CLI itself
# just granted it.
#
# Fail-open: any parse error -> exit 0, never block a tool call.
# Disable: export LEADV2_TURNCAP_CHECKPOINT=0
set -euo pipefail
trap 'exit 0' ERR

[[ "${LEADV2_TURNCAP_CHECKPOINT:-1}" == "0" ]] && exit 0

CAP="${LEADV2_CLAUDE_MAX_TURNS_EFFECTIVE:-0}"
[[ "$CAP" =~ ^[0-9]+$ ]] || exit 0
[[ "$CAP" -le 0 ]] && exit 0

TASK_ID="${LEADV2_TASK_ID:-}"
[[ -z "$TASK_ID" ]] && exit 0
SAFE_ID="$(printf -- '%s' "$TASK_ID" | tr -cd 'A-Za-z0-9._-')"
[[ -z "$SAFE_ID" ]] && exit 0

INPUT="$(cat 2>/dev/null || true)"
[[ -z "$INPUT" ]] && exit 0

STATE_DIR="${LEADV2_TURNCAP_STATE_DIR:-$HOME/.claude/state/leadv2}"
mkdir -p "$STATE_DIR"
COUNT_FILE="${STATE_DIR}/${SAFE_ID}.turncap-count"
TOUCHED_FILE="${STATE_DIR}/${SAFE_ID}.touched-files"

# --- Job 1: track edited files -------------------------------------------
TOOL_NAME="$(printf -- '%s' "$INPUT" | python3 -c "
import sys, json
try:
    print(json.load(sys.stdin).get('tool_name') or '')
except Exception:
    pass
" 2>/dev/null || true)"

case "$TOOL_NAME" in
  Write|Edit|MultiEdit)
    FILE_PATH="$(printf -- '%s' "$INPUT" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print((d.get('tool_input') or {}).get('file_path') or '')
except Exception:
    pass
" 2>/dev/null || true)"
    [[ -n "$FILE_PATH" ]] && printf -- '%s\n' "$FILE_PATH" >> "$TOUCHED_FILE"
    ;;
esac

# --- Job 2: attempt-scoped turn budget signal -----------------------------
COUNT=0
[[ -f "$COUNT_FILE" ]] && COUNT="$(wc -l < "$COUNT_FILE" 2>/dev/null || printf '0')"
COUNT="${COUNT// /}"
[[ "$COUNT" =~ ^[0-9]+$ ]] || COUNT=0
COUNT=$(( COUNT + 1 ))
printf -- '%s\n' "$COUNT" >> "$COUNT_FILE"

RESERVE="${LEADV2_TURNCAP_RESERVE:-8}"
TAIL_AT=$(( CAP - RESERVE ))
EARLY_AT=$(( CAP - RESERVE * 2 ))
(( TAIL_AT < 1 )) && TAIL_AT=1
(( EARLY_AT < 1 )) && EARLY_AT=1

emit() {
  python3 -c "
import json, sys
print(json.dumps({'hookSpecificOutput': {'hookEventName': 'PostToolUse', 'additionalContext': sys.argv[1]}}))
" -- "$1"
}

if (( COUNT >= TAIL_AT )); then
  emit "[TURNCAP_RESERVED_TAIL] ${COUNT}/${CAP} turns used this attempt on ${TASK_ID} — inside the reserved close-out window (last ${RESERVE} turns). STOP starting new work. Now: (1) finish only the tool call already in progress, nothing new; (2) git add -- <only the files YOU edited this attempt> and commit, naming ${TASK_ID} in the message — never stage a file you did not touch; (3) write/update docs/handoff/${TASK_ID}/CHECKPOINT.md: what is established, what remains, file:line anchors for the next attempt; (4) state the rung reached."
elif (( COUNT == EARLY_AT )); then
  emit "[TURNCAP_BUDGET] ${COUNT}/${CAP} turns used this attempt on ${TASK_ID}. The reserved close-out window starts at turn ${TAIL_AT} — land or checkpoint the current unit of work before then."
fi

exit 0
