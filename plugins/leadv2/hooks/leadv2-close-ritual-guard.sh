#!/usr/bin/env bash
# PreToolUse(Bash) hook: block close-style git commits when the close ritual is not complete.
#
# WHY: leads routinely commit task-close messages (e.g. "chore: close TASK-123") without
# running phase8-close.sh first, bypassing the entire learning/observability pipeline
# (reflect-history, scorecard, ledger, route-bandit). This hook hard-blocks such commits
# until docs/leadv2/closed/<task_id>.yaml AND docs/handoff/<task_id>/phase8-passed.flag
# both exist.
#
# SAFETY DESIGN (low false-positive):
#   - Only fires on git commit commands whose message matches a close pattern.
#   - Extracts task_id via narrow regex [A-Z][A-Z0-9-]+-[0-9]+; no match → allow.
#   - Escape hatch: LEADV2_SKIP_CLOSE_GUARD=1 → exit 0.
#   - Any internal error → exit 0 (never block due to guard bug).
set -euo pipefail
trap 'echo "[$(basename "$0")] error at line $LINENO, allowing" >&2; exit 0' ERR

# Escape hatch: skip guard entirely.
[[ "${LEADV2_SKIP_CLOSE_GUARD:-0}" == "1" ]] && exit 0

INPUT="$(cat 2>/dev/null || true)"
CWD="$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || echo "")"
[[ -z "$CWD" ]] && CWD="$PWD"

# Extract the Bash command from hook JSON.
CMD="$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || echo "")"
[[ -z "$CMD" ]] && exit 0

# Only care about git commit invocations.
echo "$CMD" | grep -qE '^git\s+commit' 2>/dev/null || exit 0

# Extract commit message (-m "..." or --message="...").
MSG="$(echo "$CMD" | sed -E 's/.*(-m|--message)[= ]"([^"]+)".*/\2/' 2>/dev/null || echo "")"
[[ -z "$MSG" ]] && MSG="$(echo "$CMD" | sed -E "s/.*(-m|--message)[= ]'([^']+)'.*/\2/" 2>/dev/null || echo "")"
[[ -z "$MSG" ]] && exit 0

# Check for close pattern (case-insensitive).
# Pattern requires: <type>: close <TASK-ID> where TASK-ID is [A-Z][A-Z0-9-]+-[0-9]+.
# This prevents false-positive matches on commits like "fix: close DB connection leak in FIX-123".
CLOSE_MATCH=""
CLOSE_MATCH="$(echo "$MSG" | grep -oiE '(chore|docs|feat|fix):[[:space:]]*close[[:space:]]+[A-Z][A-Z0-9-]+-[0-9]+' | head -1 || echo "")"
[[ -z "$CLOSE_MATCH" ]] && exit 0

# Extract task_id as the [A-Z][A-Z0-9-]+-[0-9]+ token immediately following 'close'.
TASK_ID="$(echo "$CLOSE_MATCH" | grep -oE '[A-Z][A-Z0-9-]+-[0-9]+' | head -1 || echo "")"
[[ -z "$TASK_ID" ]] && exit 0

# Check both ritual artifacts.
CLOSED_YAML="${CWD}/docs/leadv2/closed/${TASK_ID}.yaml"
PHASE8_FLAG="${CWD}/docs/handoff/${TASK_ID}/phase8-passed.flag"

MISSING=""
[[ ! -f "$CLOSED_YAML" ]] && MISSING="${MISSING} docs/leadv2/closed/${TASK_ID}.yaml"
[[ ! -f "$PHASE8_FLAG" ]] && MISSING="${MISSING} docs/handoff/${TASK_ID}/phase8-passed.flag"

[[ -z "$MISSING" ]] && exit 0

# Block: emit JSON decision for Claude Code hook protocol.
SCRIPT_DIR="$(dirname "$(realpath "$0")")"
PLUGIN_ROOT="$(dirname "$SCRIPT_DIR")"

jq -cn \
  --arg reason "Close ritual not complete for ${TASK_ID}. Missing:${MISSING}. Run: bash \"${PLUGIN_ROOT}/scripts/leadv2-phase8-close.sh\" ${TASK_ID} (writes scorecard/ledger/reflect + gates verify). To override: LEADV2_SKIP_CLOSE_GUARD=1" \
  '{decision:"block", reason:$reason}'
exit 2
