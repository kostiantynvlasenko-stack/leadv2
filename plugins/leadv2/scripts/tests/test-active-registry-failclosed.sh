#!/usr/bin/env bash
# tests/test-active-registry-failclosed.sh — SUPERVISE-V2-01 fix-1 (critic M1):
# leadv2-active-registry.sh B1 fail-closed root resolution had zero test
# coverage (only leadv2-supervise.sh's own copy of this pattern was tested by
# test-supervise-failclosed.sh). Same order: LEADV2_PROJECT_ROOT ->
# CLAUDE_PROJECT_DIR -> `git -C "$PWD" rev-parse --show-toplevel`. NEVER a
# bare ambient $PROJECT_ROOT/$(pwd) fallback.
#
# Tests:
#   1. no env vars, cwd not a git repo -> sourcing fails closed (nonzero,
#      root_error on stderr), does NOT silently continue
#   2. LEADV2_PROJECT_ROOT set -> sourcing succeeds, register() works
#   3. bash -n syntax check
#
# Portable: no GNU-only date/sed -i/timeout/flock.
# Run: bash scripts/tests/test-active-registry-failclosed.sh
# Exit 0 = all pass; non-zero = failures found.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/leadv2-temp.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGISTRY_SH="${SCRIPT_DIR}/../leadv2-active-registry.sh"

PASS=0; FAIL=0; ERRORS=()
log()  { printf -- '[TEST] %s\n' "$*"; }
pass() { PASS=$((PASS + 1)); log "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); ERRORS+=("FAIL: $1"); log "FAIL: $1"; }

test_1_failclosed_no_root() {
  log "Test 1: no LEADV2_PROJECT_ROOT/CLAUDE_PROJECT_DIR/PROJECT_ROOT, cwd not a git repo -> fail closed"
  local tmp_nogit out
  tmp_nogit="$(lv2_mktemp_dir "aregfc-nogit")"
  out="$(
    cd "$tmp_nogit" && env -u LEADV2_PROJECT_ROOT -u CLAUDE_PROJECT_DIR -u PROJECT_ROOT bash -c '
      source "'"$REGISTRY_SH"'"
      _src_rc=$?
      echo "SRC_RC=${_src_rc}"
      [[ $_src_rc -eq 0 ]] && echo "UNEXPECTED_SUCCESS"
    ' 2>&1
  )" || true
  rm -rf "$tmp_nogit"
  if [[ "$out" == *"root_error"* && "$out" != *"UNEXPECTED_SUCCESS"* && "$out" != *"SRC_RC=0"* ]]; then
    pass "Test 1: fail-closed (root_error, no silent continuation)"
  else
    fail "Test 1: out=$out"
  fi
}

test_2_root_resolves_and_registers() {
  log "Test 2: LEADV2_PROJECT_ROOT set -> sourcing succeeds, register() works"
  local sandbox out
  sandbox="$(lv2_mktemp_dir "aregfc-ok")"
  mkdir -p "${sandbox}/proj" "${sandbox}/state"
  out="$(
    LEADV2_PROJECT_ROOT="${sandbox}/proj" LEADV2_STATE_ROOT="${sandbox}/state" bash -c '
      set -euo pipefail
      source "'"$REGISTRY_SH"'"
      leadv2_active_register "AREGFC-T2" "Standard" "$LEADV2_PROJECT_ROOT" "test-branch" "false" >/dev/null
      echo "REGISTERED_OK"
    ' 2>&1
  )" || true
  rm -rf "$sandbox"
  if [[ "$out" == *"REGISTERED_OK"* ]]; then
    pass "Test 2: root resolved via LEADV2_PROJECT_ROOT, register() succeeded"
  else
    fail "Test 2: out=$out"
  fi
}

test_3_syntax() {
  log "Test 3: bash -n syntax check"
  bash -n "$REGISTRY_SH" 2>/dev/null && pass "Test 3: bash -n OK" || fail "Test 3: bash -n FAILED"
}

main() {
  log "=== leadv2-active-registry.sh fail-closed unit tests ==="
  log "Script: $REGISTRY_SH"
  echo ""
  test_3_syntax
  test_1_failclosed_no_root
  test_2_root_resolves_and_registers
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
