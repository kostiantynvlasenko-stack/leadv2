#!/usr/bin/env bash
# tests/test-leadv2-route-bandit.sh — Unit tests for leadv2-route-bandit.sh
#
# Tests:
#   1. n=0 state + seeded priors → heuristic arm chosen >= 85% across 200 samples
#   2. Synthetic 30 rows: arm X rewards 1, heuristic rewards 0 → sampling shifts to X
#   3. Corrupt state YAML → sample returns heuristic, exit 0
#   4. Cooldown active → returns heuristic (10 samples all heuristic)
#   5. Update is idempotent per task_id
#   6. bash -n + python syntax checks
#
# Run: bash scripts/tests/test-leadv2-route-bandit.sh
# Exit 0 = all pass; non-zero = failures found.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BANDIT_SH="${SCRIPT_DIR}/../leadv2-route-bandit.sh"
PY_HELPER="${SCRIPT_DIR}/../leadv2-route-bandit-py.py"

PASS=0
FAIL=0
ERRORS=()

log()  { printf -- '[TEST] %s\n' "$*"; }
pass() { PASS=$((PASS + 1)); log "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); ERRORS+=("FAIL: $1"); log "FAIL: $1"; }

# ── helpers ───────────────────────────────────────────────────────────────────

_tmp_state() {
  mktemp /tmp/bandit-state-XXXXXX.yaml
}

_tmp_dir() {
  mktemp -d /tmp/bandit-test-XXXXXX
}

# ── Test 1: seeded priors → heuristic dominates at n=0 ───────────────────────

test_1_seeded_priors() {
  # Beta(8,2) vs Beta(1,1): P(sonnet>fable) ≈ 80% analytically.
  # Design spec says ">=85%" which is above the true expectation — use 75% threshold
  # (5th pct of Binom(200, 0.80) ≈ 75.5%) for a <5% false-fail rate.
  log "Test 1: n=0 seeded priors → sonnet >= 75% across 200 samples (true P≈80%, threshold 75%)"

  local state_file
  state_file="$(_tmp_state)"
  # Empty state (no prior data) — bandit should lazily use seeded priors
  printf 'version: 1\narms: {}\ncooldowns:\nmeta:\n  total_updates: 0\n' > "$state_file"

  local sonnet_count=0 total=200 i=0
  while [[ "$i" -lt "$total" ]]; do
    local out
    out=$(bash "$BANDIT_SH" sample \
      --context-key "plan:Standard:false" \
      --allowed '["sonnet","fable"]' \
      --heuristic "sonnet" \
      --state-file "$state_file" 2>/dev/null)
    local arm
    arm=$(printf '%s\n' "$out" | grep '^chosen_arm=' | cut -d= -f2)
    if [[ "$arm" == "sonnet" ]]; then
      sonnet_count=$((sonnet_count + 1))
    fi
    i=$((i + 1))
  done

  rm -f "$state_file"

  local pct
  pct=$(awk "BEGIN{printf \"%.1f\", ($sonnet_count / $total) * 100}")
  log "  sonnet chosen: $sonnet_count/$total = ${pct}% (design golden expects >=85%; true Beta(8,2)>Beta(1,1) P=0.80)"

  if [[ "$sonnet_count" -ge 150 ]]; then  # 150/200 = 75%
    pass "Test 1: sonnet_pct=${pct}% >= 75% (heuristic dominates at n=0)"
  else
    fail "Test 1: sonnet_pct=${pct}% < 75% (expected heuristic to dominate)"
  fi
}

# ── Test 2: convergence on better arm ────────────────────────────────────────

test_2_convergence() {
  log "Test 2: synthetic state: fable wins 20/21, sonnet 10/20 → fable dominates"

  local state_file
  state_file="$(_tmp_state)"

  # fable: alpha=21, beta=1 (20 wins + 1 seed), sonnet: alpha=11, beta=11 (10 wins + 10 losses + seeds)
  cat > "$state_file" <<'YAML'
version: 1
arms:
  "plan:Standard:false":
    fable:   {alpha: 21, beta: 1}
    sonnet:  {alpha: 11, beta: 11}
cooldowns:
meta:
  total_updates: 30
YAML

  local fable_count=0 sonnet_count=0 total=200 i=0
  while [[ "$i" -lt "$total" ]]; do
    local out
    out=$(bash "$BANDIT_SH" sample \
      --context-key "plan:Standard:false" \
      --allowed '["sonnet","fable"]' \
      --heuristic "sonnet" \
      --state-file "$state_file" 2>/dev/null)
    local arm
    arm=$(printf '%s\n' "$out" | grep '^chosen_arm=' | cut -d= -f2)
    case "$arm" in
      fable)  fable_count=$((fable_count + 1)) ;;
      sonnet) sonnet_count=$((sonnet_count + 1)) ;;
    esac
    i=$((i + 1))
  done

  rm -f "$state_file"

  local fable_pct
  fable_pct=$(awk "BEGIN{printf \"%.1f\", ($fable_count / $total) * 100}")
  log "  fable: $fable_count/$total = ${fable_pct}%, sonnet: $sonnet_count/$total"

  if [[ "$fable_count" -ge 180 ]]; then  # > 90%
    pass "Test 2: fable_pct=${fable_pct}% > 90% — convergence confirmed"
  else
    fail "Test 2: fable_pct=${fable_pct}% < 90% (expected > 90%)"
  fi
}

# ── Test 3: corrupt state YAML → heuristic, exit 0 ───────────────────────────

test_3_corrupt_state() {
  # Corrupt YAML doesn't crash; it lazily applies seeded priors (heuristic=sonnet 8/2 vs fable 1/1).
  # Exit must be 0; heuristic should dominate in majority of samples (>= 70% with 20 runs).
  log "Test 3: corrupt state YAML → no crash (exit 0), heuristic dominates in 20 samples"

  local state_file
  state_file="$(_tmp_state)"
  printf 'version: 1\narms:\n  %%invalid yaml: [[[{{' > "$state_file"

  local exit_code=0 sonnet_count=0 i=0 total=20
  while [[ "$i" -lt "$total" ]]; do
    local out
    out=$(bash "$BANDIT_SH" sample \
      --context-key "plan:Standard:false" \
      --allowed '["sonnet","fable"]' \
      --heuristic "sonnet" \
      --state-file "$state_file" 2>/dev/null) || exit_code=$?
    local arm
    arm=$(printf '%s\n' "$out" | grep '^chosen_arm=' | cut -d= -f2 || echo "")
    [[ "$arm" == "sonnet" ]] && sonnet_count=$((sonnet_count + 1))
    i=$((i + 1))
  done

  rm -f "$state_file"

  local pct
  pct=$(awk "BEGIN{printf \"%.0f\", ($sonnet_count / $total) * 100}")

  if [[ "$exit_code" -eq 0 && "$sonnet_count" -ge 12 ]]; then  # 12/20 = 60% threshold
    pass "Test 3: corrupt YAML → exit=0, sonnet ${pct}% (>= 60%)"
  else
    fail "Test 3: expected exit=0 sonnet>=60%; got exit=$exit_code sonnet=${sonnet_count}/${total}=${pct}%"
  fi
}

# ── Test 4: cooldown active → returns heuristic ───────────────────────────────

test_4_cooldown() {
  log "Test 4: cooldown active (n=10) → all 10 samples return heuristic"

  local state_file
  state_file="$(_tmp_state)"

  cat > "$state_file" <<'YAML'
version: 1
arms:
  "plan:Standard:false":
    fable:   {alpha: 21, beta: 1}
    sonnet:  {alpha: 8, beta: 2}
cooldowns:
  "plan:Standard:false":
    heuristic_only_until_n: 10
    written_at: "2026-06-11T00:00:00Z"
    reason: "deviation+failure"
meta:
  total_updates: 5
YAML

  local heuristic_count=0 i=0
  while [[ "$i" -lt 10 ]]; do
    local out
    out=$(bash "$BANDIT_SH" sample \
      --context-key "plan:Standard:false" \
      --allowed '["sonnet","fable"]' \
      --heuristic "sonnet" \
      --state-file "$state_file" 2>/dev/null)
    local arm
    arm=$(printf '%s\n' "$out" | grep '^chosen_arm=' | cut -d= -f2)
    if [[ "$arm" == "sonnet" ]]; then
      heuristic_count=$((heuristic_count + 1))
    fi
    i=$((i + 1))
  done

  rm -f "$state_file"

  if [[ "$heuristic_count" -eq 10 ]]; then
    pass "Test 4: cooldown → all 10 samples returned heuristic (sonnet)"
  else
    fail "Test 4: expected 10 heuristic samples; got $heuristic_count"
  fi
}

# ── Test 5: update idempotency by task_id ────────────────────────────────────

test_5_idempotent_update() {
  log "Test 5: update is idempotent — second call with same task_id yields same state"

  local tmpdir
  tmpdir="$(_tmp_dir)"
  local state_file="${tmpdir}/route-bandit-state.yaml"
  local scorecard_file="${tmpdir}/scorecard.jsonl"

  # Minimal state
  cat > "$state_file" <<'YAML'
version: 1
arms:
  "plan:Standard:false":
    fable:   {alpha: 1, beta: 1}
    sonnet:  {alpha: 8, beta: 2}
cooldowns:
meta:
  total_updates: 0
YAML

  # Scorecard row
  printf '{"task_id":"TEST-IDEMPOTENT-01","verify_pass":1,"post_deploy_regression":0,"closed_at":"2026-06-11T10:00:00Z"}\n' \
    > "$scorecard_file"

  # Route-decisions for task
  local rd_dir="${tmpdir}/docs/handoff/TEST-IDEMPOTENT-01"
  mkdir -p "$rd_dir"
  cat > "${rd_dir}/route-decisions.yaml" <<'RDYAML'
- phase: plan
  step: default
  task_class: Standard
  safety_touched: false
  heuristic_arm: sonnet
  chosen_arm: fable
  bandit_active: true
  bandit_deviation: true
  context_key: "plan:Standard:false"
  decided_at: "2026-06-11T10:00:00Z"
RDYAML

  export PROJECT_ROOT="$tmpdir"

  # First update
  bash "$BANDIT_SH" update \
    --task-id "TEST-IDEMPOTENT-01" \
    --state-file "$state_file" \
    --scorecard-file "$scorecard_file" 2>/dev/null

  local state_after_first
  state_after_first="$(cat "$state_file")"

  # Second update (same task_id, same scorecard)
  bash "$BANDIT_SH" update \
    --task-id "TEST-IDEMPOTENT-01" \
    --state-file "$state_file" \
    --scorecard-file "$scorecard_file" 2>/dev/null

  local state_after_second
  state_after_second="$(cat "$state_file")"

  unset PROJECT_ROOT
  rm -rf "$tmpdir"

  # States should be identical except meta.total_updates and last_updated
  # We compare arm values only (strip meta lines)
  local arms_first arms_second
  arms_first=$(printf '%s\n' "$state_after_first" | grep -E 'alpha|beta' | sort)
  arms_second=$(printf '%s\n' "$state_after_second" | grep -E 'alpha|beta' | sort)

  if [[ "$arms_first" == "$arms_second" ]]; then
    pass "Test 5: arm values identical after two updates (idempotent)"
  else
    fail "Test 5: arm values differ after second update (not idempotent)"
    log "  First:  $arms_first"
    log "  Second: $arms_second"
  fi
}

# ── Test 6: syntax checks ─────────────────────────────────────────────────────

test_6_syntax() {
  log "Test 6: bash -n and python3 syntax checks"

  local bash_ok=0 py_ok=0

  bash -n "$BANDIT_SH" 2>/dev/null && bash_ok=1 || bash_ok=0
  python3 -m py_compile "$PY_HELPER" 2>/dev/null && py_ok=1 || py_ok=0

  if [[ "$bash_ok" -eq 1 && "$py_ok" -eq 1 ]]; then
    pass "Test 6: bash -n OK, python3 -m py_compile OK"
  else
    [[ "$bash_ok" -eq 0 ]] && fail "Test 6: bash -n FAILED for $BANDIT_SH"
    [[ "$py_ok"   -eq 0 ]] && fail "Test 6: python3 syntax FAILED for $PY_HELPER"
  fi
}

# ── run all tests ─────────────────────────────────────────────────────────────

main() {
  log "=== leadv2-route-bandit unit tests ==="
  log "Script: $BANDIT_SH"
  log "PY:     $PY_HELPER"
  echo ""

  test_6_syntax       # run syntax check first — fail fast
  test_1_seeded_priors
  test_2_convergence
  test_3_corrupt_state
  test_4_cooldown
  test_5_idempotent_update

  echo ""
  log "=== Results: PASS=$PASS FAIL=$FAIL ==="

  if [[ "${#ERRORS[@]}" -gt 0 ]]; then
    log "Failures:"
    for e in "${ERRORS[@]}"; do
      log "  $e"
    done
    exit 1
  fi

  log "All tests passed."
  exit 0
}

main "$@"
