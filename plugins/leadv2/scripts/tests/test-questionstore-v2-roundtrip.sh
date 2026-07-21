#!/usr/bin/env bash
# tests/test-questionstore-v2-roundtrip.sh — SUPERVISE-V2-01 item 6b:
# control-plane question store V2 (D-a) round-trip for leadv2-ask.sh /
# leadv2-answer.sh.
#
# Tests:
#   1. ask (--no-block) writes a pending V2 record with the expected schema
#   2. answer transitions pending -> answered (compare-and-set), inline
#      answer object populated
#   3. double-answer on the same qid is rejected (exit 4, ALREADY_ANSWERED)
#   4. answering with an option not in options[] is rejected (exit 3)
#   5. answering a nonexistent qid is rejected (exit 5)
#
# Portable: no GNU-only date/sed -i/timeout/flock — sandboxed via
# LEADV2_STATE_ROOT / PROJECT_ROOT env overrides (leadv2-state-path.sh).
# Run: bash scripts/tests/test-questionstore-v2-roundtrip.sh
# Exit 0 = all pass; non-zero = failures found.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/leadv2-temp.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ASK_SH="${SCRIPT_DIR}/../leadv2-ask.sh"
ANSWER_SH="${SCRIPT_DIR}/../leadv2-answer.sh"

PASS=0; FAIL=0; ERRORS=()
log()  { printf -- '[TEST] %s\n' "$*"; }
pass() { PASS=$((PASS + 1)); log "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); ERRORS+=("FAIL: $1"); log "FAIL: $1"; }

TMP_DIR="$(lv2_mktemp_dir "qsv2-test")"
STATE_ROOT="${TMP_DIR}/state"
LINK_ROOT="${TMP_DIR}/link"
mkdir -p "$STATE_ROOT" "$LINK_ROOT"
cleanup() { rm -rf "$TMP_DIR"; return 0; }
trap cleanup EXIT

_ask() {
  # _ask <task-id> <question> <opt-label|desc>...
  local task_id="$1" question="$2"; shift 2
  local opts=()
  for o in "$@"; do opts+=(--option "$o"); done
  LEADV2_STATE_ROOT="$STATE_ROOT" PROJECT_ROOT="$LINK_ROOT" \
    bash "$ASK_SH" "$task_id" "$question" "${opts[@]}" --no-block 2>/dev/null
}

_answer() {
  local qid="$1" option="$2"
  LEADV2_STATE_ROOT="$STATE_ROOT" PROJECT_ROOT="$LINK_ROOT" \
    bash "$ANSWER_SH" "$qid" "$option"
}

_qfile() { printf -- '%s/questions/%s.yaml' "$STATE_ROOT" "$1"; }

_field() {
  # _field <qfile> <dotted-path e.g. status or answer.selected>
  python3 -c '
import sys, yaml
path = sys.argv[2].split(".")
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        d = yaml.safe_load(f) or {}
except FileNotFoundError:
    print("__MISSING__")
    sys.exit(0)
cur = d
for p in path:
    if not isinstance(cur, dict):
        cur = None
        break
    cur = cur.get(p)
print(cur if cur is not None else "__NONE__")
' "$1" "$2"
}

# ── Test 1: ask writes pending V2 record ────────────────────────────────────

QID1=""
test_1_ask_writes_pending() {
  log "Test 1: ask --no-block writes a pending V2 record"
  QID1="$(_ask "QSV2-T1" "Deploy now?" "yes|Deploy immediately" "no|Wait for review")"

  if [[ -z "$QID1" ]]; then
    fail "Test 1: ask produced no qid"
    return
  fi
  local qf status sv task
  qf="$(_qfile "$QID1")"
  status="$(_field "$qf" status)"
  sv="$(_field "$qf" schema_version)"
  task="$(_field "$qf" task_id)"
  if [[ -f "$qf" && "$status" == "pending" && "$sv" == "2" && "$task" == "QSV2-T1" ]]; then
    pass "Test 1: qid=$QID1 status=pending schema_version=2"
  else
    fail "Test 1: qf=$qf status=$status schema_version=$sv task=$task"
  fi
}

# ── Test 2: answer transitions pending -> answered ─────────────────────────

test_2_answer_roundtrip() {
  log "Test 2: answer transitions pending -> answered with inline answer object"
  [[ -n "$QID1" ]] || { fail "Test 2: no qid from Test 1"; return; }

  local rc
  _answer "$QID1" "yes" >/dev/null 2>&1 && rc=0 || rc=$?

  local qf status selected decided_by
  qf="$(_qfile "$QID1")"
  status="$(_field "$qf" status)"
  selected="$(_field "$qf" answer.selected)"
  decided_by="$(_field "$qf" answer.decided_by)"

  if [[ "$rc" -eq 0 && "$status" == "answered" && "$selected" == "yes" && "$decided_by" == "founder" ]]; then
    pass "Test 2: rc=0 status=answered selected=yes decided_by=founder"
  else
    fail "Test 2: rc=$rc status=$status selected=$selected decided_by=$decided_by"
  fi
}

# ── Test 3: double-answer rejected ──────────────────────────────────────────

test_3_double_answer_rejected() {
  log "Test 3: re-answering the same (already-answered) qid is rejected"
  [[ -n "$QID1" ]] || { fail "Test 3: no qid from Test 1"; return; }

  local rc
  _answer "$QID1" "no" >/dev/null 2>&1 && rc=0 || rc=$?

  if [[ "$rc" -eq 4 ]]; then
    pass "Test 3: double-answer rejected with exit 4"
  else
    fail "Test 3: expected exit 4, got rc=$rc"
  fi
}

# ── Test 4: invalid option rejected ─────────────────────────────────────────

test_4_invalid_option_rejected() {
  log "Test 4: answering with an option not in options[] is rejected"
  local qid rc
  qid="$(_ask "QSV2-T4" "Which env?" "staging|Staging" "prod|Production")"
  [[ -n "$qid" ]] || { fail "Test 4: ask produced no qid"; return; }

  _answer "$qid" "not-a-real-option" >/dev/null 2>&1 && rc=0 || rc=$?

  if [[ "$rc" -eq 3 ]]; then
    pass "Test 4: invalid option rejected with exit 3"
  else
    fail "Test 4: expected exit 3, got rc=$rc"
  fi
}

# ── Test 5: nonexistent qid rejected ────────────────────────────────────────

test_5_missing_qid_rejected() {
  log "Test 5: answering a qid that was never asked is rejected"
  local rc
  _answer "q-deadbeef" "yes" >/dev/null 2>&1 && rc=0 || rc=$?

  if [[ "$rc" -eq 5 ]]; then
    pass "Test 5: missing qid rejected with exit 5"
  else
    fail "Test 5: expected exit 5, got rc=$rc"
  fi
}

# ── Test 6: syntax ───────────────────────────────────────────────────────────

test_6_syntax() {
  log "Test 6: bash -n syntax check"
  bash -n "$ASK_SH" 2>/dev/null && bash -n "$ANSWER_SH" 2>/dev/null \
    && pass "Test 6: bash -n OK (ask + answer)" \
    || fail "Test 6: bash -n FAILED"
}

main() {
  log "=== question-store V2 round-trip unit tests ==="
  log "ask: $ASK_SH"
  log "answer: $ANSWER_SH"
  echo ""
  test_6_syntax
  test_1_ask_writes_pending
  test_2_answer_roundtrip
  test_3_double_answer_rejected
  test_4_invalid_option_rejected
  test_5_missing_qid_rejected
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
