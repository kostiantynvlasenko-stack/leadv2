#!/usr/bin/env bash
# PostToolUse(Workflow) — touch sentinel after a Workflow completes for plan/review phases.
# This unblocks leadv2-workflow-bypass-guard for subsequent direct subagent spawns.

set -euo pipefail
trap 'exit 0' ERR

[[ "${LEADV2_WORKFLOW_ENABLED:-0}" == "1" ]] || exit 0

INPUT="$(cat 2>/dev/null || true)"
[[ -z "$INPUT" ]] && exit 0

# shellcheck source=leadv2-mode-isolation.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/leadv2-mode-isolation.sh"
leadv2_hook_is_supervisor_session "$INPUT" && exit 0

# Only fire on Workflow tool
TOOL_NAME="$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || true)"
[[ "$TOOL_NAME" == "Workflow" ]] || exit 0

CWD="$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || echo "")"
[[ -z "$CWD" ]] && CWD="$PWD"

ACTIVE_YAML=""
for _cand in "$CWD/docs/leadv2/active.yaml" "$CWD/.claude/leadv2-tasks/active.yaml"; do
  [[ -f "$_cand" ]] && { ACTIVE_YAML="$_cand"; break; }
done
ACTIVE_PHASE="$(leadv2_hook_resolve_phase "$INPUT" "$ACTIVE_YAML" 2>/dev/null || true)"
TASK_ID="$(leadv2_hook_resolve_task_id "$INPUT" "$ACTIVE_YAML" 2>/dev/null || true)"

case "${ACTIVE_PHASE:-}" in
  plan|review) ;;
  *) exit 0 ;;
esac
[[ -n "$TASK_ID" ]] || exit 0

SENTINEL="$CWD/docs/handoff/${TASK_ID}/.workflow-called-${ACTIVE_PHASE}"
mkdir -p "$(dirname "$SENTINEL")"
touch "$SENTINEL"
exit 0
