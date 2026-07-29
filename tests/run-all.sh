#!/usr/bin/env bash
# tests/run-all.sh — canonical repo's e2e entrypoint (T-d, PRODUCT-READINESS-GATES-01
# follow-up, 2026-07-29). This is what leadv2-e2e-entrypoint.sh resolves to and what the
# product gates (leadv2-dispatch-product-close.sh, leadv2-phase8-e2e-gate.sh) execute.
#
# It does NOT author new suites — it drives the plugin's own curated offline regression
# runner (.claude/scripts/tests/run-core-offline.sh) plus, on `--scope changed`, any
# test-*.sh whose stem matches a changed file's stem under plugins/leadv2/scripts/.
#
# usage: tests/run-all.sh [--scope changed|all]
# exit 0: every selected suite passed
# exit 1: at least one suite failed
# exit 2: bad usage
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"

SCOPE="changed"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --scope)
      SCOPE="${2:-}"; shift 2 ;;
    --scope=*)
      SCOPE="${1#--scope=}"; shift ;;
    -h|--help)
      echo "usage: tests/run-all.sh [--scope changed|all]" >&2
      exit 0 ;;
    *)
      echo "run-all: unknown argument: $1" >&2
      exit 2 ;;
  esac
done
case "${SCOPE}" in
  changed|all) ;;
  *) echo "run-all: --scope must be changed|all (got '${SCOPE}')" >&2; exit 2 ;;
esac

PASS=0
FAIL=0
declare -a SUITES=()

add_suite() { # <path>
  local p="$1" real
  real="$(cd "$(dirname "$p")" 2>/dev/null && pwd)/$(basename "$p")" || return 0
  [[ -f "$real" ]] || return 0
  local existing
  for existing in "${SUITES[@]:-}"; do
    [[ "$existing" == "$real" ]] && return 0
  done
  SUITES+=("$real")
}

# Always-on: the plugin's own curated offline regression set.
add_suite "${ROOT}/.claude/scripts/tests/run-core-offline.sh"

if [[ "${SCOPE}" == "all" ]]; then
  while IFS= read -r f; do add_suite "$f"; done < <(
    find "${ROOT}/.claude/scripts/tests" "${ROOT}/plugins/leadv2/tests" "${ROOT}/tests" \
      -maxdepth 1 -type f -name 'test-*.sh' 2>/dev/null | sort
  )
else
  changed="$(git -C "${ROOT}" diff --name-only HEAD 2>/dev/null)"
  if [[ -z "${changed}" ]] && git -C "${ROOT}" rev-parse HEAD~1 >/dev/null 2>&1; then
    changed="$(git -C "${ROOT}" diff --name-only HEAD~1..HEAD 2>/dev/null)"
  fi
  if [[ -n "${changed}" ]]; then
    while IFS= read -r cf; do
      [[ "${cf}" == plugins/leadv2/scripts/*.sh ]] || continue
      stem="$(basename "${cf}" .sh)"
      for cand in "${ROOT}/.claude/scripts/tests/test-${stem}.sh" \
                  "${ROOT}/plugins/leadv2/tests/test-${stem}.sh" \
                  "${ROOT}/tests/test-${stem}.sh"; do
        add_suite "${cand}"
      done
    done <<< "${changed}"
  fi
fi

for suite in "${SUITES[@]}"; do
  printf '[RUN] %s\n' "${suite}"
  if bash "${suite}"; then
    printf '[PASS] %s\n' "${suite}"
    PASS=$((PASS + 1))
  else
    printf '[FAIL] %s\n' "${suite}"
    FAIL=$((FAIL + 1))
  fi
done

printf 'run-all: %d passed, %d failed, scope=%s\n' "${PASS}" "${FAIL}" "${SCOPE}"
(( FAIL == 0 ))
