#!/usr/bin/env bash
set -euo pipefail
# leadv2-queue-release.sh — Release a claimed queue item after task completion.
#
# Usage: leadv2-queue-release.sh --lane <lane> --id <item-id> --outcome <success|fail|poison|reject>
#                                 [--reject-reason "..."]
#
# Outcomes:
#   success — status=done, claim cleared, closed_at=now
#   fail    — attempts++; if attempts >= max_attempts → status=poisoned, closed_at=now
#   poison  — status=poisoned explicitly (reject-reason required), closed_at=now
#   reject  — status=rejected (founder explicit reject), closed_at=now

PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
# shellcheck disable=SC2034
QUEUE_DIR="${PROJECT_ROOT}/docs/agents/product-owner/queue" # kept for backward compat

# Source tasks lib — all release operations now delegate to tasks.yaml
# shellcheck source=leadv2-tasks-lib.sh
source "$(dirname "$0")/leadv2-tasks-lib.sh"

LANE=""
ITEM_ID=""
OUTCOME=""
REJECT_REASON=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --lane)          LANE="$2";          shift 2 ;;
    --id)            ITEM_ID="$2";       shift 2 ;;
    --outcome)       OUTCOME="$2";       shift 2 ;;
    --reject-reason) REJECT_REASON="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: leadv2-queue-release.sh --lane <lane> --id <item-id> --outcome <success|fail|poison> [--reject-reason \"...\"]" >&2
      exit 0
      ;;
    *) echo "[queue-release] unknown arg: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$LANE" || -z "$ITEM_ID" || -z "$OUTCOME" ]]; then
  echo "[queue-release] ERROR: --lane, --id, and --outcome are required" >&2
  exit 1
fi

case "$OUTCOME" in
  success|fail|poison|reject) ;;
  *)
    echo "[queue-release] ERROR: --outcome must be success, fail, poison, or reject" >&2
    exit 1
    ;;
esac

if [[ "$OUTCOME" == "poison" && -z "$REJECT_REASON" ]]; then
  echo "[queue-release] ERROR: --reject-reason is required when outcome=poison" >&2
  exit 1
fi

if [[ "$OUTCOME" == "reject" && -z "$REJECT_REASON" ]]; then
  echo "[queue-release] ERROR: --reject-reason is required when outcome=reject" >&2
  exit 1
fi

# ── Delegate to tasks lib ─────────────────────────────────────────────────
# Map outcome: poison → poison (pass reject-reason as --error)
# Map outcome: reject → poison (callers use reject for explicit founder rejects)
_release_outcome="$OUTCOME"
_release_error="$REJECT_REASON"
if [[ "$OUTCOME" == "reject" ]]; then
  _release_outcome="poison"
  _release_error="${REJECT_REASON:-founder explicit reject}"
fi

leadv2_tasks_release "$ITEM_ID" --outcome "$_release_outcome" ${_release_error:+--error "$_release_error"}
exit $?
