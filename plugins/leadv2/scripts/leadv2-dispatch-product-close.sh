#!/usr/bin/env bash
# leadv2-dispatch-product-close.sh — detached post-worker readiness gates for ST-9.
# It is deliberately a script, not supervisor work: dispatch starts it only after a live
# product worker is confirmed.  It reports an absent e2e or cross-provider conflict as a
# finding; neither is silently passed.  Kill switches are passed explicitly by dispatch.
set -uo pipefail

ROOT="${1:?root}"; TASK="${2:?task}"; AUTHOR="${3:?author}"; HANDLE="${4:-}"
E2E_ON="${5:-1}"; REVIEW_ON="${6:-1}"
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
elif [[ ! -f "${ROOT}/tests/run-all.sh" ]]; then
  printf 'status: absent\nreason: tests/run-all.sh not found\n' > "${HANDOFF}/e2e-gate.md"
  emit decision "e2e_gate task=${TASK} status=absent reason=no_relevant_e2e"
else
  bash "${ROOT}/tests/run-all.sh" --scope changed > "${HANDOFF}/e2e-gate.log" 2>&1; e2e_rc=$?
  if [[ ${e2e_rc} -eq 0 ]]; then
    emit decision "e2e_gate task=${TASK} status=ran verdict=pass"
  else
    emit decision "e2e_gate task=${TASK} status=ran verdict=fail rc=${e2e_rc}"
  fi
fi

if [[ "${REVIEW_ON}" != 1 ]]; then
  emit decision "review_gate task=${TASK} status=disabled reason=kill_switch"
fi
