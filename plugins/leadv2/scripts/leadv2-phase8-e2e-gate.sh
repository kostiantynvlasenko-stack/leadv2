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
#
# DEPLOY-CLASS-VERIFY-GATE-01 (D6): when the task classifies as `deploy`,
# a deploy-verify check MUST pass BEFORE this reaches PE_SKIP_TESTS or the
# normal test run — inserted above both so neither can bypass it. Bypass
# for THIS check is a separate, explicit env pair:
#   LEADV2_SKIP_DEPLOY_VERIFY=1 LEADV2_SKIP_DEPLOY_VERIFY_REASON="..."
#   -> empty reason still fails-closed (a reasonless bypass is a silent one).
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

# ── D6: deploy-class verify gate (DEPLOY-CLASS-VERIFY-GATE-01) ──────────────
# Runs BEFORE the PE_SKIP_TESTS branch so that bypass cannot skip deploy
# verification. When the classifier says `deploy`, requires
# leadv2-deploy-verify-check.sh to pass before the sentinel is written.
# If the classifier itself is absent (not yet vendored here), classification
# degrades to `code` -- never a false-RED for repos mid-propagation.
DEPLOY_VERIFIED="false"
DEPLOY_VERIFY_BYPASSED="false"
DEPLOY_VERIFY_BYPASS_REASON=""

CLASSIFIER="${SCRIPT_DIR}/leadv2-deploy-classify.sh"
if [[ -f "$CLASSIFIER" ]]; then
  CLASSIFICATION="$(bash "$CLASSIFIER" "$TASK_ID" 2>/dev/null || echo code)"
else
  CLASSIFICATION="code"
fi

if [[ "$CLASSIFICATION" == "deploy" ]]; then
  if [[ "${LEADV2_SKIP_DEPLOY_VERIFY:-}" == "1" ]]; then
    if [[ -z "${LEADV2_SKIP_DEPLOY_VERIFY_REASON:-}" ]]; then
      echo "leadv2-phase8-e2e-gate: LEADV2_SKIP_DEPLOY_VERIFY=1 requires a non-empty LEADV2_SKIP_DEPLOY_VERIFY_REASON -- fail-closed" >&2
      rm -f "$SENTINEL"
      exit 1
    fi
    DEPLOY_VERIFY_BYPASSED="true"
    DEPLOY_VERIFY_BYPASS_REASON="${LEADV2_SKIP_DEPLOY_VERIFY_REASON}"
    echo "leadv2-phase8-e2e-gate: deploy-verify BYPASSED -- ${DEPLOY_VERIFY_BYPASS_REASON}" >&2
  else
    DEPLOY_CHECK="${SCRIPT_DIR}/leadv2-deploy-verify-check.sh"
    if [[ ! -f "$DEPLOY_CHECK" ]]; then
      echo "leadv2-phase8-e2e-gate: task classified deploy but leadv2-deploy-verify-check.sh not found (${DEPLOY_CHECK}) -- fail-closed" >&2
      rm -f "$SENTINEL"
      exit 1
    fi
    dv_out=""
    dv_rc=0
    dv_out=$(bash "$DEPLOY_CHECK" "$TASK_ID" 2>&1) || dv_rc=$?
    if [[ $dv_rc -eq 0 ]]; then
      DEPLOY_VERIFIED="true"
      echo "leadv2-phase8-e2e-gate: deploy-verify PASS -- ${dv_out}" >&2
    else
      echo "leadv2-phase8-e2e-gate: deploy-verify FAIL (exit ${dv_rc}) -- ${dv_out}" >&2
      rm -f "$SENTINEL"
      exit 1
    fi
  fi
fi

if [[ "${PE_SKIP_TESTS:-}" == "1" ]]; then
  printf 'e2e-gate-passed: %s\nasserted_at: %s\nscope: changed\nbypassed: true\ndeploy_verified: %s\ndeploy_verify_bypassed: %s\ndeploy_verify_bypass_reason: %s\n' \
    "$TASK_ID" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$DEPLOY_VERIFIED" "$DEPLOY_VERIFY_BYPASSED" "$DEPLOY_VERIFY_BYPASS_REASON" > "$SENTINEL"
  echo "leadv2-phase8-e2e-gate: BYPASSED via PE_SKIP_TESTS=1 (sentinel marked bypassed:true)" | tee "$LOG" >&2
  exit 0
fi

rc=0
e2e_cmd=""
if ! e2e_cmd="$(bash "${SCRIPT_DIR}/leadv2-e2e-entrypoint.sh" "${PROJECT_ROOT}")"; then
  echo "leadv2-phase8-e2e-gate: no e2e entrypoint in $(basename "${PROJECT_ROOT}") -- blocked" \
    | tee "$LOG" >&2
  rm -f "$SENTINEL"
  exit 1
fi
bash -c "${e2e_cmd} --scope changed" > "$LOG" 2>&1 || rc=$?

if [[ $rc -eq 0 ]]; then
  printf 'e2e-gate-passed: %s\nasserted_at: %s\nscope: changed\nbypassed: false\ndeploy_verified: %s\ndeploy_verify_bypassed: %s\ndeploy_verify_bypass_reason: %s\n' \
    "$TASK_ID" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$DEPLOY_VERIFIED" "$DEPLOY_VERIFY_BYPASSED" "$DEPLOY_VERIFY_BYPASS_REASON" > "$SENTINEL"
  echo "leadv2-phase8-e2e-gate: PASS — sentinel written: ${SENTINEL}" >&2
  exit 0
else
  rm -f "$SENTINEL"   # never leave a stale PASS behind on a red re-run
  echo "leadv2-phase8-e2e-gate: FAIL (tests/run-all.sh --scope changed exit ${rc}) — see ${LOG}" >&2
  tail -40 "$LOG" >&2 || true
  exit 1
fi
