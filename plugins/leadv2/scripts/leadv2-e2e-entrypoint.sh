#!/usr/bin/env bash
# leadv2-e2e-entrypoint.sh — resolve the per-repo e2e command for the product gates.
# PRODUCT-READINESS-GATES-01 follow-up (T-d, 2026-07-29): the two gate callers
# (leadv2-dispatch-product-close.sh, leadv2-phase8-e2e-gate.sh) previously hardcoded
# `tests/run-all.sh`, which does not exist in every repo. This helper centralizes
# resolution so both callers behave identically.
#
# usage: leadv2-e2e-entrypoint.sh <root>
# stdout: a single shell command string that runs the repo's e2e suite,
#         WITHOUT scope arguments. Callers append `--scope changed` (or `all`).
#         The resolved command MUST accept `--scope changed|all`.
# exit 0: resolved, command printed
# exit 3: no entrypoint in this repo (nothing printed on stdout)
# exit 2: bad usage
#
# Resolution order (first usable candidate wins):
#   1. $LEADV2_E2E_CMD                              — non-empty env override
#   2. <root>/tests/run-all.sh                        — if -f
#   3. <root>/tests/harness.sh                        — if -f
#   4. <root>/.claude/leadv2-overrides/e2e.yaml:cmd    — single-line scalar only;
#      a block scalar (`cmd: |`) is NOT supported.
#      example:
#        cmd: bash scripts/run-e2e.sh
set -uo pipefail

ROOT="${1:?usage: leadv2-e2e-entrypoint.sh <root>}"

if [[ -n "${LEADV2_E2E_CMD:-}" ]]; then
  printf '%s\n' "${LEADV2_E2E_CMD}"
  exit 0
fi

if [[ -f "${ROOT}/tests/run-all.sh" ]]; then
  printf 'bash %q\n' "${ROOT}/tests/run-all.sh"
  exit 0
fi

if [[ -f "${ROOT}/tests/harness.sh" ]]; then
  printf 'bash %q\n' "${ROOT}/tests/harness.sh"
  exit 0
fi

overrides_yaml="${ROOT}/.claude/leadv2-overrides/e2e.yaml"
if [[ -f "${overrides_yaml}" ]]; then
  cmd="$(grep -m1 -E '^[[:space:]]*cmd:[[:space:]]*' "${overrides_yaml}" \
    | sed -E 's/^[[:space:]]*cmd:[[:space:]]*//; s/^["'\'']//; s/["'\'']$//')"
  if [[ -n "${cmd}" ]]; then
    printf '%s\n' "${cmd}"
    exit 0
  fi
fi

exit 3
