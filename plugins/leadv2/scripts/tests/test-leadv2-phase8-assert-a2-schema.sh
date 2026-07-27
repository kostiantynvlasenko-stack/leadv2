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
# CLOSE-GATE-A2-STORE-YAML-IMPEDANCE-01 (D-VOCAB) extended this test with the
# lane-terminal tier: claimed_done/needs_evidence pass A2 ONLY when BOTH a
# release receipt (with outcome: completed_success) AND the phase-8 evidence
# artifact exist on disk. Tests 8-12 cover: verified_closed (plain terminal),
# claimed_done/needs_evidence hitting the distinct lane-terminal path, the
# full gate decision (artifacts present -> pass, any missing/wrong -> fail),
# and in_progress still failing (anti-fail-open, same as Test 4/5 but for the
# new vocabulary).
#
# fix-round-1 (500a9bcbcab3) Finding 4: Tests 8/9/11/12 used to be tautological
# -- 8/9 passed TERMINALS/LANE_TERMINALS as hardcoded literals disconnected
# from the live script (a regression dropping verified_closed from
# TERMINAL_STATUSES would not have been caught), and 11/12 ran a hand-written
# `_a2_gate_decision()` reimplementation of the shipped bash-side AND check
# instead of the real script (reverting the AND to an OR in
# leadv2-phase8-assert.sh would still have passed). Both are fixed now:
# TERMINALS/LANE_TERMINALS are extracted from the live TERMINAL_STATUSES/
# LANE_TERMINAL_STATUSES assignments in the shipped script, and Tests 8/9/11/12
# all invoke the shipped leadv2-phase8-assert.sh end-to-end via `_e2e_run`
# (real subprocess, real exit code, real stderr) against a throwaway project
# root that satisfies every OTHER hard assertion (A1/A3/A4/A5/A6/A7/A8) so the
# observed exit code is driven by A2 alone. Verified by reverting the AND at
# leadv2-phase8-assert.sh's rc==3 branch to an OR and re-running this suite --
# see docs/handoff/500a9bcbcab3/fix-round-1.md for the before/after output.
#
# The A2 python block (used by Tests 1-6, schema-tolerance only) is still
# extracted VERBATIM from the live leadv2-phase8-assert.sh, same pattern as
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

# fix-round-1 Finding 4: extracted from the live script's own assignments
# instead of hardcoded literals, so a regression that drops (e.g.)
# verified_closed from leadv2-phase8-assert.sh's TERMINAL_STATUSES is caught
# here too, not just silently diverged from.
_extract_assert_var() {
  # Prints the resolved value of `<varname>="literal"` or
  # `<varname>="${<varname>:-literal}"` (the runtime-derived-with-fallback
  # form) as it appears in ASSERT_SH -- the second assignment of the pair is
  # what the script actually uses after the python-import attempt, so grab
  # the LAST match, not the first.
  local varname="$1"
  grep "^${varname}=" "$ASSERT_SH" | tail -1 | sed -E "s/^${varname}=\"\\\$\\{${varname}:-([^}]*)\\}\"/\\1/"
}
TERMINALS="$(_extract_assert_var TERMINAL_STATUSES)"
LANE_TERMINALS="$(_extract_assert_var LANE_TERMINAL_STATUSES)"
if [[ -z "$TERMINALS" || -z "$LANE_TERMINALS" ]]; then
  echo "[TEST] FATAL: could not extract TERMINAL_STATUSES/LANE_TERMINAL_STATUSES from ${ASSERT_SH} -- source has drifted, fix the extractor" >&2
  exit 1
fi

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
  python3 - "$task_id" "$tasks_yaml" "$TERMINALS" "$LANE_TERMINALS" "$SCRIPTS_DIR" <<PYEOF
$snippet
PYEOF
}

# ── E2E harness (fix-round-1 Finding 4) ──────────────────────────────────────
# Runs the shipped leadv2-phase8-assert.sh end-to-end as a real subprocess --
# real exit code, real stderr -- instead of hand-reimplementing its bash-side
# decision. Each throwaway PROJECT_ROOT satisfies every hard assertion OTHER
# than A2 (A1/A3/A4/A5/A6/A7/A8 all PASS or WARN-only by construction), so the
# observed overall exit code is driven by A2 alone; reverting the AND at
# leadv2-phase8-assert.sh's rc==3 branch to an OR flips these tests to fail
# for the missing-one-artifact cases (Test 12b/12c).
E2E_ROOT="${TMPDIR_ROOT}/e2e"
mkdir -p "$E2E_ROOT"

# args: task_id -> prints the new project root path
_e2e_new_project() {
  local task_id="$1"
  local root="${E2E_ROOT}/${task_id}.$$.${RANDOM}"
  mkdir -p "${root}/docs/leadv2/closed" "${root}/docs/handoff/${task_id}"
  printf -- 'task_id: %s\nclosed_at: 2026-01-01T00:00:00Z\n' "$task_id" \
    > "${root}/docs/leadv2/closed/${task_id}.yaml"                                  # A1
  printf -- 'entries:\n  - task: %s\n' "$task_id" \
    > "${root}/docs/leadv2/reflect-history.yaml"                                    # A4
  touch "${root}/docs/handoff/${task_id}/e2e-gate-passed.flag"                      # A7 (fresh)
  # A3: no active.yaml written -> treated as "no active sessions", PASS.
  # A5/A6/A8: pass/warn-only by omission (no closed-yaml live_signal field, no
  # merge-blocker.flag, no deploy-verify-check.sh in this canonical scripts dir).
  printf -- '%s\n' "$root"
}

# args: root task_id status
_e2e_write_tasks_yaml() {
  printf -- 'total_open: 1\ntasks:\n  - id: %s\n    status: %s\n' "$2" "$3" \
    > "${1}/docs/tasks.yaml"
}

# args: root task_id -> sets E2E_RC and E2E_ERR (stderr only, stdout discarded)
# set +e/-e bracket is required, not cosmetic: under `set -e` (active at the
# top of this file) a bare `VAR="$(cmd)"` assignment DOES abort the whole
# suite the moment cmd returns non-zero (verified) -- and a non-zero exit
# from the shipped script is exactly what the FAIL-path tests expect to see.
_e2e_run() {
  local root="$1" task_id="$2"
  set +e
  E2E_ERR="$(CLAUDE_PROJECT_ROOT="$root" LEADV2_PROJECT_ROOT="$root" \
    LEADV2_STATE_ROOT="${root}/.state" \
    bash "$ASSERT_SH" "$task_id" 2>&1 >/dev/null)"
  E2E_RC=$?
  set -e
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

LANE_YAML="${TMPDIR_ROOT}/lane-tasks.yaml"
cat > "$LANE_YAML" <<'EOF'
total_open: 4
tasks:
  - id: TASK-VERIFIED-CLOSED
    status: verified_closed
  - id: TASK-CLAIMED-DONE
    status: claimed_done
  - id: TASK-NEEDS-EVIDENCE
    status: needs_evidence
  - id: TASK-IN-PROGRESS
    status: in_progress
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

# ── Test 8 (E2E): verified_closed is plain-terminal -> shipped script PASSES ─
test_8_verified_closed_pass() {
  log "Test 8 (E2E): status=verified_closed -> shipped leadv2-phase8-assert.sh full PASS (exit 0)"
  local task_id="E2E-VERIFIED-CLOSED-$$" root
  root="$(_e2e_new_project "$task_id")"
  _e2e_write_tasks_yaml "$root" "$task_id" "verified_closed"
  _e2e_run "$root" "$task_id"
  if [[ "$E2E_RC" -eq 0 ]] && grep -q "A2 tasks.yaml: ${task_id} has terminal status" <<<"$E2E_ERR"; then
    pass "Test 8: verified_closed -> shipped script exit 0 with A2 PASS logged (D-VOCAB: was missing from TERMINAL_STATUSES)"
  else
    fail "Test 8: expected exit 0 + A2 PASS log, got rc=${E2E_RC}: ${E2E_ERR}"
  fi
}

# ── Test 9 (E2E): claimed_done / needs_evidence hit the distinct lane-terminal path ──
# With no artifacts on disk, the shipped script must FAIL -- but via the
# lane-terminal message, not the generic "not terminal" message a plain
# non-terminal status (e.g. in_progress, Test 10) produces. Proves
# claimed_done/needs_evidence are actually routed through the rc=3 branch,
# not silently falling into the generic terminal-status check.
test_9_lane_terminal_distinct_signal() {
  log "Test 9 (E2E): claimed_done|needs_evidence with no artifacts -> shipped script FAILs via the distinct lane-terminal path"
  local ok=1 status task_id root
  for status in claimed_done needs_evidence; do
    task_id="E2E-LANE-${status}-$$"
    root="$(_e2e_new_project "$task_id")"
    _e2e_write_tasks_yaml "$root" "$task_id" "$status"
    _e2e_run "$root" "$task_id"
    if [[ "$E2E_RC" -ne 1 ]] || ! grep -q "lane-terminal" <<<"$E2E_ERR"; then
      ok=0
      log "  ${status}: expected exit 1 + 'lane-terminal' in stderr, got rc=${E2E_RC}: ${E2E_ERR}"
    fi
  done
  if [[ "$ok" -eq 1 ]]; then
    pass "Test 9: claimed_done and needs_evidence both hit the distinct lane-terminal FAIL path (no artifacts present)"
  else
    fail "Test 9: lane-terminal signal not observed for one or both statuses"
  fi
}

# ── Test 10: in_progress is neither terminal nor lane-terminal -> A2 FAILS ───
# Anti-fail-open for the NEW vocabulary, same guarantee as Test 4/5.
test_10_in_progress_fails() {
  log "Test 10: status=in_progress -> A2 still FAILS (exit 1) -- must never become always-pass"
  local rc=0
  _run_a2 "TASK-IN-PROGRESS" "$LANE_YAML" >/dev/null 2>&1 || rc=$?
  if [[ "$rc" -eq 1 ]]; then
    pass "Test 10: in_progress -> exit 1 (FAIL, correctly not fail-open)"
  else
    fail "Test 10: expected exit 1, got exit ${rc}"
  fi
}

# ── Test 11 (E2E): claimed_done + release receipt (outcome: completed_success) ──
# ── + phase-8 evidence BOTH present -> shipped script full PASS ─────────────
test_11_claimed_done_with_artifacts_pass() {
  log "Test 11 (E2E): claimed_done + release receipt (outcome: completed_success) + phase-8 evidence BOTH present -> shipped script full PASS"
  local task_id="E2E-CD-ARTIFACTS-$$" root
  root="$(_e2e_new_project "$task_id")"
  _e2e_write_tasks_yaml "$root" "$task_id" "claimed_done"
  printf -- 'task_id: %s\noutcome: completed_success\n' "$task_id" \
    > "${root}/docs/leadv2/closed/.tasks-sentinel-${task_id}.yaml"
  touch "${root}/docs/handoff/${task_id}/phase8-passed.flag"
  _e2e_run "$root" "$task_id"
  if [[ "$E2E_RC" -eq 0 ]]; then
    pass "Test 11: claimed_done + both artifacts (success receipt) -> shipped script exit 0"
  else
    fail "Test 11: expected exit 0, got rc=${E2E_RC}: ${E2E_ERR}"
  fi
}

# ── Test 12 (E2E): claimed_done WITHOUT a qualifying artifact set -> shipped ──
# ── script FAILs in every variant. Not tautological: proves BOTH files must ──
# ── be present AND the receipt's outcome must be completed_success -- a ─────
# ── revert of the AND (leadv2-phase8-assert.sh rc==3 branch) to an OR flips ──
# ── 12b/12c to unexpectedly PASS; a regression that drops the outcome check ──
# ── (fix-round-1 Finding 1) flips 12d to unexpectedly PASS. ─────────────────
test_12_claimed_done_without_artifacts_fails() {
  log "Test 12 (E2E): claimed_done missing receipt / sentinel / success-outcome -> shipped script FAILs in every case (not fail-open)"
  local ok=1 task_id root

  # (a) neither artifact
  task_id="E2E-CD-NONE-$$"; root="$(_e2e_new_project "$task_id")"
  _e2e_write_tasks_yaml "$root" "$task_id" "claimed_done"
  _e2e_run "$root" "$task_id"
  [[ "$E2E_RC" -eq 1 ]] || { ok=0; log "  (a) neither artifact: expected FAIL(1), got rc=${E2E_RC}"; }

  # (b) receipt present (success outcome), sentinel missing -- distinguishes AND from OR
  task_id="E2E-CD-NOSENTINEL-$$"; root="$(_e2e_new_project "$task_id")"
  _e2e_write_tasks_yaml "$root" "$task_id" "claimed_done"
  printf -- 'task_id: %s\noutcome: completed_success\n' "$task_id" \
    > "${root}/docs/leadv2/closed/.tasks-sentinel-${task_id}.yaml"
  _e2e_run "$root" "$task_id"
  [[ "$E2E_RC" -eq 1 ]] || { ok=0; log "  (b) no sentinel: expected FAIL(1), got rc=${E2E_RC}"; }

  # (c) sentinel present, receipt missing -- distinguishes AND from OR
  task_id="E2E-CD-NORECEIPT-$$"; root="$(_e2e_new_project "$task_id")"
  _e2e_write_tasks_yaml "$root" "$task_id" "claimed_done"
  touch "${root}/docs/handoff/${task_id}/phase8-passed.flag"
  _e2e_run "$root" "$task_id"
  [[ "$E2E_RC" -eq 1 ]] || { ok=0; log "  (c) no receipt: expected FAIL(1), got rc=${E2E_RC}"; }

  # (d) both files present but receipt outcome=poison (Finding 1 regression guard)
  task_id="E2E-CD-POISONRECEIPT-$$"; root="$(_e2e_new_project "$task_id")"
  _e2e_write_tasks_yaml "$root" "$task_id" "claimed_done"
  printf -- 'task_id: %s\noutcome: poison\n' "$task_id" \
    > "${root}/docs/leadv2/closed/.tasks-sentinel-${task_id}.yaml"
  touch "${root}/docs/handoff/${task_id}/phase8-passed.flag"
  _e2e_run "$root" "$task_id"
  [[ "$E2E_RC" -eq 1 ]] || { ok=0; log "  (d) poison-outcome receipt: expected FAIL(1), got rc=${E2E_RC}"; }

  if [[ "$ok" -eq 1 ]]; then
    pass "Test 12: neither / missing-sentinel-only / missing-receipt-only / poison-outcome-receipt all -> shipped script FAIL"
  else
    fail "Test 12: at least one non-qualifying-evidence variant did not FAIL"
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
  test_8_verified_closed_pass
  test_9_lane_terminal_distinct_signal
  test_10_in_progress_fails
  test_11_claimed_done_with_artifacts_pass
  test_12_claimed_done_without_artifacts_fails
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
