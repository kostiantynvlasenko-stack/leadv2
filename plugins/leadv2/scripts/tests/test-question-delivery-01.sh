#!/usr/bin/env bash
# QUESTION-DELIVERY-01: dispatch questions must wake the supervising stream.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/leadv2-temp.sh"

TMP="$(lv2_mktemp_dir question-delivery)"
STATE="$TMP/state"
PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ASK="$PLUGIN_ROOT/scripts/leadv2-ask.sh"
DISPATCH="$PLUGIN_ROOT/scripts/leadv2-dispatch-code.sh"
LOOP="$PLUGIN_ROOT/scripts/leadv2-supervise-loop.sh"
SUPERVISE="$PLUGIN_ROOT/scripts/leadv2-supervise.sh"
STATE_PATH="$PLUGIN_ROOT/scripts/leadv2-state-path.sh"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

fail() { printf -- '[TEST] FAIL: %s\n' "$*"; exit 1; }
pass() { printf -- '[TEST] PASS: %s\n' "$*"; }

mkdir -p "$TMP/.claude/ref" "$TMP/docs/leadv2" "$TMP/bin"
# An empty policy block deterministically retains glm as the default arm.
printf 'glm_policy:\n' > "$TMP/.claude/ref/leadv2-routing.yaml"
ACTIVE="$(LEADV2_PROJECT_ROOT="$TMP" LEADV2_STATE_ROOT="$STATE" PROJECT_ROOT="$TMP" bash "$STATE_PATH" active.yaml)"
mkdir -p "$(dirname "$ACTIVE")"
printf 'sessions: []\n' > "$ACTIVE"

# This fake is a real dispatch-launch seam: `bg` raises a cross-worktree
# question and `status` supplies the router's required liveness proof.
FAKE="$TMP/bin/glm-coder.sh"
cat > "$FAKE" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  bg)
    bash "$ASK_SH_TEST" "QDEL-DISPATCH" "Choose deployment lane" \
      --option "staging|Use staging" --option "production|Use production" --no-block >/dev/null
    printf 'dispatch-question-run\n'
    ;;
  status) exit 0 ;;
  *) exit 1 ;;
esac
FAKE
chmod +x "$FAKE"

LOG="$(LEADV2_PROJECT_ROOT="$TMP" LEADV2_STATE_ROOT="$STATE" PROJECT_ROOT="$TMP" bash "$STATE_PATH" supervise-loop.log)"
# Start the loop first: the lane asks while the supervising lead is already
# mid-turn/listening, so delivery must be queued rather than lost.
env LEADV2_PROJECT_ROOT="$TMP" CLAUDE_PROJECT_DIR="$TMP" LEADV2_STATE_ROOT="$STATE" \
  LEADV2_SUPERVISE_EVENT_POLL_S=1 LEADV2_SUPERVISE_LOOP_MAX_CYCLES=4 \
  bash "$LOOP" >/dev/null 2>&1 &
LOOP_PID=$!
sleep 0.2

env CLAUDE_PROJECT_ROOT="$TMP" LEADV2_STATE_ROOT="$STATE" ASK_SH_TEST="$ASK" \
  LEADV2_DISPATCH_GLM_BIN="$FAKE" LEADV2_DISPATCH_CACHE_DIR="$TMP/cache" \
  LEADV2_JOURNAL_BIN=/bin/true \
  bash "$DISPATCH" "question-delivery mission" >/dev/null 2>&1 \
  || fail "dispatch launcher failed"
wait "$LOOP_PID" || fail "supervisor loop failed"

grep -q 'SUPERVISE-URGENT] QUESTION QDEL-DISPATCH .*options=staging,production' "$LOG" \
  || fail "dispatch question did not reach supervising stream: $(cat "$LOG" 2>/dev/null)"
pass "dispatch-launched question reached the supervising stream while it was running"

# Once delivered, an unanswered old question is re-emitted exactly once as an
# escalation on the same supervisor surface (no parallel queue/poller).
QFILE="$(find "$STATE/questions" -name 'q-*.yaml' -print -quit)"
python3 - "$QFILE" <<'PY'
import sys, yaml
p = sys.argv[1]
with open(p, encoding='utf-8') as f: d = yaml.safe_load(f) or {}
d['asked_at'] = '2000-01-01T00:00:00Z'
with open(p, 'w', encoding='utf-8') as f: yaml.safe_dump(d, f, sort_keys=False)
PY
OUT="$(env LEADV2_PROJECT_ROOT="$TMP" CLAUDE_PROJECT_DIR="$TMP" LEADV2_STATE_ROOT="$STATE" \
  LEADV2_QUESTION_ESCALATE_S=1 bash "$SUPERVISE" --json --since delivery)"
printf '%s' "$OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["requires_founder"][0]["escalated"] is True' \
  || fail "old unanswered question did not escalate on supervisor surface: $OUT"
pass "old unanswered question escalates visibly without being dropped"
