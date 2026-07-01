#!/usr/bin/env bash
# PreToolUse(Agent) WARN-only nudge: remind the lead to route fitting build/review
# tasks to Codex when a repo has opted into codex_enabled: true. NEVER blocks/denies —
# purely informational stderr reminder. Mirrors leadv2-block-codex.sh's cwd/policy
# resolution so behavior stays consistent across hooks.
set -euo pipefail
trap 'echo "[$(basename "$0")] error at line $LINENO" >&2; exit 0' ERR

INPUT="$(cat 2>/dev/null || true)"
[[ -z "$INPUT" ]] && exit 0

TOOL_NAME="$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || echo "")"
[[ "$TOOL_NAME" != "Agent" ]] && exit 0

SUBTYPE="$(echo "$INPUT" | jq -r '.tool_input.subagent_type // empty' 2>/dev/null || echo "")"
[[ -z "$SUBTYPE" ]] && exit 0

SUBTYPE_LOWER="$(echo "$SUBTYPE" | tr '[:upper:]' '[:lower:]')"

# Already routed to Codex -> nothing to nudge.
[[ "$SUBTYPE_LOWER" == *codex* ]] && exit 0

# Only nudge for build/review roles Codex is first-class for.
case "$SUBTYPE_LOWER" in
  *developer*|*postgres*|*frontend*|*critic*|*security*) ;;
  *) exit 0 ;;
esac

CWD="$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || echo "")"
[[ -z "$CWD" ]] && CWD="$PWD"

PROJECT_ROOT="${CLAUDE_PROJECT_ROOT:-$(cd "$CWD" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null || echo "$CWD")}"
POLICY="$PROJECT_ROOT/.claude/leadv2-overrides/codex-policy.yaml"

# No policy file, or codex_enabled not true -> stay silent (this repo hasn't opted in).
[[ -f "$POLICY" ]] || exit 0
grep -qE '^[[:space:]]*codex_enabled:[[:space:]]*true' "$POLICY" 2>/dev/null || exit 0

echo "[leadv2-codex-first-nudge] REMINDER: codex_enabled: true in $POLICY -- consider routing this task (subagent_type=$SUBTYPE) to Codex first (codex-task.sh) before Claude quota. See docs/model-routing.md." >&2

exit 0
