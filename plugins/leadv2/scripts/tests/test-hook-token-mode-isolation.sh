#!/usr/bin/env bash
# Offline regression for prompt-token discipline and supervisor/lead isolation.
# No provider, network, or model call is made.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
ANCHOR="$PLUGIN_ROOT/hooks/leadv2-task-anchor.sh"
CACHE_WARM="$PLUGIN_ROOT/scripts/leadv2-cache-warm.sh"
USER_CONTEXT="$PLUGIN_ROOT/hooks/leadv2-user-prompt-context.sh"
MODE_ISOLATION="$PLUGIN_ROOT/hooks/leadv2-mode-isolation.sh"
TOOL_COUNTER="$PLUGIN_ROOT/hooks/leadv2-tool-counter.sh"
HARDBANS_REINJECT="$PLUGIN_ROOT/hooks/leadv2-hardbans-reinject.sh"
PASS=0
FAIL=0
ROOT="$(mktemp -d /tmp/leadv2-hook-isolation-XXXXXX)"
BG_PID=""
SESSION_ID="hook-isolation-$$"
TASK_ID="HOOK-ISOLATION-01"
MARKER="/tmp/.leadv2-task-anchor-full-${SESSION_ID}-${TASK_ID}"
SUPERVISOR_MARKER="/tmp/.leadv2-supervisor-mode-${SESSION_ID}"
REINJECT_COUNTER="/tmp/leadv2-reinject-${SESSION_ID}.count"

cleanup() {
  [[ -n "$BG_PID" ]] && kill "$BG_PID" 2>/dev/null || true
  rm -f "$MARKER" "$SUPERVISOR_MARKER" "$REINJECT_COUNTER"
  rm -rf "$ROOT"
}
trap cleanup EXIT

pass() { PASS=$((PASS + 1)); printf -- '[TEST] PASS: %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf -- '[TEST] FAIL: %s\n' "$1"; }

REPO="$ROOT/repo"
STATE_ROOT="$ROOT/state"
TEST_HOME="$ROOT/home"
PYTHON_SITE="$(python3 -c 'import os, yaml; print(os.path.dirname(os.path.dirname(yaml.__file__)))')"
mkdir -p "$REPO/docs/leadv2" "$REPO/docs/handoff/$TASK_ID" "$STATE_ROOT" "$TEST_HOME"
git -C "$REPO" init -q
git -C "$REPO" config user.email test@example.com
git -C "$REPO" config user.name test
git -C "$REPO" commit -q --allow-empty -m init

payload() {
  python3 - "$REPO" "$SESSION_ID" <<'PYEOF'
import json, sys
print(json.dumps({"cwd": sys.argv[1], "session_id": sys.argv[2], "prompt": "ok"}))
PYEOF
}

run_anchor() {
  LEADV2_STATE_ROOT="$STATE_ROOT" bash "$ANCHOR" <<<"$(payload)"
}

if bash -n "$ANCHOR" && bash -n "$USER_CONTEXT" && bash -n "$CACHE_WARM" \
   && bash -n "$MODE_ISOLATION" && bash -n "$TOOL_COUNTER" \
   && bash -n "$HARDBANS_REINJECT"; then
  pass "hook/cache scripts parse"
else
  fail "hook/cache scripts parse"
fi

# A foreign child row points at the same main checkout. A supervisor sentinel
# owned by this process must win: never inherit the child's task anchor.
sleep 60 &
BG_PID=$!
cat > "$REPO/docs/leadv2/active.yaml" <<EOF
version: 2
sessions:
  - task_id: CHILD-FOREIGN-01
    worktree: $REPO
    phase: build
    class: Standard
    pid: $BG_PID
    stale: false
    started_at: '2026-07-21T00:00:00Z'
EOF
python3 - "$STATE_ROOT/.supervise-active" "$$" <<'PYEOF'
import json, sys
json.dump({"pid": int(sys.argv[2]), "started_at": "2026-07-21T00:00:00Z", "mode": "legacy-relay"}, open(sys.argv[1], "w"))
PYEOF
supervisor_out="$(run_anchor)"
if [[ "$supervisor_out" == *"<supervisor-anchor>"* \
   && "$supervisor_out" != *"ACTIVE TASK:"* \
   && "$supervisor_out" != *"CHILD-FOREIGN-01"* ]]; then
  pass "supervisor receives mode anchor, never a child task anchor"
else
  fail "supervisor/child prompt contexts leaked: $supervisor_out"
fi

compact_payload="$(python3 - "$REPO" "$SESSION_ID" <<'PYEOF'
import json, sys
print(json.dumps({
    "cwd": sys.argv[1],
    "session_id": sys.argv[2],
    "prompt": "<command-name>/compact</command-name>",
}))
PYEOF
)"
LEADV2_STATE_ROOT="$STATE_ROOT" bash "$ANCHOR" <<<"$compact_payload" >/dev/null
LEADV2_STATE_ROOT="$STATE_ROOT" bash "$USER_CONTEXT" <<<"$compact_payload" >/dev/null
if [[ ! -e "$REPO/docs/leadv2/tasks/CHILD-FOREIGN-01/pre-compact-resume.md" ]]; then
  pass "supervisor compact hook does not write resume state into a child task"
else
  fail "supervisor compact hook polluted child task state"
fi

# PostToolUse hooks run in the same supervisor process too. They must not
# count supervisor tools against sessions[0] or inject that child's hard bans.
HOME="$TEST_HOME" PYTHONPATH="$PYTHON_SITE${PYTHONPATH:+:$PYTHONPATH}" \
  bash "$TOOL_COUNTER" <<<"$(payload)" >/dev/null
reinject_out="$(HOME="$TEST_HOME" PYTHONPATH="$PYTHON_SITE${PYTHONPATH:+:$PYTHONPATH}" \
  LEADV2_REINJECT_EVERY=1 bash "$HARDBANS_REINJECT" <<<"$(payload)")"
if [[ ! -e "$TEST_HOME/.claude/state/leadv2/CHILD-FOREIGN-01.tool-count" \
   && ! -e "$REINJECT_COUNTER" && -z "$reinject_out" ]]; then
  pass "supervisor task hooks do not mutate or inject child state"
else
  fail "supervisor task hook leaked into child state"
fi

# An ordinary unrelated lead with no registered task must also ignore a live
# foreign PID even when the child temporarily reports the same worktree.
rm -f "$STATE_ROOT/.supervise-active"
rm -f "$SUPERVISOR_MARKER"
foreign_out="$(run_anchor)"
if [[ "$foreign_out" != *"ACTIVE TASK:"* && "$foreign_out" != *"CHILD-FOREIGN-01"* ]]; then
  pass "ordinary lead ignores a foreign live session in the same checkout"
else
  fail "ordinary lead inherited foreign task: $foreign_out"
fi

# Once the row belongs to this process ancestry, normal lead anchoring works.
cat > "$REPO/docs/leadv2/active.yaml" <<EOF
version: 2
sessions:
  - task_id: CHILD-FOREIGN-01
    worktree: $REPO
    phase: build
    class: Standard
    pid: $BG_PID
    stale: false
    started_at: '2026-07-21T00:00:00Z'
  - task_id: $TASK_ID
    worktree: $REPO
    phase: review
    class: Standard
    pid: $$
    stale: false
    started_at: '2026-07-21T00:00:01Z'
EOF
first_out="$(run_anchor)"
second_out="$(run_anchor)"
first_lines="$(printf -- '%s\n' "$first_out" | wc -l | tr -d ' ')"
second_lines="$(printf -- '%s\n' "$second_out" | wc -l | tr -d ' ')"
if [[ "$first_out" == *"ACTIVE TASK: $TASK_ID"* && "$second_out" == *"ACTIVE TASK: $TASK_ID"* \
   && "$first_lines" -le 40 && "$second_lines" -le 4 && "$second_lines" -lt "$first_lines" ]]; then
  pass "task anchor is full once, then compact (<=4 lines)"
else
  fail "task anchor token cap failed: first=${first_lines} second=${second_lines}"
fi


# The same hook remains active in a real lead session and resolves its task.
HOME="$TEST_HOME" PYTHONPATH="$PYTHON_SITE${PYTHONPATH:+:$PYTHONPATH}" \
  bash "$TOOL_COUNTER" <<<"$(payload)" >/dev/null
if [[ -s "$TEST_HOME/.claude/state/leadv2/${TASK_ID}.tool-count" \
   && ! -e "$TEST_HOME/.claude/state/leadv2/CHILD-FOREIGN-01.tool-count" ]]; then
  pass "parallel lead task hooks select their own PID row, not sessions[0]"
else
  fail "parallel lead task hook selected the wrong registry row"
fi

# The former cache warmer must remain a zero-network no-op even when a fake
# API key is present; only an explicit legacy experiment may issue a request.
warm_out="$(ANTHROPIC_API_KEY=definitely-not-real "$CACHE_WARM" --role critic --model opus)"
if [[ "$warm_out" == *"status: skipped_unsupported"* \
   && "$warm_out" == *"next_spawn_cache_hit_expected: false"* ]]; then
  pass "standalone cache warm is disabled by default (zero token spend)"
else
  fail "cache warm default is not the safe no-op: $warm_out"
fi

printf -- '[TEST] Results: PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
