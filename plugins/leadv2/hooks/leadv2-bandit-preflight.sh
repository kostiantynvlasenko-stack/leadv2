#!/usr/bin/env bash
# PreToolUse:Workflow — bandit preflight hook (R2).
#
# When LEADV2_ROUTE_BANDIT=1 AND the Workflow name is leadv2-plan or leadv2-review
# AND docs/handoff/$LEADV2_TASK_ID/route-decisions.yaml is absent:
#   auto-run select-for-workflow inline to write route-decisions.yaml BEFORE the
#   Workflow call proceeds.
#
# CONTRACT:
#   - FAIL-OPEN: any error -> exit 0 (never blocks the Workflow tool).
#   - FLAG-OFF: LEADV2_ROUTE_BANDIT != "1" -> exit 0, no filesystem side effects
#     (byte-identical to current behaviour).
#   - FAST: file-exists check is first; shell call only when file is absent.
#   - NO-OP when route-decisions.yaml already present (idempotent).
#
# Registered in hooks.json under PreToolUse:Workflow.

set -euo pipefail
trap 'exit 0' ERR   # fail-open on any unhandled error

# -- flag-off fast path -------------------------------------------------------
[[ "${LEADV2_ROUTE_BANDIT:-0}" == "1" ]] || exit 0

# -- parse hook input ---------------------------------------------------------
INPUT="$(cat 2>/dev/null || true)"
[[ -z "$INPUT" ]] && exit 0

# Extract tool_input.name (Workflow tool passes the workflow name here)
WF_NAME="$(printf '%s' "$INPUT" | python3 -c "
import sys, json
try:
    d = json.loads(sys.stdin.read())
    inp = d.get('tool_input') or {}
    print((inp.get('name') or '').strip())
except Exception:
    pass
" 2>/dev/null || true)"

# Only intercept plan and review workflows
case "${WF_NAME:-}" in
  leadv2-plan|leadv2-review) ;;
  *) exit 0 ;;
esac

# -- resolve project root -----------------------------------------------------
# Honor LEADV2_PROJECT_ROOT > PROJECT_ROOT > git toplevel > PWD (same order as
# select-for-workflow in leadv2-route-bandit.sh).
PROJ_ROOT="${LEADV2_PROJECT_ROOT:-${PROJECT_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}}"

# -- check if route-decisions.yaml already exists ----------------------------
TASK_ID="${LEADV2_TASK_ID:-}"
SAFE_TASK_ID="$(printf -- '%s' "$TASK_ID" | tr -cd 'A-Za-z0-9._-')"

if [[ -z "$SAFE_TASK_ID" ]]; then
  # No task ID -- cannot write route-decisions.yaml; skip silently
  exit 0
fi

RD_FILE="${PROJ_ROOT}/docs/handoff/${SAFE_TASK_ID}/route-decisions.yaml"

# If already present, nothing to do
[[ -f "$RD_FILE" ]] && exit 0

# -- auto-run select-for-workflow ---------------------------------------------
# Locate leadv2-route-bandit.sh relative to this hook file.
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BANDIT_SCRIPT="${HOOK_DIR}/../scripts/leadv2-route-bandit.sh"

if [[ ! -f "$BANDIT_SCRIPT" ]]; then
  printf -- '[bandit-preflight] WARN: bandit script not found at %s -- skipping\n' "$BANDIT_SCRIPT" >&2
  exit 0
fi

# Derive phase from workflow name
case "$WF_NAME" in
  leadv2-plan)   PHASE="plan" ;;
  leadv2-review) PHASE="review" ;;
  *)             PHASE="plan" ;;
esac

# Read task class and safety from env (set by lead at dispatch time).
TASK_CLASS="${LEADV2_TASK_CLASS:-Standard}"
SAFETY_TOUCHED="${LEADV2_SAFETY_TOUCHED:-false}"

printf -- '[bandit-preflight] auto-running select-for-workflow (task=%s phase=%s class=%s safety=%s)\n' \
  "$SAFE_TASK_ID" "$PHASE" "$TASK_CLASS" "$SAFETY_TOUCHED" >&2

# Run select-for-workflow; discard stdout (JSON map of role->model) -- only the
# side effect matters: route-decisions.yaml written under docs/handoff/<task>.
# Any error -> fail-open (trap catches set -e exit and returns 0).
LEADV2_PROJECT_ROOT="${PROJ_ROOT}" PROJECT_ROOT="${PROJ_ROOT}" \
  timeout 15 bash "$BANDIT_SCRIPT" select-for-workflow \
    --phase     "$PHASE" \
    --class     "$TASK_CLASS" \
    --safety    "$SAFETY_TOUCHED" \
    --task-id   "$SAFE_TASK_ID" \
  >/dev/null 2>&1 || {
    printf -- '[bandit-preflight] WARN: select-for-workflow failed -- continuing (fail-open)\n' >&2
    exit 0
  }

if [[ -f "$RD_FILE" ]]; then
  printf -- '[bandit-preflight] auto-selected models written to %s\n' "$RD_FILE" >&2
else
  printf -- '[bandit-preflight] WARN: select-for-workflow ran but route-decisions.yaml absent -- continuing\n' >&2
fi

exit 0
