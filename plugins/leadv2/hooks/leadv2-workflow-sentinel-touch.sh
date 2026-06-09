#!/usr/bin/env bash
# PostToolUse(Workflow) — touch sentinel after a Workflow completes for plan/review phases.
# This unblocks leadv2-workflow-bypass-guard for subsequent direct subagent spawns.

set -euo pipefail
trap 'exit 0' ERR

[[ "${LEADV2_WORKFLOW_ENABLED:-0}" == "1" ]] || exit 0

INPUT="$(cat 2>/dev/null || true)"
[[ -z "$INPUT" ]] && exit 0

# Only fire on Workflow tool
TOOL_NAME="$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || true)"
[[ "$TOOL_NAME" == "Workflow" ]] || exit 0

ACTIVE_PHASE="${LEADV2_ACTIVE_PHASE:-}"
CWD="$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || echo "")"
[[ -z "$CWD" ]] && CWD="$PWD"

if [[ -z "$ACTIVE_PHASE" ]]; then
  ACTIVE_YAML=""
  for _cand in "$CWD/docs/leadv2/active.yaml" "$CWD/.claude/leadv2-tasks/active.yaml"; do
    [[ -f "$_cand" ]] && { ACTIVE_YAML="$_cand"; break; }
  done
  if [[ -n "$ACTIVE_YAML" ]]; then
    ACTIVE_PHASE="$(python3 -c "
import sys, yaml
try:
    with open(sys.argv[1]) as f:
        d = yaml.safe_load(f) or {}
    sessions = d.get('sessions') or []
    if sessions and isinstance(sessions, list):
        print((sessions[0].get('phase') or '').lower())
except Exception:
    pass
" "$ACTIVE_YAML" 2>/dev/null || true)"
  fi
fi

case "${ACTIVE_PHASE:-}" in
  plan|review) ;;
  *) exit 0 ;;
esac

SENTINEL="$CWD/docs/leadv2/.workflow-called-${ACTIVE_PHASE}"
mkdir -p "$(dirname "$SENTINEL")"
touch "$SENTINEL"
exit 0
