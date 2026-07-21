#!/usr/bin/env bash
# tests/test-leadv2-phase8-assert-a2-schema.sh — GATE-A2-FIX-01 regression test.
#
# Proves leadv2-phase8-assert.sh's A2 check (tasks.yaml terminal-status lookup)
# is tolerant of BOTH docs/tasks.yaml shapes:
#   - bare top-level list (native tasks-lib.sh shape)
#   - mapping with a "tasks" list key, e.g. {"total_open": N, "tasks": [...]}
#     (persona-engine's scripts/task-sync-yaml.sh Truth-Surface projection)
#
# Also proves the gate does NOT become fail-open: a task present but with a
# NON-terminal status must still FAIL A2, in both shapes.
#
# The A2 python block is extracted VERBATIM from the live leadv2-phase8-assert.sh
# (not hand-duplicated) so this test tracks the shipped source, same pattern as
# test-leadv2-phase8-learn-counter.sh Test 6/7.
#
# Run: bash scripts/tests/test-leadv2-phase8-assert-a2-schema.sh
# Exit 0 = all pass; non-zero = failures found.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/leadv2-temp.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ASSERT_SH="${SCRIPTS_DIR}/leadv2-phase8-assert.sh"
COMMON_PY="${SCRIPTS_DIR}/leadv2_tasks_yaml_common.py"

PASS=0; FAIL=0; ERRORS=()
log()  { printf -- '[TEST] %s\n' "$*"; }
pass() { PASS=$((PASS + 1)); log "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); ERRORS+=("FAIL: $1"); log "FAIL: $1"; }

RUN_ID="a2-$$-$(date +%s)"
TMPDIR_ROOT="$(lv2_mktemp_dir "${RUN_ID}")"
trap 'rm -rf "$TMPDIR_ROOT"' EXIT

# ── Extract the A2 python block verbatim from the live script ───────────────
_extract_a2_python() {
  awk '/^import sys$/{found=1} found{print} /^PYEOF$/{if(found)exit}' "$ASSERT_SH" | sed '$d'
}

_run_a2() {
  local task_id="$1" tasks_yaml="$2"
  local snippet
  snippet="$(_extract_a2_python)"
  if [[ -z "$snippet" ]]; then
    echo "EXTRACT_FAILED" >&2
    return 99
  fi
  local terminals="done|poisoned|rejected|failed|archived|closed|completed|admin-closed"
  python3 - "$task_id" "$tasks_yaml" "$terminals" "$SCRIPTS_DIR" <<PYEOF
$snippet
PYEOF
}

# ── Fixtures ──────────────────────────────────────────────────────────────────
MAPPING_YAML="${TMPDIR_ROOT}/mapping-tasks.yaml"
cat > "$MAPPING_YAML" <<'EOF'
total_open: 2
tasks:
  - id: TASK-DONE
    status: done
  - id: TASK-PENDING
    status: pending
EOF

LIST_YAML="${TMPDIR_ROOT}/list-tasks.yaml"
cat > "$LIST_YAML" <<'EOF'
- id: TASK-DONE
  status: done
- id: TASK-PENDING
  status: pending
EOF

# ── Test 1: extraction sanity — snippet is non-empty and imports the shared helper ──
test_1_extraction_sanity() {
  log "Test 1: A2 python block extracted from live source, imports shared helper"
  local snippet
  snippet="$(_extract_a2_python)"
  if [[ -n "$snippet" ]] && grep -q "load_tasks_items" <<<"$snippet"; then
    pass "Test 1: extracted A2 block references load_tasks_items (shared helper, no inline duplication)"
  else
    fail "Test 1: extracted A2 block missing or does not use load_tasks_items — source may have drifted"
  fi
}

# ── Test 2: mapping-shaped tasks.yaml, terminal status -> A2 PASS (exit 0) ──
test_2_mapping_terminal_pass() {
  log "Test 2: mapping-shaped tasks.yaml + status=done -> A2 PASS"
  local rc=0
  _run_a2 "TASK-DONE" "$MAPPING_YAML" >/dev/null 2>&1 || rc=$?
  if [[ "$rc" -eq 0 ]]; then
    pass "Test 2: mapping-shaped + terminal status -> exit 0 (PASS)"
  else
    fail "Test 2: expected exit 0, got exit ${rc}"
  fi
}

# ── Test 3: list-shaped tasks.yaml, terminal status -> A2 PASS (exit 0) ──
test_3_list_terminal_pass() {
  log "Test 3: list-shaped tasks.yaml + status=done -> A2 PASS"
  local rc=0
  _run_a2 "TASK-DONE" "$LIST_YAML" >/dev/null 2>&1 || rc=$?
  if [[ "$rc" -eq 0 ]]; then
    pass "Test 3: list-shaped + terminal status -> exit 0 (PASS)"
  else
    fail "Test 3: expected exit 0, got exit ${rc}"
  fi
}

# ── Test 4: mapping-shaped tasks.yaml, NON-terminal status -> A2 FAILS (exit 1) ──
# Anti-fail-open: fixing the schema-tolerance bug must not make the gate pass
# for a task that is genuinely still open.
test_4_mapping_nonterminal_fails() {
  log "Test 4: mapping-shaped tasks.yaml + status=pending -> A2 still FAILS (not fail-open)"
  local rc=0
  _run_a2 "TASK-PENDING" "$MAPPING_YAML" >/dev/null 2>&1 || rc=$?
  if [[ "$rc" -eq 1 ]]; then
    pass "Test 4: mapping-shaped + non-terminal status -> exit 1 (FAIL, correctly not fail-open)"
  else
    fail "Test 4: expected exit 1 (non-terminal must still fail), got exit ${rc}"
  fi
}

# ── Test 5: list-shaped tasks.yaml, NON-terminal status -> A2 FAILS (exit 1) ──
test_5_list_nonterminal_fails() {
  log "Test 5: list-shaped tasks.yaml + status=pending -> A2 still FAILS"
  local rc=0
  _run_a2 "TASK-PENDING" "$LIST_YAML" >/dev/null 2>&1 || rc=$?
  if [[ "$rc" -eq 1 ]]; then
    pass "Test 5: list-shaped + non-terminal status -> exit 1 (FAIL, correctly not fail-open)"
  else
    fail "Test 5: expected exit 1, got exit ${rc}"
  fi
}

# ── Test 6: task not found in either shape -> exit 2 (distinct from FAIL) ──
test_6_not_found() {
  log "Test 6: task_id absent from tasks.yaml -> exit 2 (not-found, distinct code)"
  local rc=0
  _run_a2 "TASK-NOPE" "$MAPPING_YAML" >/dev/null 2>&1 || rc=$?
  if [[ "$rc" -eq 2 ]]; then
    pass "Test 6: absent task_id -> exit 2"
  else
    fail "Test 6: expected exit 2, got exit ${rc}"
  fi
}

# ── Test 7: shared helper module + syntax checks ─────────────────────────────
test_7_syntax() {
  log "Test 7: bash -n / py_compile syntax checks"
  local ok=1
  bash -n "$ASSERT_SH" 2>/dev/null || ok=0
  python3 -m py_compile "$COMMON_PY" 2>/dev/null || ok=0
  if [[ "$ok" -eq 1 ]]; then
    pass "Test 7: leadv2-phase8-assert.sh + leadv2_tasks_yaml_common.py syntax OK"
  else
    fail "Test 7: syntax check failed"
  fi
}

main() {
  log "=== GATE-A2-FIX-01 A2 schema-tolerance regression tests (RUN_ID=${RUN_ID}) ==="
  log "Script: $ASSERT_SH"
  echo ""
  test_7_syntax
  test_1_extraction_sanity
  test_2_mapping_terminal_pass
  test_3_list_terminal_pass
  test_4_mapping_nonterminal_fails
  test_5_list_nonterminal_fails
  test_6_not_found
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
