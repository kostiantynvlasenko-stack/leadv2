#!/usr/bin/env bash
# tests/test-loop-detect-hook.sh — regression test for leadv2-loop-detect-hook.sh
# (fix-round-2, task 6d0c93f4a7b2, items 2 and 6).
#
# (a) F4 regression: pipes synthetic PreToolUse+PostToolUse payloads through the
#     wrapper N times and asserts /tmp/leadv2-loop-detect-<key>.json is created
#     and tool_counts increments. The original defect (D6/F4) was `python3 -c
#     "..." -- a b c` shifting sys.argv, silently resolving detect_script to the
#     wrong string, so the detector never ran and no state file was ever
#     written -- this test FAILS LOUDLY against that wrapper (no state file
#     appears) and must keep failing if `--` is ever reintroduced.
# (b) item 6 (BLOCKING): a call denied at the tool-cap limit must NOT increment
#     the persisted counter -- only a call that actually executes (PostToolUse)
#     may increment it.
# (c) item 6 (BLOCKING): a child agent (distinct agent_id, same session_id) gets
#     its own counter namespace and is not blocked by the parent's count.
#
# Usage: bash tests/test-loop-detect-hook.sh
# Exit 0 = all pass; non-zero = failure count.
set -euo pipefail

HOOK="${BASH_SOURCE[0]%/*}/../hooks/leadv2-loop-detect-hook.sh"
PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$(( PASS + 1 )); }
fail() { echo "FAIL: $1"; FAIL=$(( FAIL + 1 )); }

SID="test-loopdetect-$$"
STATE_FILE="/tmp/leadv2-loop-detect-${SID}.json"
CHILD_STATE_FILE="/tmp/leadv2-loop-detect-${SID}-child-1.json"

cleanup() {
  rm -f "$STATE_FILE" "$CHILD_STATE_FILE" "${STATE_FILE}".tmp* "${CHILD_STATE_FILE}".tmp* 2>/dev/null || true
}
trap cleanup EXIT
cleanup

export LEADV2_LOOP_DETECT=1
export LEADV2_LOOP_WARN_AT=1000
export LEADV2_LOOP_HARD_AT=1000
export LEADV2_TOOL_FREQ_WARN=1000
export LEADV2_TOOL_HARD_LIMIT=5
export LEADV2_TASK_ID="test-task-loopdetect"

# Build a payload with a distinct bash command per call (so the identical-call
# hash never repeats within one test -- only tool_count frequency is exercised).
build_payload() {
  local event="$1" session="$2" agent="$3" nonce="$4"
  python3 -c "
import json, sys
print(json.dumps({
    'hook_event_name': sys.argv[1],
    'tool_name': 'Bash',
    'session_id': sys.argv[2],
    'agent_id': sys.argv[3],
    'tool_input': {'command': 'echo test-loopdetect-' + sys.argv[4]},
}))
" "$event" "$session" "$agent" "$nonce"
}

fire() {
  # fire <event> <session> <agent> <nonce> -> prints "rc=<n> stdout=<...>" and stderr passthrough
  local event="$1" session="$2" agent="$3" nonce="$4"
  local out rc=0
  out="$(build_payload "$event" "$session" "$agent" "$nonce" | bash "$HOOK" 2>/tmp/test-loopdetect-stderr.$$)" || rc=$?
  echo "$rc"
}

fire_pair() {
  # A normal, non-denied call: Pre then Post, mirroring real harness sequencing.
  local session="$1" agent="$2" nonce="$3"
  fire "PreToolUse" "$session" "$agent" "$nonce" >/dev/null
  fire "PostToolUse" "$session" "$agent" "$nonce" >/dev/null
}

get_count() {
  # get_count <state_file> <tool_name>
  python3 -c "
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    print(d.get('tool_counts', {}).get(sys.argv[2], 0))
except Exception:
    print(-1)
" "$1" "$2"
}

# ---------------------------------------------------------------------------
# (a) F4 regression: state file created + tool_counts increments through the
#     wrapper (not the detector called directly).
# ---------------------------------------------------------------------------
for i in 1 2 3; do
  fire_pair "$SID" "" "a$i"
done

if [[ -f "$STATE_FILE" ]]; then
  cnt="$(get_count "$STATE_FILE" "Bash")"
  if [[ "$cnt" == "3" ]]; then
    pass "(a) wrapper writes state file and tool_counts increments to 3 after 3 Pre+Post pairs"
  else
    fail "(a) expected tool_counts.Bash=3, got '$cnt' (state file: $(cat "$STATE_FILE" 2>/dev/null || echo MISSING))"
  fi
else
  fail "(a) $STATE_FILE was never created -- wrapper is inert (this is the exact D6/F4 regression: a re-added '--' before positional python argv silently breaks this)"
fi

# ---------------------------------------------------------------------------
# (b) A denied call must not increment the counter. Drive tool_count to
#     LEADV2_TOOL_HARD_LIMIT-1 (already at 3 from (a); one more pair -> 4),
#     then fire ONE MORE PreToolUse only (no matching Post, since a denied
#     call never executes in the real harness) and confirm it is BLOCKed
#     AND that the persisted count stays at 4, not 5.
# ---------------------------------------------------------------------------
fire_pair "$SID" "" "b1"
before="$(get_count "$STATE_FILE" "Bash")"

rc="$(fire "PreToolUse" "$SID" "" "b2")"
after="$(get_count "$STATE_FILE" "Bash")"

if [[ "$rc" == "2" ]] && [[ "$before" == "4" ]] && [[ "$after" == "4" ]]; then
  pass "(b) denied PreToolUse call (rc=2) at the cap does not increment tool_counts (stayed at $after)"
else
  fail "(b) expected rc=2 before=4 after=4, got rc=$rc before=$before after=$after"
fi

# ---------------------------------------------------------------------------
# (c) A child agent (same session_id, distinct agent_id) gets its own counter
#     namespace and is NOT blocked by the parent lane's count sitting at the cap.
# ---------------------------------------------------------------------------
rc_child="$(fire "PreToolUse" "$SID" "child-1" "c1")"
fire "PostToolUse" "$SID" "child-1" "c1" >/dev/null
child_cnt="$(get_count "$CHILD_STATE_FILE" "Bash")"
parent_cnt_after="$(get_count "$STATE_FILE" "Bash")"

if [[ "$rc_child" == "0" ]] && [[ -f "$CHILD_STATE_FILE" ]] && [[ "$child_cnt" == "1" ]] && [[ "$parent_cnt_after" == "4" ]]; then
  pass "(c) child agent (agent_id=child-1) has an independent counter (1) and is not blocked by parent's cap; parent unaffected (4)"
else
  fail "(c) expected rc_child=0 child_cnt=1 parent_cnt=4, got rc_child=$rc_child child_cnt=$child_cnt parent_cnt=$parent_cnt_after (child state file exists: $(test -f "$CHILD_STATE_FILE" && echo yes || echo no))"
fi

echo ""
echo "=== $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]]
