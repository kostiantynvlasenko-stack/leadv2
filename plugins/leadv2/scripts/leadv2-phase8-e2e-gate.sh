#!/usr/bin/env bash
# leadv2-phase8-e2e-gate.sh — E2E-INTO-DEV-LOOP-01
# Runs tests/run-all.sh --scope changed for <task_id> and writes the sentinel
# leadv2-phase8-assert.sh's A7 check reads. Called by leadv2-phase8-close.sh
# before it invokes leadv2-phase8-assert.sh; also callable standalone (used
# by this task's own verification plan, see plan.md §8).
#
# Usage:
#   leadv2-phase8-e2e-gate.sh <task_id>
#   LEADV2_TASK_ID=PO-XXX leadv2-phase8-e2e-gate.sh
#
# Exit codes:
#   0  tests/run-all.sh --scope changed exited 0 -> sentinel written
#   1  tests/run-all.sh --scope changed exited non-zero -> sentinel NOT written
#   2  bad usage (missing task_id)
#
# Bypass (emergency only, same convention as PE_SKIP_TESTS elsewhere):
#   PE_SKIP_TESTS=1 leadv2-phase8-e2e-gate.sh <task_id>
#   -> sentinel IS written but with bypassed: true (visible, not silent —
#      "every decision is explainable" per CLAUDE.md non-negotiables).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${CLAUDE_PROJECT_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
# shellcheck source=leadv2-helpers.sh
source "${SCRIPT_DIR}/leadv2-helpers.sh"
_lv2_load_paths
cd "$PROJECT_ROOT"

TASK_ID="${1:-${LEADV2_TASK_ID:-}}"
if [[ -z "$TASK_ID" ]]; then
  echo "task_id required (arg1 or LEADV2_TASK_ID env)" >&2
  exit 2
fi

OUT_DIR="${LEADV2_HANDOFF_DIR}/${TASK_ID}"
mkdir -p "$OUT_DIR"
SENTINEL="${OUT_DIR}/e2e-gate-passed.flag"
LOG="${OUT_DIR}/e2e-gate.log"

# Advisory lock: prevent two concurrent invocations for the SAME task_id
# from interleaving writes to $LOG (see plan.md §9 R4). Mirrors the flock
# convention already used by the deploy path.
LOCK="/tmp/leadv2-e2e-gate-${TASK_ID}.lock"
exec 9>"$LOCK"
if ! flock -n 9; then
  echo "leadv2-phase8-e2e-gate: another run in progress for ${TASK_ID} (lock: ${LOCK})" >&2
  exit 1
fi

if [[ "${PE_SKIP_TESTS:-}" == "1" ]]; then
  printf 'e2e-gate-passed: %s\nasserted_at: %s\nscope: changed\nbypassed: true\n' \
    "$TASK_ID" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$SENTINEL"
  echo "leadv2-phase8-e2e-gate: BYPASSED via PE_SKIP_TESTS=1 (sentinel marked bypassed:true)" | tee "$LOG" >&2
  exit 0
fi

rc=0
bash "${PROJECT_ROOT}/tests/run-all.sh" --scope changed > "$LOG" 2>&1 || rc=$?

if [[ $rc -eq 0 ]]; then
  printf 'e2e-gate-passed: %s\nasserted_at: %s\nscope: changed\nbypassed: false\n' \
    "$TASK_ID" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$SENTINEL"
  echo "leadv2-phase8-e2e-gate: PASS — sentinel written: ${SENTINEL}" >&2
  exit 0
else
  rm -f "$SENTINEL"   # never leave a stale PASS behind on a red re-run
  echo "leadv2-phase8-e2e-gate: FAIL (tests/run-all.sh --scope changed exit ${rc}) — see ${LOG}" >&2
  tail -40 "$LOG" >&2 || true
  exit 1
fi
