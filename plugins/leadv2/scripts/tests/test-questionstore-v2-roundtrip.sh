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
#   6. bash -n syntax check
#   7. QUESTION-BRIDGE-01: control-plane WRITE failure degrades to the legacy
#      handoff store instead of crashing; leadv2-reply.sh answers it and the
#      ask poll loop picks up the chosen option (exit 0).
#   8. QUESTION-BRIDGE-01: control-plane AND legacy writes both fail ->
#      LEADV2_ASK_DEGRADED_TO_DEFAULT marker on stderr, FIRST --option label
#      on stdout, exit 0 (never a crash).
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
REPLY_SH="${SCRIPT_DIR}/../leadv2-reply.sh"

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
    && bash -n "$REPLY_SH" 2>/dev/null \
    && pass "Test 6: bash -n OK (ask + answer + reply)" \
    || fail "Test 6: bash -n FAILED"
}

# ── Test 7: control-plane write failure -> legacy fallback (QUESTION-BRIDGE-01)

test_7_control_plane_failure_fallback() {
  log "Test 7: control-plane write failure degrades to legacy handoff store (no crash)"
  # Force the control-plane WRITE to fail: pre-create $STATE_ROOT/questions and
  # chmod it 000 so `mkdir -p` is an idempotent no-op but the python write
  # (open()/flock() on .write.lock) raises EACCES -> exit non-zero -> fallback.
  local bad_state="${TMP_DIR}/badstate7"
  mkdir -p "${bad_state}/questions"
  chmod 000 "${bad_state}/questions"
  local work_root="${TMP_DIR}/work7"
  mkdir -p "$work_root"

  local task_id="QB1-T7"
  local async_dir="${work_root}/docs/handoff/${task_id}/questions-async"

  # Blocking ask (tiny poll interval, short timeout). Backgrounded because it
  # BLOCKS on the legacy poll loop until we answer it from the side below.
  LEADV2_STATE_ROOT="$bad_state" LEADV2_PROJECT_ROOT="$work_root" PROJECT_ROOT="$work_root" \
    LEADV2_ASK_POLL_INTERVAL=1 \
    bash "$ASK_SH" "$task_id" "Pick one" --option "staging|Use staging" --option "production|Use production" \
    --phase build --timeout 15 \
    >"${TMP_DIR}/ask7.out" 2>"${TMP_DIR}/ask7.err" &
  local ask_pid=$!

  # Wait for the legacy fallback pending file to land (write succeeded = no crash).
  local i got_pending=""
  for i in $(seq 1 20); do
    [[ -d "$async_dir" ]] && got_pending="$(find "$async_dir" -maxdepth 1 -name '*-pending.yaml' 2>/dev/null | head -1)"
    [[ -n "$got_pending" ]] && break
    sleep 0.3
  done

  if [[ -z "$got_pending" ]]; then
    chmod 700 "${bad_state}/questions" 2>/dev/null || true
    kill "$ask_pid" 2>/dev/null || true; wait "$ask_pid" 2>/dev/null || true
    fail "Test 7: legacy fallback pending file not written under ${async_dir}"
    return
  fi

  local legacy_qid; legacy_qid="$(basename "$got_pending")"
  legacy_qid="${legacy_qid%-pending.yaml}"

  # Word labels are the real question contract; this protects the legacy
  # answer path from reintroducing single-letter-only validation.
  local reply_rc
  LEADV2_PROJECT_ROOT="$work_root" \
    bash "$REPLY_SH" --task-id "$task_id" "$legacy_qid" "production" >"${TMP_DIR}/reply7.out" 2>&1 && reply_rc=0 || reply_rc=$?

  # Wait for the ask poll loop to observe the answer and exit (bounded by the
  # 15s --timeout even if the pickup somehow fails).
  wait "$ask_pid" 2>/dev/null || true
  local chosen; chosen="$(cat "${TMP_DIR}/ask7.out" 2>/dev/null || true)"
  chmod 700 "${bad_state}/questions" 2>/dev/null || true

  if [[ "$reply_rc" -eq 0 && "$chosen" == "production" ]]; then
    pass "Test 7: word-label reply answered and ask poll returned chosen=production (no crash)"
  else
    fail "Test 7: reply_rc=$reply_rc chosen='$chosen' (expected production). err=$(head -c 200 "${TMP_DIR}/ask7.err" 2>/dev/null)"
  fi
}

# ── Test 8: double failure -> degrade-to-default (QUESTION-BRIDGE-01) ────────

test_8_double_failure_degrades_to_default() {
  log "Test 8: control-plane AND legacy writes both fail -> degrade-to-default (exit 0)"
  # Control-plane: questions dir chmod-000 -> write fails -> fallback.
  local bad_state="${TMP_DIR}/badstate8"
  mkdir -p "${bad_state}/questions"; chmod 000 "${bad_state}/questions"
  # Legacy: entire PROJECT_ROOT chmod-000 -> docs/handoff can't be created.
  local dead_root="${TMP_DIR}/deadroot8"
  mkdir -p "$dead_root"; chmod 000 "$dead_root"

  local out err rc
  LEADV2_STATE_ROOT="$bad_state" LEADV2_PROJECT_ROOT="$dead_root" PROJECT_ROOT="$dead_root" \
    bash "$ASK_SH" "QB1-T8" "Pick one" --option "a|Alpha" --option "b|Beta" \
    >"${TMP_DIR}/ask8.out" 2>"${TMP_DIR}/ask8.err" && rc=0 || rc=$?

  out="$(cat "${TMP_DIR}/ask8.out" 2>/dev/null || true)"
  err="$(cat "${TMP_DIR}/ask8.err" 2>/dev/null || true)"
  chmod 700 "${bad_state}/questions" "$dead_root" 2>/dev/null || true

  if [[ "$rc" -eq 0 && "$out" == "a" && "$err" == *"LEADV2_ASK_DEGRADED_TO_DEFAULT"* ]]; then
    pass "Test 8: double-failure -> exit 0, stdout=first option 'a', DEGRADED marker on stderr"
  else
    fail "Test 8: rc=$rc out='$out' err='$(printf '%s' "$err" | head -c 160)'"
  fi
}

main() {
  log "=== question-store V2 round-trip unit tests ==="
  log "ask: $ASK_SH"
  log "answer: $ANSWER_SH"
  log "reply: $REPLY_SH"
  echo ""
  test_6_syntax
  test_1_ask_writes_pending
  test_2_answer_roundtrip
  test_3_double_answer_rejected
  test_4_invalid_option_rejected
  test_5_missing_qid_rejected
  test_7_control_plane_failure_fallback
  test_8_double_failure_degrades_to_default
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
