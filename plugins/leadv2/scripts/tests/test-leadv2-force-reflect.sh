#!/usr/bin/env bash
# tests/test-leadv2-force-reflect.sh - Unit tests for leadv2-force-reflect.sh (Stop hook)
#
# Tests:
#   1. trigger phase -> stdout is one JSON line with decision=block
#   2. reflect-history.yaml written with stub entry
#   3. re-run idempotent (.reflect-forced prevents duplicate)
#   4. non-trigger phase -> no block
#   5. bash -n syntax check
#
# Run: bash scripts/tests/test-leadv2-force-reflect.sh
# Exit 0 = all pass; non-zero = failures found.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_SH="${SCRIPT_DIR}/../../hooks/leadv2-force-reflect.sh"

PASS=0; FAIL=0; ERRORS=()
log()  { printf -- '[TEST] %s\n' "$*"; }
pass() { PASS=$((PASS + 1)); log "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); ERRORS+=("FAIL: $1"); log "FAIL: $1"; }
_tmp_dir() { mktemp -d /tmp/fr-test-XXXXXX; }

_write_active_yaml() {
  local dir="$1" phase="$2" task_id="$3"
  mkdir -p "${dir}/docs/leadv2"
  printf 'sessions:\n  - task_id: "%s"\n    phase: "%s"\n' "$task_id" "$phase" \
    > "${dir}/docs/leadv2/active.yaml"
}

test_1_block_on_trigger_phase() {
  log "Test 1: trigger phase (verify) -> one JSON line decision=block"
  local tmpdir task_id="TEST-REFLECT-T1"
  tmpdir="$(_tmp_dir)"
  _write_active_yaml "$tmpdir" "verify" "$task_id"
  mkdir -p "${tmpdir}/docs/handoff/${task_id}"
  local input out decision line_count
  input=$(printf '{"cwd":"%s","stop_hook_active":false}' "$tmpdir")
  out=$(printf '%s\n' "$input" | bash "$HOOK_SH" 2>/dev/null || true)
  rm -rf "$tmpdir"
  decision=$(printf '%s\n' "$out" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d.get('decision',''))" 2>/dev/null || echo "")
  line_count=$(printf '%s\n' "$out" | grep -c '^{' || echo 0)
  if [[ "$decision" == "block" && "$line_count" -eq 1 ]]; then
    pass "Test 1: one JSON line decision=block"
  else
    fail "Test 1: expected decision=block; got '${decision}' lines=${line_count}"
  fi
}

test_2_reflect_history_written() {
  log "Test 2: reflect-history.yaml written with stub entry"
  local tmpdir task_id="TEST-REFLECT-T2"
  tmpdir="$(_tmp_dir)"
  _write_active_yaml "$tmpdir" "deploy" "$task_id"
  mkdir -p "${tmpdir}/docs/handoff/${task_id}" "${tmpdir}/docs/leadv2"
  local input
  input=$(printf '{"cwd":"%s","stop_hook_active":false}' "$tmpdir")
  printf '%s\n' "$input" | bash "$HOOK_SH" 2>/dev/null || true
  local reflect_path="${tmpdir}/docs/leadv2/reflect-history.yaml"
  local entry_found=0
  if [[ -f "$reflect_path" ]]; then
    entry_found=$(python3 "$reflect_path" "$task_id" 2>/dev/null || echo 0) || true
    entry_found=$(python3 -c "
import yaml, sys
with open(sys.argv[1]) as f:
    d = yaml.safe_load(f) or {}
entries = d.get('entries') or []
tid = sys.argv[2]
print(1 if any(isinstance(e, dict) and e.get('task') == tid for e in entries) else 0)
" "$reflect_path" "$task_id" 2>/dev/null || echo 0)
  fi
  rm -rf "$tmpdir"
  if [[ "$entry_found" == "1" ]]; then
    pass "Test 2: reflect-history.yaml has entry for ${task_id}"
  else
    fail "Test 2: reflect-history.yaml missing or no entry for ${task_id}"
  fi
}

test_3_idempotent() {
  log "Test 3: re-run idempotent"
  local tmpdir task_id="TEST-REFLECT-T3"
  tmpdir="$(_tmp_dir)"
  _write_active_yaml "$tmpdir" "close" "$task_id"
  mkdir -p "${tmpdir}/docs/handoff/${task_id}" "${tmpdir}/docs/leadv2"
  local input
  input=$(printf '{"cwd":"%s","stop_hook_active":false}' "$tmpdir")
  printf '%s\n' "$input" | bash "$HOOK_SH" 2>/dev/null || true
  printf '%s\n' "$input" | bash "$HOOK_SH" 2>/dev/null || true
  local reflect_path="${tmpdir}/docs/leadv2/reflect-history.yaml"
  local entry_count=0 marker_exists=0
  if [[ -f "$reflect_path" ]]; then
    entry_count=$(python3 -c "
import yaml, sys
with open(sys.argv[1]) as f:
    d = yaml.safe_load(f) or {}
entries = d.get('entries') or []
tid = sys.argv[2]
print(sum(1 for e in entries if isinstance(e, dict) and e.get('task') == tid))
" "$reflect_path" "$task_id" 2>/dev/null || echo 0)
  fi
  [[ -f "${tmpdir}/docs/handoff/${task_id}/.reflect-forced" ]] && marker_exists=1
  rm -rf "$tmpdir"
  if [[ "$entry_count" -eq 1 && "$marker_exists" -eq 1 ]]; then
    pass "Test 3: 1 entry in reflect-history.yaml; .reflect-forced present"
  else
    fail "Test 3: entry_count=${entry_count} (expected 1) marker_exists=${marker_exists}"
  fi
}

test_4_no_block_early_phase() {
  log "Test 4: early phase (plan) -> no block"
  local tmpdir task_id="TEST-REFLECT-T4"
  tmpdir="$(_tmp_dir)"
  _write_active_yaml "$tmpdir" "plan" "$task_id"
  mkdir -p "${tmpdir}/docs/handoff/${task_id}"
  local input out
  input=$(printf '{"cwd":"%s","stop_hook_active":false}' "$tmpdir")
  out=$(printf '%s\n' "$input" | bash "$HOOK_SH" 2>/dev/null || true)
  rm -rf "$tmpdir"
  if [[ -z "$out" ]]; then
    pass "Test 4: phase=plan -> stdout empty (no block)"
  else
    local decision
    decision=$(printf '%s\n' "$out" | python3 -c "import sys,json; d=json.loads(sys.stdin.read().strip() or '{}'); print(d.get('decision','none'))" 2>/dev/null || echo none)
    [[ "$decision" != "block" ]] && pass "Test 4: no block (decision=${decision})" || fail "Test 4: unexpected block on plan phase"
  fi
}

test_5_syntax() {
  log "Test 5: bash -n syntax check"
  bash -n "$HOOK_SH" 2>/dev/null && pass "Test 5: bash -n OK" || fail "Test 5: bash -n FAILED"
}

main() {
  log "=== leadv2-force-reflect unit tests ==="
  log "Hook: $HOOK_SH"
  echo ""
  test_5_syntax
  test_1_block_on_trigger_phase
  test_2_reflect_history_written
  test_3_idempotent
  test_4_no_block_early_phase
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
