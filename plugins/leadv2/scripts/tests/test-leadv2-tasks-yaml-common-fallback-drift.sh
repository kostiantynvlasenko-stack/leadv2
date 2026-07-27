#!/usr/bin/env bash
# tests/test-leadv2-tasks-yaml-common-fallback-drift.sh — CLOSE-GATE-A2-
# STORE-YAML-IMPEDANCE-01 round-2 finding 3 regression test.
#
# leadv2-phase8-assert.sh derives TERMINAL_STATUSES/LANE_TERMINAL_STATUSES
# from leadv2_tasks_yaml_common.py at runtime, but falls back to a HAND-
# TYPED literal (lines ~200/~209) if the python import fails for any reason
# (corrupted install, module moved, etc). critic-round-2.md finding 3: the
# only existing test touching these values,
# test-leadv2-phase8-assert-a2-schema.sh's _extract_assert_var, reads the
# FALLBACK LITERAL text back out of the script source -- it can never catch
# the fallback going stale relative to the actual python constants, because
# it is comparing the literal to itself. A future edit to
# leadv2_tasks_yaml_common.py's TERMINAL_STATUSES/LANE_TERMINAL_STATUSES
# without updating the hand-synced bash fallback would re-diverge silently,
# with zero test failures -- "same disease, one layer down" per the finding.
#
# This test closes that gap: it extracts the fallback literal from the shell
# source (same technique) AND independently imports leadv2_tasks_yaml_common
# and asks Python for the REAL, current value, then asserts the two are
# byte-identical. A future edit to the python constants that forgets to
# touch the bash fallback now fails HERE, not silently.
#
# Non-tautology proof (see docs/handoff/500a9bcbcab3/fix-round-2.md): this
# suite was re-run after temporarily dropping "verified_closed" from
# leadv2_tasks_yaml_common.py's TERMINAL_STATUSES (leaving the bash fallback
# untouched) and the test correctly FAILED; restored, passes again.
#
# Companion test for the THIRD fallback location this same finding names
# (leadv2-tasks-regen-gate.sh:62, a persona-engine-specific project script,
# not part of this shared plugin) lives in the consuming repo:
# persona-engine/scripts/tests/test-leadv2-tasks-regen-gate-fallback-drift.sh
#
# Run: bash scripts/tests/test-leadv2-tasks-yaml-common-fallback-drift.sh
# Exit 0 = all pass; non-zero = failures found (real drift or extraction broke).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ASSERT_SH="${SCRIPTS_DIR}/leadv2-phase8-assert.sh"
COMMON_PY="${SCRIPTS_DIR}/leadv2_tasks_yaml_common.py"

PASS=0; FAIL=0; ERRORS=()
log()  { printf -- '[TEST] %s\n' "$*"; }
pass() { PASS=$((PASS + 1)); log "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); ERRORS+=("FAIL: $1"); log "FAIL: $1"; }

# Same extraction technique as test-leadv2-phase8-assert-a2-schema.sh's
# _extract_assert_var (grabs the fallback literal out of
# `<varname>="${<varname>:-literal}"`, last match in the file).
_extract_fallback_literal() {
  local varname="$1"
  grep "^${varname}=" "$ASSERT_SH" | tail -1 | sed -E "s/^${varname}=\"\\\$\\{${varname}:-([^}]*)\\}\"/\\1/"
}

# The independent, python-resolved runtime value -- NOT read from the shell
# source at all. Fails loudly (does not swallow ImportError like the
# production `except Exception: pass` fallback path does) so a broken
# import shows up as a test failure, not a silent empty string.
_python_resolved_value() {
  local varname="$1"
  python3 -c "
import sys
sys.path.insert(0, sys.argv[1])
from leadv2_tasks_yaml_common import ${varname}
print(${varname})
" "$SCRIPTS_DIR"
}

test_1_terminal_statuses_matches_python() {
  log "Test 1: leadv2-phase8-assert.sh TERMINAL_STATUSES fallback matches python-resolved leadv2_tasks_yaml_common.TERMINAL_STATUSES"
  local literal resolved
  literal="$(_extract_fallback_literal TERMINAL_STATUSES)"
  resolved="$(_python_resolved_value TERMINAL_STATUSES)"
  if [[ -z "$literal" ]]; then
    fail "Test 1: could not extract TERMINAL_STATUSES fallback literal from ${ASSERT_SH} -- source has drifted, fix the extractor"
  elif [[ "$literal" == "$resolved" ]]; then
    pass "Test 1: TERMINAL_STATUSES fallback == python-resolved value ('${resolved}')"
  else
    fail "Test 1: DRIFT -- ${ASSERT_SH} fallback='${literal}' but leadv2_tasks_yaml_common.TERMINAL_STATUSES='${resolved}'"
  fi
}

test_2_lane_terminal_statuses_matches_python() {
  log "Test 2: leadv2-phase8-assert.sh LANE_TERMINAL_STATUSES fallback matches python-resolved leadv2_tasks_yaml_common.LANE_TERMINAL_STATUSES"
  local literal resolved
  literal="$(_extract_fallback_literal LANE_TERMINAL_STATUSES)"
  resolved="$(_python_resolved_value LANE_TERMINAL_STATUSES)"
  if [[ -z "$literal" ]]; then
    fail "Test 2: could not extract LANE_TERMINAL_STATUSES fallback literal from ${ASSERT_SH} -- source has drifted, fix the extractor"
  elif [[ "$literal" == "$resolved" ]]; then
    pass "Test 2: LANE_TERMINAL_STATUSES fallback == python-resolved value ('${resolved}')"
  else
    fail "Test 2: DRIFT -- ${ASSERT_SH} fallback='${literal}' but leadv2_tasks_yaml_common.LANE_TERMINAL_STATUSES='${resolved}'"
  fi
}

test_3_syntax() {
  log "Test 3: bash -n / py_compile syntax checks"
  local ok=1
  bash -n "$ASSERT_SH" 2>/dev/null || ok=0
  python3 -m py_compile "$COMMON_PY" 2>/dev/null || ok=0
  if [[ "$ok" -eq 1 ]]; then
    pass "Test 3: leadv2-phase8-assert.sh + leadv2_tasks_yaml_common.py syntax OK"
  else
    fail "Test 3: syntax check failed"
  fi
}

main() {
  log "=== CLOSE-GATE-A2-STORE-YAML-IMPEDANCE-01 round-2 finding-3 fallback-drift tests ==="
  log "Script: $ASSERT_SH"
  log "Module: $COMMON_PY"
  echo ""
  test_3_syntax
  test_1_terminal_statuses_matches_python
  test_2_lane_terminal_statuses_matches_python
  echo ""
  log "=== Results: PASS=$PASS FAIL=$FAIL ==="
  if [[ "${#ERRORS[@]}" -gt 0 ]]; then
    log "Failures:"
    for e in "${ERRORS[@]}"; do log "  $e"; done
    exit 1
  fi
  log "All tests passed."
  exit 0
}

main "$@"
