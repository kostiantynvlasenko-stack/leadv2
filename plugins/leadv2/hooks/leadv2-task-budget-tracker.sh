#!/usr/bin/env bash
# PostToolUse hook (any tool): increment per-prompt tool counter.
# Pairs with user-prompt-context.sh which resets it on UserPromptSubmit.
# Surfaces "lead used N tools on previous turn" on next prompt.
set -euo pipefail
trap 'echo "[$(basename "$0")] error at line $LINENO" >&2; exit 0' ERR

INPUT="$(cat 2>/dev/null || true)"
[[ -z "$INPUT" ]] && exit 0

SESSION_ID="$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || echo "")"
[[ -z "$SESSION_ID" ]] && exit 0

BUDGET_FILE="/tmp/.leadv2-budget-${SESSION_ID}"
PREV="$(cat "$BUDGET_FILE" 2>/dev/null || echo '0|0')"
PREV_TOOLS="${PREV%|*}"
PREV_TOTAL_TYPED="${PREV#*|}"
NEW_TOOLS=$((PREV_TOOLS + 1))
echo "${NEW_TOOLS}|${PREV_TOTAL_TYPED}" > "$BUDGET_FILE"

# Soft warn at >50 tools per turn (not blocking, just signal in stderr)
if [[ "$NEW_TOOLS" -eq 50 ]]; then
  echo "[leadv2-budget] hit 50 tool calls on this turn — consider concluding or splitting the task" >&2
elif [[ "$NEW_TOOLS" -eq 100 ]]; then
  echo "[leadv2-budget] hit 100 tool calls on this turn — strongly recommend stopping and reporting back to founder" >&2
fi
exit 0
