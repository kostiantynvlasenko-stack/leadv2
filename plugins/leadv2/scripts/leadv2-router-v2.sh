#!/usr/bin/env bash
# leadv2-router-v2.sh — deterministic, quota-driven arm selection (ROUTER-QUOTA-DRIVEN-01, T6).
#
# WHAT THIS REPLACES
#   2026-07-28: the lead dispatched ~7 lanes straight into Codex while it sat at
#   100% used / 0 credits and never noticed -- a provider at 0 credits still
#   answers and still reports status=completed, so the hardcoded glm->codex->
#   sonnet chain happily dead-ended into it while the healthy Anthropic bucket
#   (6% of its 5h window) sat unused. The stopgap fix was a hand-maintained
#   exclusion file (~/.claude/leadv2-excluded-arms) -- founder-rejected as a
#   band-aid: it must be remembered and edited by hand, including removing
#   Codex from it the moment its quota resets on 2026-08-04.
#
#   This script is the real mechanism: it reads the SAME live quota truth
#   leadv2-quota-read.py already exposes (T1: usable_now = remaining_pct /
#   max(hours_to_reset,1), never a stale hand-edited list) and filters the
#   dispatch chain automatically, every call, with no persisted state. An
#   exhausted arm returns to rotation the instant its usable_now recovers --
#   nothing to edit, nothing to remember, nothing to expire.
#
#   The exclusion file remains supported in leadv2-dispatch-code.sh as an
#   explicit OPERATOR OVERRIDE (emergency "take this arm out no matter what"),
#   applied AFTER this automatic filter -- it is no longer the primary path.
#
# Usage:
#   leadv2-router-v2.sh resolve  --chain glm,codex,sonnet [--task-id T] [--quota-json FILE]
#   leadv2-router-v2.sh dry-run  --chain glm,codex,sonnet [--quota-json FILE]
#   leadv2-router-v2.sh filter   [--mission-kind K] [--protected-path]
#                                [--glm-failure-count N --glm-failure-count-ledger-verified]
#                                [--channel-down a,b] [--task-id T]
#                                [--routing-yaml FILE] [--skip-quota-gate-check]
#
# resolve: stdout `key=value` lines (winner, reason, eligible, filtered,
#   headroom); exit 0 = winner chosen, exit 3 = every candidate arm exhausted
#   (caller's existing all_arms_exhausted rollback path). --task-id also
#   journals one `route_v2_resolved` line (leadv2-journal.sh) carrying the
#   full per-arm vector, so a wrong route is auditable after the fact.
# dry-run: full JSON decision vector to stdout, always exit 0 -- for humans.
#
# filter (T4, SMART-ROUTING-V2 sec3 L1 hard filters): reads router_v2.arms +
#   phases.glm_policy from routing.yaml and computes which arms are eligible
#   AT ALL for this mission -- before any headroom/score math, and never
#   traded back in by one. Pipe `eligible=` straight into resolve's --chain
#   for the combined L1+headroom decision. Reason codes: policy_ban (mission
#   kind banned per glm_policy.opus_only_mission_kinds -- excludes glm+codex),
#   protected_path (safety/publish/payments -- only sonnet/opus survive),
#   quota_gate (leadv2-glm-quota-gate.sh tripped -- checked automatically
#   unless --skip-quota-gate-check), failed_twice (ledger-verified
#   glm_failure_count>=2 only -- an unverified count is ignored, see
#   leadv2-router-v2.py's F1-spoof-fix comment), channel_down (caller-named
#   hard-unavailable arm). stdout `eligible=`/`filtered=` key=value lines;
#   always exit 0 (an empty eligible set is a reportable outcome, not this
#   layer's failure -- resolve()'s exit 3 is where "no winner" is fatal).
#   --task-id journals one `route_v2_filtered` line.
#
# Env:
#   LEADV2_QUOTA_LIVE       override path to leadv2-quota-live.sh (tests)
#   LEADV2_ROUTER_V2_PY     override path to leadv2-router-v2.py (tests)
#   LEADV2_JOURNAL_BIN      override path to leadv2-journal.sh (tests)
#   LEADV2_ROUTING_YAML     override path to routing.yaml (tests); filter mode only
#   LEADV2_GLM_QUOTA_GATE   override path to leadv2-glm-quota-gate.sh (tests)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROUTER_PY="${LEADV2_ROUTER_V2_PY:-"${SCRIPT_DIR}/leadv2-router-v2.py"}"
JOURNAL_BIN="${LEADV2_JOURNAL_BIN:-${SCRIPT_DIR}/leadv2-journal.sh}"
GLM_QUOTA_GATE="${LEADV2_GLM_QUOTA_GATE:-${SCRIPT_DIR}/leadv2-glm-quota-gate.sh}"
PROJECT_ROOT="${PROJECT_ROOT:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"
ROUTING_YAML="${LEADV2_ROUTING_YAML:-${PROJECT_ROOT}/.claude/ref/leadv2-routing.yaml}"

die() { printf -- '[leadv2-router-v2] %s\n' "$*" >&2; exit 2; }

[[ -f "${ROUTER_PY}" ]] || die "python resolver not found: ${ROUTER_PY}"

MODE=""
CHAIN=""
TASK_ID=""
QUOTA_JSON=""
QUOTA_LIVE="${LEADV2_QUOTA_LIVE:-}"
MISSION_KIND=""
PROTECTED_PATH=0
GLM_FAILURE_COUNT=0
GLM_FAILURE_LEDGER_VERIFIED=0
CHANNEL_DOWN=""
SKIP_QUOTA_GATE_CHECK=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    resolve|dry-run|filter) MODE="$1"; shift ;;
    --chain)      CHAIN="${2:-}"; shift 2 ;;
    --task-id)    TASK_ID="${2:-}"; shift 2 ;;
    --quota-json) QUOTA_JSON="${2:-}"; shift 2 ;;
    --quota-live) QUOTA_LIVE="${2:-}"; shift 2 ;;
    --mission-kind) MISSION_KIND="${2:-}"; shift 2 ;;
    --protected-path) PROTECTED_PATH=1; shift ;;
    --glm-failure-count) GLM_FAILURE_COUNT="${2:-0}"; shift 2 ;;
    --glm-failure-count-ledger-verified) GLM_FAILURE_LEDGER_VERIFIED=1; shift ;;
    --channel-down) CHANNEL_DOWN="${2:-}"; shift 2 ;;
    --routing-yaml) ROUTING_YAML="${2:-}"; shift 2 ;;
    --skip-quota-gate-check) SKIP_QUOTA_GATE_CHECK=1; shift ;;
    -h|--help)    sed -n '3,61p' "$0"; exit 0 ;;
    *) die "unknown arg: $1" ;;
  esac
done
[[ -n "${MODE}" ]] || die "usage: leadv2-router-v2.sh resolve|dry-run|filter [args] (see --help)"

if [[ "${MODE}" == "filter" ]]; then
  [[ -f "${ROUTING_YAML}" ]] || die "routing.yaml not found: ${ROUTING_YAML}"
  TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/leadv2-router-v2-filter.XXXXXX")" || die "mktemp failed"
  trap 'rm -rf "${TMP_DIR}"' EXIT
  ARMS_JSON="${TMP_DIR}/arms.json"
  POLICY_JSON="${TMP_DIR}/glm_policy.json"

  # Pull router_v2.arms + phases.glm_policy out of the SAME routing.yaml as
  # plain JSON -- glm_policy stays the single source of policy bans (spec
  # sec1); this only re-serializes it for the python filter, never a second
  # copy of the policy itself.
  python3 -c '
import sys, json, yaml
cfg_path, out_arms, out_policy = sys.argv[1], sys.argv[2], sys.argv[3]
with open(cfg_path) as fh:
    cfg = yaml.safe_load(fh) or {}
arms = ((cfg.get("router_v2") or {}).get("arms")) or []
policy = (cfg.get("phases") or {}).get("glm_policy") or cfg.get("glm_policy") or {}
with open(out_arms, "w") as fh:
    json.dump(arms, fh)
with open(out_policy, "w") as fh:
    json.dump(policy, fh)
' "${ROUTING_YAML}" "${ARMS_JSON}" "${POLICY_JSON}" || die "routing.yaml parse failed: ${ROUTING_YAML}"

  ARM_COUNT="$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "${ARMS_JSON}")"
  [[ "${ARM_COUNT}" -gt 0 ]] || die "router_v2.arms is empty or missing in ${ROUTING_YAML}"

  # Quota gate (spec sec3 L1 "Quota gate" row): reuse the SAME sanctioned gate
  # GLM lanes already pass through -- never a second, possibly-drifting reader
  # of the 80% threshold (founder standing rule: no second channel around a
  # gate). Only relevant when a glm arm is even in the registry.
  GLM_GATE_TRIPPED=0
  if [[ "${SKIP_QUOTA_GATE_CHECK}" != "1" && -f "${GLM_QUOTA_GATE}" ]]; then
    if ! bash "${GLM_QUOTA_GATE}" >/dev/null 2>&1; then
      GLM_GATE_TRIPPED=1
    fi
  fi

  PY_ARGS=(filter --arms-json "${ARMS_JSON}" --glm-policy-json "${POLICY_JSON}")
  [[ -n "${MISSION_KIND}" ]] && PY_ARGS+=(--mission-kind "${MISSION_KIND}")
  [[ "${PROTECTED_PATH}" == "1" ]] && PY_ARGS+=(--protected-path)
  [[ "${GLM_GATE_TRIPPED}" == "1" ]] && PY_ARGS+=(--glm-quota-gate-tripped)
  [[ -n "${GLM_FAILURE_COUNT}" && "${GLM_FAILURE_COUNT}" != "0" ]] && PY_ARGS+=(--glm-failure-count "${GLM_FAILURE_COUNT}")
  [[ "${GLM_FAILURE_LEDGER_VERIFIED}" == "1" ]] && PY_ARGS+=(--glm-failure-count-ledger-verified)
  [[ -n "${CHANNEL_DOWN}" ]] && PY_ARGS+=(--channel-down "${CHANNEL_DOWN}")

  OUT="$(python3 "${ROUTER_PY}" "${PY_ARGS[@]}")"
  RC=$?
  printf '%s\n' "${OUT}"

  if [[ -n "${TASK_ID}" && -f "${JOURNAL_BIN}" ]]; then
    eligible="$(printf '%s\n' "${OUT}" | sed -n 's/^eligible=//p')"
    filtered="$(printf '%s\n' "${OUT}" | sed -n 's/^filtered=//p')"
    bash "${JOURNAL_BIN}" append "${TASK_ID}" decision \
      "route_v2_filtered mission_kind=${MISSION_KIND:-none} protected_path=$([[ ${PROTECTED_PATH} == 1 ]] && echo true || echo false) eligible=${eligible} filtered=${filtered}" \
      >/dev/null 2>&1 || true
  fi

  exit "${RC}"
fi

[[ -n "${CHAIN}" ]] || die "--chain is required (comma-separated ordered arm ids)"

PY_ARGS=("${MODE}" --chain "${CHAIN}")
[[ -n "${QUOTA_JSON}" ]] && PY_ARGS+=(--quota-json "${QUOTA_JSON}")
[[ -n "${QUOTA_LIVE}" ]] && PY_ARGS+=(--quota-live "${QUOTA_LIVE}")

OUT="$(python3 "${ROUTER_PY}" "${PY_ARGS[@]}")"
RC=$?

printf '%s\n' "${OUT}"

if [[ "${MODE}" == "resolve" && -n "${TASK_ID}" && -f "${JOURNAL_BIN}" ]]; then
  winner="$(printf '%s\n' "${OUT}" | sed -n 's/^winner=//p')"
  reason="$(printf '%s\n' "${OUT}" | sed -n 's/^reason=//p')"
  eligible="$(printf '%s\n' "${OUT}" | sed -n 's/^eligible=//p')"
  filtered="$(printf '%s\n' "${OUT}" | sed -n 's/^filtered=//p')"
  headroom="$(printf '%s\n' "${OUT}" | sed -n 's/^headroom=//p')"
  bash "${JOURNAL_BIN}" append "${TASK_ID}" decision \
    "route_v2_resolved winner=${winner} reason=${reason} eligible=${eligible} filtered=${filtered} headroom=${headroom}" \
    >/dev/null 2>&1 || true
fi

exit "${RC}"
