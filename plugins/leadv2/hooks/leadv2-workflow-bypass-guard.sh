#!/usr/bin/env bash
# PreToolUse(Agent) guard -- enforce Workflow-first protocol for plan/review phases.
# When LEADV2_WORKFLOW_ENABLED=1 AND active phase is plan or review AND the sentinel
# file docs/handoff/<task>/.workflow-called-<phase> is absent AND the spawn targets a
# structured-review subagent (architect/critic/security-auditor) -> deny.
#
# Env kill-switch: LEADV2_WORKFLOW_GUARD=0 -> exit 0 (fail open).
# Fail open on ANY parse error.

set -euo pipefail
trap 'exit 0' ERR

[[ "${LEADV2_WORKFLOW_GUARD:-1}" == "0" ]] && exit 0
[[ "${LEADV2_WORKFLOW_ENABLED:-0}" == "1" ]] || exit 0

INPUT="$(cat 2>/dev/null || true)"
[[ -z "$INPUT" ]] && exit 0

# shellcheck source=leadv2-mode-isolation.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/leadv2-mode-isolation.sh"
leadv2_hook_is_supervisor_session "$INPUT" && exit 0

SUBTYPE="$(printf '%s' "$INPUT" | jq -r '.tool_input.subagent_type // empty' 2>/dev/null || true)"
case "$SUBTYPE" in
  architect|critic|security-auditor) ;;
  *) exit 0 ;;
esac

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
[[ -f "$SENTINEL" ]] && exit 0

case "$SUBTYPE" in
  architect)        WORKFLOW_NAME="leadv2-plan" ;;
  critic)           WORKFLOW_NAME="leadv2-review" ;;
  security-auditor) WORKFLOW_NAME="leadv2-review" ;;
  *)                WORKFLOW_NAME="the corresponding leadv2 Workflow" ;;
esac

python3 -c "
import sys, json
subtype=sys.argv[1]; phase=sys.argv[2]; wf=sys.argv[3]
msg=('workflow-bypass-guard DENY: spawning %s during phase=%s without calling the %s Workflow first. '
     'Call Workflow(name=%s) to fan-out; it touches the sentinel. To bypass: LEADV2_WORKFLOW_GUARD=0.' % (subtype,phase,wf,wf))
print(json.dumps({'hookSpecificOutput':{'hookEventName':'PreToolUse','permissionDecision':'deny','permissionDecisionReason':msg}}))
" -- "$SUBTYPE" "$ACTIVE_PHASE" "$WORKFLOW_NAME"
exit 0
