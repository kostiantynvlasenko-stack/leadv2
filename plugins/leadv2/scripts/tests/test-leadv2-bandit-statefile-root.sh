#!/usr/bin/env bash
# tests/test-leadv2-bandit-statefile-root.sh — Verify route-bandit state file resolves under
# LEADV2_PROJECT_ROOT, not $SCRIPT_DIR/../..
#
# Tests:
#   1. update with LEADV2_PROJECT_ROOT=<tempdir> -> state file under tempdir, not plugin tree
#   2. sample with LEADV2_PROJECT_ROOT=<tempdir> -> reads state from tempdir path
#   3. bash -n syntax check
#
# Run: bash scripts/tests/test-leadv2-bandit-statefile-root.sh
# Exit 0 = all pass; non-zero = failures found.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BANDIT_SH="${SCRIPT_DIR}/../leadv2-route-bandit.sh"

PASS=0; FAIL=0; ERRORS=()
log()  { printf -- '[TEST] %s\n' "$*"; }
pass() { PASS=$((PASS + 1)); log "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); ERRORS+=("FAIL: $1"); log "FAIL: $1"; }
_tmp_dir() { mktemp -d /tmp/bsr-test-XXXXXX; }

# ── Test 1: update resolves state file under LEADV2_PROJECT_ROOT ──────────────

test_1_update_uses_project_root() {
  log "Test 1: update with LEADV2_PROJECT_ROOT -> state file resolves under that root"

  local tmpdir task_id="BSR-T1"
  tmpdir="$(_tmp_dir)"
  mkdir -p "${tmpdir}/docs/leadv2"
  mkdir -p "${tmpdir}/docs/handoff/${task_id}"

  # Seed a scorecard row so update has something to process
  printf '{"task_id":"%s","verify_pass":1,"post_deploy_regression":0,"closed_at":"2026-06-17T10:00:00Z"}\n' \
    "$task_id" > "${tmpdir}/docs/leadv2/scorecard.jsonl"

  # Route-decisions for the task
  cat > "${tmpdir}/docs/handoff/${task_id}/route-decisions.yaml" << 'RDYAML'
- phase: plan
  step: default
  task_class: Standard
  safety_touched: false
  heuristic_arm: sonnet
  chosen_arm: sonnet
  bandit_active: true
  bandit_deviation: false
  context_key: "plan:Standard:false"
  decided_at: "2026-06-17T10:00:00Z"
RDYAML

  LEADV2_PROJECT_ROOT="$tmpdir" PROJECT_ROOT="$tmpdir" \
    bash "$BANDIT_SH" update --task-id "$task_id" 2>/dev/null || true

  local expected_state="${tmpdir}/docs/leadv2/route-bandit-state.yaml"
  local state_in_tmpdir=0
  [[ -f "$expected_state" ]] && state_in_tmpdir=1

  # Assert state was NOT written inside the plugin scripts tree
  local plugin_state_path="${SCRIPT_DIR}/../../docs/leadv2/route-bandit-state.yaml"
  local state_in_plugin=0
  [[ -f "$plugin_state_path" ]] && state_in_plugin=1

  rm -rf "$tmpdir"

  if [[ "$state_in_tmpdir" -eq 1 && "$state_in_plugin" -eq 0 ]]; then
    pass "Test 1: state file in tmpdir; not in plugin tree"
  else
    fail "Test 1: state_in_tmpdir=${state_in_tmpdir} (expected 1) state_in_plugin=${state_in_plugin} (expected 0)"
  fi
}

# ── Test 2: sample reads state from LEADV2_PROJECT_ROOT ──────────────────────

test_2_sample_uses_project_root() {
  log "Test 2: sample with LEADV2_PROJECT_ROOT -> reads state from that root path"

  local tmpdir
  tmpdir="$(_tmp_dir)"
  mkdir -p "${tmpdir}/docs/leadv2"

  local state_file="${tmpdir}/docs/leadv2/route-bandit-state.yaml"
  # Write a state with fable strongly dominant so we can verify it was read
  cat > "$state_file" << 'SYAML'
version: 1
arms:
  "plan:Standard:false":
    fable:  {alpha: 50, beta: 1}
    sonnet: {alpha: 1,  beta: 50}
cooldowns:
meta:
  total_updates: 51
SYAML

  local fable_count=0 total=20 i=0
  while [[ "$i" -lt "$total" ]]; do
    local out arm
    out=$(LEADV2_PROJECT_ROOT="$tmpdir" bash "$BANDIT_SH" sample \
      --context-key "plan:Standard:false" \
      --allowed '["sonnet","fable"]' \
      --heuristic "sonnet" 2>/dev/null || true)
    arm=$(printf '%s\n' "$out" | grep '^chosen_arm=' | cut -d= -f2 || echo "")
    [[ "$arm" == "fable" ]] && fable_count=$((fable_count + 1))
    i=$((i + 1))
  done

  rm -rf "$tmpdir"

  # fable has Beta(50,1) vs sonnet Beta(1,50): P(fable chosen) > 98%; expect >=15/20
  if [[ "$fable_count" -ge 15 ]]; then
    pass "Test 2: fable chosen ${fable_count}/${total} (state read from LEADV2_PROJECT_ROOT)"
  else
    fail "Test 2: fable chosen only ${fable_count}/${total} — state may not have been read from LEADV2_PROJECT_ROOT"
  fi
}

# ── Test 3: syntax check ──────────────────────────────────────────────────────

test_3_syntax() {
  log "Test 3: bash -n syntax check"
  bash -n "$BANDIT_SH" 2>/dev/null && pass "Test 3: bash -n OK" || fail "Test 3: bash -n FAILED"
}

main() {
  log "=== leadv2-bandit-statefile-root unit tests ==="
  log "Script: $BANDIT_SH"
  echo ""
  test_3_syntax
  test_1_update_uses_project_root
  test_2_sample_uses_project_root
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
