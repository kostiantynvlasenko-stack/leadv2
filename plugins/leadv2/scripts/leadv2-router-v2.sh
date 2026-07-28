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
#
# resolve: stdout `key=value` lines (winner, reason, eligible, filtered,
#   headroom); exit 0 = winner chosen, exit 3 = every candidate arm exhausted
#   (caller's existing all_arms_exhausted rollback path). --task-id also
#   journals one `route_v2_resolved` line (leadv2-journal.sh) carrying the
#   full per-arm vector, so a wrong route is auditable after the fact.
# dry-run: full JSON decision vector to stdout, always exit 0 -- for humans.
#
# Env:
#   LEADV2_QUOTA_LIVE     override path to leadv2-quota-live.sh (tests)
#   LEADV2_ROUTER_V2_PY   override path to leadv2-router-v2.py (tests)
#   LEADV2_JOURNAL_BIN    override path to leadv2-journal.sh (tests)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROUTER_PY="${LEADV2_ROUTER_V2_PY:-"${SCRIPT_DIR}/leadv2-router-v2.py"}"
JOURNAL_BIN="${LEADV2_JOURNAL_BIN:-${SCRIPT_DIR}/leadv2-journal.sh}"

die() { printf -- '[leadv2-router-v2] %s\n' "$*" >&2; exit 2; }

[[ -f "${ROUTER_PY}" ]] || die "python resolver not found: ${ROUTER_PY}"

MODE=""
CHAIN=""
TASK_ID=""
QUOTA_JSON=""
QUOTA_LIVE="${LEADV2_QUOTA_LIVE:-}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    resolve|dry-run) MODE="$1"; shift ;;
    --chain)      CHAIN="${2:-}"; shift 2 ;;
    --task-id)    TASK_ID="${2:-}"; shift 2 ;;
    --quota-json) QUOTA_JSON="${2:-}"; shift 2 ;;
    --quota-live) QUOTA_LIVE="${2:-}"; shift 2 ;;
    -h|--help)    sed -n '3,32p' "$0"; exit 0 ;;
    *) die "unknown arg: $1" ;;
  esac
done
[[ -n "${MODE}" ]] || die "usage: leadv2-router-v2.sh resolve|dry-run --chain a,b,c [--task-id T] [--quota-json FILE]"
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
