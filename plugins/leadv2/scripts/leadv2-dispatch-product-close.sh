#!/usr/bin/env bash
# leadv2-dispatch-product-close.sh — detached post-worker readiness gates for ST-9.
# It is deliberately a script, not supervisor work: dispatch starts it only after a live
# product worker is confirmed.  It reports a missing e2e entrypoint, an unscopable diff, or
# a cross-provider conflict as a finding; none is silently passed.  Kill switches are passed
# explicitly by dispatch.
set -uo pipefail

ROOT="${1:?root}"; TASK="${2:?task}"; AUTHOR="${3:?author}"; HANDLE="${4:-}"
E2E_ON="${5:-1}"; REVIEW_ON="${6:-1}"
WRITES_CSV="${LEADV2_DISPATCH_LANE_WRITES:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JOURNAL_BIN="${LEADV2_JOURNAL_BIN:-${SCRIPT_DIR}/leadv2-journal.sh}"
DISPATCH_BIN="${LEADV2_DISPATCH_BIN:-${SCRIPT_DIR}/leadv2-dispatch-code.sh}"
HANDOFF="${ROOT}/docs/handoff/dispatch-${TASK}"
mkdir -p "${HANDOFF}"

emit() { # type text
  if [[ -f "${JOURNAL_BIN}" ]]; then bash "${JOURNAL_BIN}" append "dispatch-${TASK}" "$1" "$2" >/dev/null 2>&1 || true; fi
  printf '[leadv2-dispatch-product-close] %s\n' "$2" >&2
}

# Wait only for a positively known local PID. Other providers may expose only a durable
# job/run handle, so their lifecycle owner writes the close evidence; we never guess done.
if [[ "${AUTHOR}" == sonnet && "${HANDLE}" =~ ^[0-9]+$ ]]; then
  while kill -0 "${HANDLE}" 2>/dev/null; do sleep 2; done
fi

if [[ "${E2E_ON}" != 1 ]]; then
  emit decision "e2e_gate task=${TASK} status=disabled reason=kill_switch"
elif ! e2e_cmd="$(bash "${SCRIPT_DIR}/leadv2-e2e-entrypoint.sh" "${ROOT}")"; then
  repo="$(basename "${ROOT}")"
  printf 'status: blocked\nreason: no_e2e_entrypoint\nrepo: %s\n' "${repo}" > "${HANDOFF}/e2e-gate.md"
  rm -f "${HANDOFF}/e2e-gate-passed.flag"
  emit decision "e2e_gate task=${TASK} status=blocked reason=no_e2e_entrypoint repo=${repo}"
  exit 4
else
  bash -c "${e2e_cmd} --scope changed" > "${HANDOFF}/e2e-gate.log" 2>&1; e2e_rc=$?
  if [[ ${e2e_rc} -eq 0 ]]; then
    printf 'e2e-gate-passed: %s\nasserted_at: %s\nscope: changed\nbypassed: false\n' \
      "${TASK}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "${HANDOFF}/e2e-gate-passed.flag"
    emit decision "e2e_gate task=${TASK} status=ran verdict=pass"
  else
    rm -f "${HANDOFF}/e2e-gate-passed.flag"
    emit decision "e2e_gate task=${TASK} status=ran verdict=fail rc=${e2e_rc}"
  fi
fi

if [[ "${REVIEW_ON}" != 1 ]]; then
  emit decision "review_gate task=${TASK} status=disabled reason=kill_switch"
  exit 0
fi

# REVIEWER_ARMS is an availability result supplied by the router/quota layer. Removing the
# author is the cross-provider correctness constraint, not an operator exclusion. A conflict
# is a finding: a same-provider-only pool must never turn into a silent skip.
arms="${LEADV2_DISPATCH_REVIEWER_ARMS:-codex,sonnet}"
reviewer=""
IFS=',' read -r -a candidates <<< "${arms}"
for candidate in "${candidates[@]}"; do
  [[ "${candidate}" == "${AUTHOR}" || -z "${candidate}" ]] && continue
  case "${candidate}" in codex|sonnet) reviewer="${candidate}"; break;; esac
done
if [[ -z "${reviewer}" ]]; then
  printf 'status: conflict\nauthor: %s\navailable_reviewer_arms: %s\n' "${AUTHOR}" "${arms}" > "${HANDOFF}/review-gate.md"
  emit decision "review_gate task=${TASK} status=conflict author=${AUTHOR} available=${arms} reason=no_cross_provider_reviewer"
  exit 0
fi

diff_file="${HANDOFF}/review.diff"
: > "${diff_file}"
blocked_reason=""
if [[ -n "${WRITES_CSV}" ]]; then
  IFS=',' read -r -a raw_writes <<< "${WRITES_CSV}"
  writes=()
  for w in "${raw_writes[@]}"; do
    w="${w#"${w%%[![:space:]]*}"}"; w="${w%"${w##*[![:space:]]}"}"
    [[ -n "${w}" ]] && writes+=("${w}")
  done
  if [[ ${#writes[@]} -gt 0 ]]; then
    git -C "${ROOT}" diff HEAD -- "${writes[@]}" ':(exclude)docs/leadv2' ':(exclude)docs/handoff' > "${diff_file}" 2>/dev/null || true
  fi
  [[ -s "${diff_file}" ]] || blocked_reason="unscopable_diff"
else
  wt="$(bash "${SCRIPT_DIR}/leadv2-lane-worktree.sh" path-of "${TASK}" 2>/dev/null || true)"
  if [[ -n "${wt}" && -d "${wt}" ]]; then
    git -C "${wt}" diff HEAD -- ':(exclude)docs/leadv2' ':(exclude)docs/handoff' > "${diff_file}" 2>/dev/null || true
  fi
  [[ -s "${diff_file}" ]] || blocked_reason="unscopable_diff"
fi
if [[ -n "${blocked_reason}" ]]; then
  printf 'status: blocked\nreason: %s\n' "${blocked_reason}" > "${HANDOFF}/review-gate.md"
  emit decision "review_gate task=${TASK} status=blocked reason=${blocked_reason}"
  exit 5
fi
diff_hash="$(shasum -a 256 "${diff_file}" | awk '{print $1}')"
# Dedup is checked BEFORE spending a second provider. record-review below remains the
# atomic writer that resolves a concurrent race; in that case the duplicate result is also
# journaled instead of masquerading as a new review.
ledger="${LEADV2_DISPATCH_CACHE_DIR:-${HOME}/.claude/cache}/review-ledger/$(basename "${ROOT}").jsonl"
if [[ -f "${ledger}" ]] && grep -qF "\"diff_hash\":\"${diff_hash}\"" "${ledger}"; then
  emit decision "review_gate task=${TASK} status=dedup diff=${diff_hash:0:8}"
  exit 0
fi
review_out="${HANDOFF}/review-${reviewer}.md"
if [[ "${reviewer}" == codex ]]; then
  bash "${LEADV2_DISPATCH_CODEX_BIN:-${SCRIPT_DIR}/codex-task.sh}" adversarial-review --base HEAD --wait > "${review_out}" 2>&1; review_rc=$?
else
  mission_file="${HANDOFF}/review-mission.md"
  printf 'Review ONLY the diff at %s. Return Critical/High correctness findings or clean. You are independent of the author (%s).\n' "${diff_file}" "${AUTHOR}" > "${mission_file}"
  PROJECT_ROOT="${ROOT}" bash "${LEADV2_DISPATCH_ARCHITECT_BIN:-${SCRIPT_DIR}/claude-subsession.sh}" --role critic --model sonnet --task-id "dispatch-${TASK}-review" --mission-file "${mission_file}" --wait > "${review_out}" 2>&1; review_rc=$?
fi
verdict=PASS_WITH_NITS; [[ ${review_rc} -ne 0 ]] && verdict=FAIL
record_out="$(LEADV2_DISPATCH_CACHE_DIR="${LEADV2_DISPATCH_CACHE_DIR:-}" LEADV2_JOURNAL_BIN="${JOURNAL_BIN}" \
  bash "${DISPATCH_BIN}" record-review --diff-hash "${diff_hash}" --verdict "${verdict}" --reviewer "${reviewer}" --run-id "dispatch-${TASK}" 2>&1)"; record_rc=$?
if [[ ${record_rc} -eq 2 ]]; then
  emit decision "review_gate task=${TASK} status=dedup diff=${diff_hash:0:8}"
else
  emit decision "review_gate task=${TASK} status=ran author=${AUTHOR} reviewer=${reviewer} verdict=${verdict} diff=${diff_hash:0:8} ledger_rc=${record_rc}"
fi
