#!/usr/bin/env bash
# PreToolUse:Agent hook — hard-blocks new Agent spawns when per-turn tool count
# exceeds LEADV2_TOOL_BLOWUP_HARD (default 120) AND the current task phase is
# NOT in {build, plan, review} (those legitimately fan out).
# Safe exit on any read failure — never blocks when state is unavailable.
set -euo pipefail
trap 'exit 0' ERR

HARD_THRESHOLD="${LEADV2_TOOL_BLOWUP_HARD:-120}"

INPUT="$(cat 2>/dev/null || true)"
[[ -z "$INPUT" ]] && exit 0

# shellcheck source=leadv2-mode-isolation.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/leadv2-mode-isolation.sh"
leadv2_hook_is_supervisor_session "$INPUT" && exit 0

SESSION_ID="$(printf -- '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)"
[[ -z "$SESSION_ID" ]] && exit 0

# --- Read current-turn tool count from budget file ---
BUDGET_FILE="/tmp/.leadv2-budget-${SESSION_ID}"
CURRENT="$(cat "$BUDGET_FILE" 2>/dev/null || echo '0|0')"
CURRENT_TOOLS="${CURRENT%|*}"
CURRENT_TOOLS="${CURRENT_TOOLS// /}"

# Not yet at threshold — pass silently
[[ "$CURRENT_TOOLS" -lt "$HARD_THRESHOLD" ]] && exit 0

# --- At/above threshold: check current phase ---
CWD="$(printf -- '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)"
[[ -z "$CWD" ]] && CWD="$PWD"

ACTIVE_YAML=""
for f in "$CWD/docs/leadv2/active.yaml" "$CWD/.claude/leadv2-tasks/active.yaml"; do
  [[ -f "$f" ]] && ACTIVE_YAML="$f" && break
done

# No active task → can't determine phase, pass silently
[[ -z "$ACTIVE_YAML" ]] && exit 0

CURRENT_PHASE="$(leadv2_hook_resolve_phase "$INPUT" "$ACTIVE_YAML" 2>/dev/null || true)"

# Allow-listed phases: build, plan, review (legitimate fan-out)
case "$CURRENT_PHASE" in
  build|plan|review|"") exit 0 ;;
esac

# Phase is NOT in allowlist AND tool count is at/above hard threshold → block
jq -n \
  --argjson tools "$CURRENT_TOOLS" \
  --arg phase "$CURRENT_PHASE" \
  --argjson threshold "$HARD_THRESHOLD" \
  '{
    decision: "block",
    reason: ("TOOL_BLOWUP_HARD: " + ($tools | tostring) + " tool calls this turn exceeds threshold " + ($threshold | tostring) + " in phase=" + $phase + " (non-fan-out phase). Stop spawning new Agent tasks. Return to founder with summary of what was done so far.")
  }'
exit 0
