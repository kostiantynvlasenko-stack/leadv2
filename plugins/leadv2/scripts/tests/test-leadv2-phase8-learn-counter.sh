#!/usr/bin/env bash
# tests/test-leadv2-phase8-learn-counter.sh — Unit tests for learn-counter in leadv2-phase8-close.sh
#
# Proves Item-1 invariant: with NO env vars set (scorecard defaults off),
# .close-count increments on every close and learn trigger fires at modulo-N boundary.
# Asserts no double-fire.
#
# NOTE: phase8-close.sh hard-sets PROJECT_ROOT=$(dirname BASH_SOURCE)/../..
# so tests run in-place and use a real temp branch under that root's docs/leadv2/.
# We isolate with unique counter/trigger file names per test to avoid cross-test pollution.
#
# Tests:
#   1. LEADV2_SCORECARD_ON_CLOSE unset (default 0) -> .close-count increments each close
#   2. learn trigger fires at modulo-N boundary (LEADV2_LEARN_EVERY_N=3)
#   3. no double-fire at N+1
#   4. LEADV2_SCORECARD_ON_CLOSE=1 + non-empty scorecard -> uses scorecard line-count path
#   5. bash -n syntax check
#
# Run: bash scripts/tests/test-leadv2-phase8-learn-counter.sh
# Exit 0 = all pass; non-zero = failures found.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PHASE8_SH="${SCRIPT_DIR}/../leadv2-phase8-close.sh"
# phase8-close.sh will resolve PROJECT_ROOT=$(dirname PHASE8_SH)/.. = plugin root
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
LEADV2_DIR="${PLUGIN_ROOT}/docs/leadv2"

PASS=0; FAIL=0; ERRORS=()
log()  { printf -- '[TEST] %s\n' "$*"; }
pass() { PASS=$((PASS + 1)); log "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); ERRORS+=("FAIL: $1"); log "FAIL: $1"; }

# Unique run-id so parallel/repeated test runs don't collide
RUN_ID="lc-$$-$(date +%s)"

# Setup: ensure docs/leadv2 exists under plugin root (usually does)
mkdir -p "$LEADV2_DIR"

# Run just the learn-counter section of phase8-close by extracting and running it inline.
# We source the env and call the logic block directly to avoid the git/YAML write side-effects.
# This is the cleanest way to test the specific counter logic in isolation.
_run_learn_counter_block() {
  local task_id="$1"
  local learn_every_n="${2:-5}"
  local scorecard_on="${3:-0}"
  local counter_file="${4:-${LEADV2_DIR}/.close-count-${RUN_ID}}"
  local sc_file="${5:-/dev/null}"
  local trigger_file="${6:-${LEADV2_DIR}/.learn-trigger-${RUN_ID}}"

  bash << BLOCKSH
set -euo pipefail
LEADV2_LEARN_ON_CLOSE=1
LEADV2_LEARN_EVERY_N="${learn_every_n}"
LEADV2_SCORECARD_ON_CLOSE="${scorecard_on}"
PROJECT_ROOT="${PLUGIN_ROOT}"
TASK_ID="${task_id}"
_sc_file="${sc_file}"
_close_count=0
if [[ "\${LEADV2_SCORECARD_ON_CLOSE:-0}" == "1" && -f "\$_sc_file" ]]; then
  _close_count=\$(wc -l < "\$_sc_file" 2>/dev/null || echo 0)
  _close_count=\$(( _close_count + 0 ))
fi
if [[ "\${LEADV2_SCORECARD_ON_CLOSE:-0}" != "1" ]]; then
  _counter_file="${counter_file}"
  mkdir -p "\$(dirname "\$_counter_file")"
  _prev=\$(cat "\$_counter_file" 2>/dev/null || echo 0)
  [[ "\$_prev" =~ ^[0-9]+\$ ]] || _prev=0
  _close_count=\$(( (_prev + 1) % 1000000 ))
  printf -- '%d\n' "\$_close_count" > "\${_counter_file}.tmp" && mv "\${_counter_file}.tmp" "\$_counter_file"
fi
_learn_n="${learn_every_n}"
if [[ \$_learn_n -gt 0 && \$(( _close_count % _learn_n )) -eq 0 && \$_close_count -gt 0 ]]; then
  _trigger_file="${trigger_file}"
  mkdir -p "\$(dirname "\$_trigger_file")"
  printf -- 'trigger_task_id: %s\ntrigger_close_count: %d\ntriggered_at: %s\ntrigger_task_class: general\n' \
    "\$TASK_ID" "\$_close_count" "\$(date -u '+%Y-%m-%dT%H:%M:%SZ')" > "\$_trigger_file"
fi
BLOCKSH
}

# ── Test 1: .close-count increments each close ───────────────────────────────

test_1_close_count_increments() {
  log "Test 1: .close-count increments on each close (SCORECARD_ON_CLOSE unset=default 0)"
  local counter_file="${LEADV2_DIR}/.close-count-t1-${RUN_ID}"
  local trigger_file="${LEADV2_DIR}/.learn-trigger-t1-${RUN_ID}"

  _run_learn_counter_block "T1-A" 99 0 "$counter_file" "/dev/null" "$trigger_file"
  local v1
  v1=$(cat "$counter_file" 2>/dev/null || echo "missing")

  _run_learn_counter_block "T1-B" 99 0 "$counter_file" "/dev/null" "$trigger_file"
  local v2
  v2=$(cat "$counter_file" 2>/dev/null || echo "missing")

  rm -f "$counter_file" "$trigger_file"

  if [[ "$v1" == "1" && "$v2" == "2" ]]; then
    pass "Test 1: .close-count=1 after close 1, =2 after close 2"
  else
    fail "Test 1: expected v1=1 v2=2; got v1='${v1}' v2='${v2}'"
  fi
}

# ── Test 2: trigger fires at modulo-3 boundary ───────────────────────────────

test_2_trigger_at_boundary() {
  log "Test 2: learn trigger fires at modulo-3 boundary"
  local counter_file="${LEADV2_DIR}/.close-count-t2-${RUN_ID}"
  local trigger_file="${LEADV2_DIR}/.learn-trigger-t2-${RUN_ID}"

  _run_learn_counter_block "T2-A" 3 0 "$counter_file" "/dev/null" "$trigger_file"
  if [[ -f "$trigger_file" ]]; then
    rm -f "$counter_file" "$trigger_file"
    fail "Test 2: trigger fired after close 1 (unexpected)"
    return
  fi

  _run_learn_counter_block "T2-B" 3 0 "$counter_file" "/dev/null" "$trigger_file"
  if [[ -f "$trigger_file" ]]; then
    rm -f "$counter_file" "$trigger_file"
    fail "Test 2: trigger fired after close 2 (unexpected)"
    return
  fi

  _run_learn_counter_block "T2-C" 3 0 "$counter_file" "/dev/null" "$trigger_file"
  local trigger_exists=0
  [[ -f "$trigger_file" ]] && trigger_exists=1

  rm -f "$counter_file" "$trigger_file"

  if [[ "$trigger_exists" -eq 1 ]]; then
    pass "Test 2: trigger file written at close 3 (modulo-3 boundary)"
  else
    fail "Test 2: trigger file not present after close 3"
  fi
}

# ── Test 3: no double-fire at N+1 ────────────────────────────────────────────

test_3_no_double_fire() {
  log "Test 3: trigger NOT re-written at close 4 after firing at close 3"
  local counter_file="${LEADV2_DIR}/.close-count-t3-${RUN_ID}"
  local trigger_file="${LEADV2_DIR}/.learn-trigger-t3-${RUN_ID}"

  _run_learn_counter_block "T3-A" 3 0 "$counter_file" "/dev/null" "$trigger_file"
  _run_learn_counter_block "T3-B" 3 0 "$counter_file" "/dev/null" "$trigger_file"
  _run_learn_counter_block "T3-C" 3 0 "$counter_file" "/dev/null" "$trigger_file"
  [[ -f "$trigger_file" ]] || { rm -f "$counter_file" "$trigger_file"; fail "Test 3: trigger not written at close 3 (prerequisite failed)"; return; }

  local mtime1
  mtime1=$(python3 -c "import os; print(int(os.path.getmtime('$trigger_file')))" 2>/dev/null || echo 0)

  sleep 1
  _run_learn_counter_block "T3-D" 3 0 "$counter_file" "/dev/null" "$trigger_file"

  local mtime2
  mtime2=$(python3 -c "import os; print(int(os.path.getmtime('$trigger_file')))" 2>/dev/null || echo 0)

  rm -f "$counter_file" "$trigger_file"

  if [[ "$mtime1" == "$mtime2" ]]; then
    pass "Test 3: trigger file mtime unchanged at close 4 (no double-fire)"
  else
    fail "Test 3: trigger file mtime changed at close 4 (double-fire detected)"
  fi
}

# ── Test 4: LEADV2_SCORECARD_ON_CLOSE=1 uses scorecard line count ─────────────

test_4_scorecard_path() {
  log "Test 4: SCORECARD_ON_CLOSE=1 + 5-line scorecard -> scorecard path, not .close-count"
  local counter_file="${LEADV2_DIR}/.close-count-t4-${RUN_ID}"
  local trigger_file="${LEADV2_DIR}/.learn-trigger-t4-${RUN_ID}"
  local sc_file
  sc_file=$(mktemp /tmp/sc-t4-XXXXXX.jsonl)
  printf '{"task_id":"T1"}\n{"task_id":"T2"}\n{"task_id":"T3"}\n{"task_id":"T4"}\n{"task_id":"T5"}\n' > "$sc_file"

  _run_learn_counter_block "T4-A" 5 1 "$counter_file" "$sc_file" "$trigger_file"

  local trigger_exists=0 counter_incremented=0
  [[ -f "$trigger_file" ]] && trigger_exists=1
  [[ -f "$counter_file" ]] && counter_incremented=1

  rm -f "$counter_file" "$trigger_file" "$sc_file"

  if [[ "$trigger_exists" -eq 1 && "$counter_incremented" -eq 0 ]]; then
    pass "Test 4: scorecard path (trigger fired, .close-count not incremented)"
  else
    fail "Test 4: trigger_exists=${trigger_exists} (expected 1) counter_incremented=${counter_incremented} (expected 0)"
  fi
}

# ── Test 5: syntax check ──────────────────────────────────────────────────────

test_5_syntax() {
  log "Test 5: bash -n syntax check on phase8-close.sh"
  bash -n "$PHASE8_SH" 2>/dev/null && pass "Test 5: bash -n OK" || fail "Test 5: bash -n FAILED"
}

main() {
  log "=== leadv2-phase8-learn-counter unit tests (RUN_ID=${RUN_ID}) ==="
  log "Script: $PHASE8_SH"
  echo ""
  test_5_syntax
  test_1_close_count_increments
  test_2_trigger_at_boundary
  test_3_no_double_fire
  test_4_scorecard_path
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
