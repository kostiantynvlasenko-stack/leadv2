#!/usr/bin/env bash
# tests/test-reply-router-01.sh — LANE-QUESTION-DELIVERY-01: leadv2-reply-router.sh
# must resolve BOTH question stores so `/leadv2 reply <q-id> <option>` never
# hard-fails "not found" just because it happened to check the wrong one.
#
# Tests:
#   1. bash -n syntax check
#   2. control-plane store: multi-word option accepted, question -> answered
#   3. control-plane store: invalid option rejected (exit 3), message names
#      the valid options
#   4. legacy-handoff store: multi-word option accepted via task-id auto-
#      discovery (no --task-id hint needed)
#   5. legacy-handoff store: single-letter option still works (no regression)
#   6. neither store has the qid -> exit 5, message names both paths checked
#   7. --task-id hint disambiguates a legacy qid without a filesystem scan
#
# Portable, sandboxed via LEADV2_STATE_ROOT / PROJECT_ROOT / LEADV2_PROJECT_ROOT
# (same convention as test-questionstore-v2-roundtrip.sh).
# Run: bash scripts/tests/test-reply-router-01.sh

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/leadv2-temp.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROUTER_SH="${SCRIPT_DIR}/../leadv2-reply-router.sh"
ASK_SH="${SCRIPT_DIR}/../leadv2-ask.sh"

PASS=0; FAIL=0; ERRORS=()
log()  { printf -- '[TEST] %s\n' "$*"; }
pass() { PASS=$((PASS + 1)); log "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); ERRORS+=("FAIL: $1"); log "FAIL: $1"; }

TMP_DIR="$(lv2_mktemp_dir "reply-router-test")"
STATE_ROOT="${TMP_DIR}/state"
LINK_ROOT="${TMP_DIR}/link"
mkdir -p "$STATE_ROOT" "$LINK_ROOT"
cleanup() { rm -rf "$TMP_DIR"; return 0; }
trap cleanup EXIT

_route() {
  LEADV2_STATE_ROOT="$STATE_ROOT" PROJECT_ROOT="$LINK_ROOT" LEADV2_PROJECT_ROOT="$LINK_ROOT" \
    bash "$ROUTER_SH" "$@"
}

_field() {
  python3 -c '
import sys, yaml
path = sys.argv[2].split(".")
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        d = yaml.safe_load(f) or {}
except FileNotFoundError:
    print("__MISSING__"); sys.exit(0)
cur = d
for p in path:
    if not isinstance(cur, dict):
        cur = None; break
    cur = cur.get(p)
print(cur if cur is not None else "__NONE__")
' "$1" "$2"
}

_write_legacy_pending() {
  # _write_legacy_pending <task_id> <qid> <label1> [<label2> ...]
  local task_id="$1" qid="$2"; shift 2
  local dir="${LINK_ROOT}/docs/handoff/${task_id}/questions-async"
  mkdir -p "$dir"
  {
    printf 'task_id: %s\n' "$task_id"
    printf 'qid: %s\n' "$qid"
    printf 'question: test question\n'
    printf 'options:\n'
    for label in "$@"; do
      printf -- '- label: %s\n  text: option %s\n' "$label" "$label"
    done
  } > "${dir}/${qid}-pending.yaml"
}

test_1_syntax() {
  log "Test 1: bash -n syntax check"
  bash -n "$ROUTER_SH" 2>/dev/null && pass "Test 1: bash -n OK" || fail "Test 1: bash -n FAILED"
}

test_2_control_plane_multiword_accepted() {
  log "Test 2: control-plane store, multi-word option accepted"
  local qid
  qid="$(LEADV2_STATE_ROOT="$STATE_ROOT" PROJECT_ROOT="$LINK_ROOT" \
    bash "$ASK_SH" "CP-T2" "Corroborated dead. Escalate." \
    --option "inspect|inspect logs first" --option "restart|restart the task" --option "abandon|mark abandoned" \
    --no-block 2>/dev/null)"
  [[ -n "$qid" ]] || { fail "Test 2: ask produced no qid"; return; }

  local rc out
  out="$(_route "$qid" "restart" 2>&1)" && rc=0 || rc=$?
  local qf="${STATE_ROOT}/questions/${qid}.yaml"
  local status selected
  status="$(_field "$qf" status)"
  selected="$(_field "$qf" answer.selected)"

  if [[ "$rc" -eq 0 && "$status" == "answered" && "$selected" == "restart" ]]; then
    pass "Test 2: router resolved control-plane qid, status=answered selected=restart"
  else
    fail "Test 2: rc=$rc status=$status selected=$selected out=$out"
  fi
}

test_3_control_plane_invalid_option_named() {
  log "Test 3: control-plane store, invalid option rejected with named valid list"
  local qid
  qid="$(LEADV2_STATE_ROOT="$STATE_ROOT" PROJECT_ROOT="$LINK_ROOT" \
    bash "$ASK_SH" "CP-T3" "Pick one" \
    --option "wait|Wait" --option "stop|Stop" --no-block 2>/dev/null)"
  [[ -n "$qid" ]] || { fail "Test 3: ask produced no qid"; return; }

  local rc out
  out="$(_route "$qid" "bogus" 2>&1)" && rc=0 || rc=$?

  if [[ "$rc" -eq 3 && "$out" == *"wait"* && "$out" == *"stop"* ]]; then
    pass "Test 3: invalid option rejected exit=3, message names wait,stop"
  else
    fail "Test 3: rc=$rc out=$out"
  fi
}

test_4_legacy_multiword_autodiscovered() {
  log "Test 4: legacy-handoff store, multi-word option accepted, task-id auto-discovered"
  local qid="q-legacy0001"
  _write_legacy_pending "TASK-T4" "$qid" "wait" "stop"

  local rc out
  out="$(_route "$qid" "stop" 2>&1)" && rc=0 || rc=$?
  local answered="${LINK_ROOT}/docs/handoff/TASK-T4/questions-async/${qid}-answered.yaml"

  if [[ "$rc" -eq 0 && -f "$answered" ]]; then
    local chosen; chosen="$(_field "$answered" chosen)"
    if [[ "$chosen" == "stop" ]]; then
      pass "Test 4: router auto-discovered legacy task-id and answered chosen=stop"
    else
      fail "Test 4: answered file chosen=$chosen (expected stop)"
    fi
  else
    fail "Test 4: rc=$rc out=$out answered_exists=$([[ -f "$answered" ]] && echo yes || echo no)"
  fi
}

test_5_legacy_single_letter_no_regression() {
  log "Test 5: legacy-handoff store, single-letter option still works (regression check)"
  local qid="q-legacy0002"
  _write_legacy_pending "TASK-T5" "$qid" "a" "b"

  local rc
  _route "$qid" "a" >/dev/null 2>&1 && rc=0 || rc=$?
  local answered="${LINK_ROOT}/docs/handoff/TASK-T5/questions-async/${qid}-answered.yaml"

  if [[ "$rc" -eq 0 && -f "$answered" ]]; then
    pass "Test 5: single-letter option 'a' still accepted (no regression)"
  else
    fail "Test 5: rc=$rc answered_exists=$([[ -f "$answered" ]] && echo yes || echo no)"
  fi
}

test_6_missing_in_both_stores() {
  log "Test 6: qid absent from both stores -> exit 5, names both paths checked"
  local rc out
  out="$(_route "q-doesnotexist" "anything" 2>&1)" && rc=0 || rc=$?

  if [[ "$rc" -eq 5 && "$out" == *"control-plane"* && "$out" == *"questions-async"* ]]; then
    pass "Test 6: exit=5, message names both control-plane and legacy paths"
  else
    fail "Test 6: rc=$rc out=$out"
  fi
}

test_7_task_id_hint_disambiguates() {
  log "Test 7: --task-id hint resolves legacy qid without a directory scan"
  local qid="q-legacy0003"
  # Labels avoid YAML 1.1 boolean literals (yes/no/true/false/on/off parse
  # as bool, not str, under PyYAML safe_load) — an unrelated pre-existing
  # quirk in leadv2-reply.sh's option matching, out of scope here.
  _write_legacy_pending "TASK-T7" "$qid" "approve" "reject"

  local rc
  _route "$qid" "approve" --task-id "TASK-T7" >/dev/null 2>&1 && rc=0 || rc=$?
  local answered="${LINK_ROOT}/docs/handoff/TASK-T7/questions-async/${qid}-answered.yaml"

  if [[ "$rc" -eq 0 && -f "$answered" ]]; then
    pass "Test 7: --task-id hint resolved and answered"
  else
    fail "Test 7: rc=$rc answered_exists=$([[ -f "$answered" ]] && echo yes || echo no)"
  fi
}

main() {
  log "=== leadv2-reply-router.sh dual-store resolution tests ==="
  log "router: $ROUTER_SH"
  echo ""
  test_1_syntax
  test_2_control_plane_multiword_accepted
  test_3_control_plane_invalid_option_named
  test_4_legacy_multiword_autodiscovered
  test_5_legacy_single_letter_no_regression
  test_6_missing_in_both_stores
  test_7_task_id_hint_disambiguates
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
