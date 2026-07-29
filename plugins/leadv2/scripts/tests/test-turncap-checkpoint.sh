#!/usr/bin/env bash
# Offline regression coverage for LANE-TURNCAP-CHECKPOINT-01.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COMMIT_SCRIPT="$SCRIPTS_ROOT/leadv2-turncap-checkpoint-commit.sh"
RUNNER="$SCRIPTS_ROOT/leadv2-session-runner.sh"
HOOK="$SCRIPT_DIR/../../hooks/leadv2-turncap-checkpoint-hook.sh"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/leadv2-turncap-ckpt.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf '[TEST] PASS: %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '[TEST] FAIL: %s\n' "$1"; }

if bash -n "$COMMIT_SCRIPT"; then pass "commit-script syntax"; else fail "commit-script syntax"; fi
if bash -n "$HOOK"; then pass "hook syntax"; else fail "hook syntax"; fi
if grep -Fq 'TAIL_AT=$(( CAP - RESERVE ))' "$HOOK" \
  && grep -Fq 'EARLY_AT=$(( CAP - RESERVE * 2 ))' "$HOOK" \
  && ! grep -Eq '(^|[^0-9])55([^0-9]|$)' "$HOOK"; then
  pass "checkpoint warnings are derived from the effective cap, not a literal turn 55"
else
  fail "checkpoint warning thresholds must derive from CAP without a literal turn 55"
fi

mk_repo() {
  local repo="$1"
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.email "test@example.com"
  git -C "$repo" config user.name "Test"
  printf 'seed\n' > "$repo/seed.txt"
  git -C "$repo" add seed.txt
  git -C "$repo" commit -q -m seed
}

# --- Test 1: commits only manifest+dirty files, never a foreign dirty file ---
repo="$ROOT/repo1"
mk_repo "$repo"
mkdir -p "$repo/lane"
printf 'lane work\n' > "$repo/lane/a.py"          # this lane's edit (untracked)
printf 'other lane work\n' > "$repo/lane/foreign.py"  # another lane's uncommitted edit

state_dir="$ROOT/state1"
mkdir -p "$state_dir"
printf '%s\n' "$repo/lane/a.py" > "${state_dir}/T1.touched-files"

LEADV2_TURNCAP_STATE_DIR="$state_dir" "$COMMIT_SCRIPT" "T1" "$repo" 1 6 60 >"$ROOT/t1.log" 2>&1
rc=$?

committed="$(git -C "$repo" show --stat -1 --format='' 2>/dev/null || true)"
still_dirty="$(git -C "$repo" status --porcelain -- lane/foreign.py)"

if [[ "$rc" -eq 0 ]] && printf '%s' "$committed" | grep -q "lane/a.py" \
  && ! printf '%s' "$committed" | grep -q "foreign.py" \
  && [[ -n "$still_dirty" ]] \
  && printf '%s' "$committed" | grep -q "CHECKPOINT.md"; then
  pass "checkpoint commit stages only this lane's manifest+dirty files, writes fallback CHECKPOINT.md"
else
  fail "checkpoint commit scope: rc=$rc committed=[$committed] still_dirty=[$still_dirty] log=$(cat "$ROOT/t1.log")"
fi

# --- Test 2: nothing dirty -> no-op, no commit ---
repo2="$ROOT/repo2"
mk_repo "$repo2"
head_before="$(git -C "$repo2" rev-parse HEAD)"
state_dir2="$ROOT/state2"
mkdir -p "$state_dir2"
printf '%s\n' "$repo2/does-not-exist.py" > "${state_dir2}/T2.touched-files"

LEADV2_TURNCAP_STATE_DIR="$state_dir2" "$COMMIT_SCRIPT" "T2" "$repo2" 1 6 60 >/dev/null 2>&1
rc2=$?
head_after="$(git -C "$repo2" rev-parse HEAD)"

if [[ "$rc2" -eq 0 && "$head_before" == "$head_after" ]]; then
  pass "no dirty manifest files -> no-op, no commit"
else
  fail "expected no-op, got rc=$rc2 head_before=$head_before head_after=$head_after"
fi

# --- Test 3: self-authored CHECKPOINT.md is not overwritten by the fallback ---
repo3="$ROOT/repo3"
mk_repo "$repo3"
mkdir -p "$repo3/docs/handoff/T3"
printf '# Self-authored\nEstablished: X. Remaining: Y. Anchor: foo.py:12\n' \
  > "$repo3/docs/handoff/T3/CHECKPOINT.md"
printf 'edit\n' > "$repo3/work.py"

state_dir3="$ROOT/state3"
mkdir -p "$state_dir3"
{
  printf '%s\n' "$repo3/work.py"
  printf '%s\n' "$repo3/docs/handoff/T3/CHECKPOINT.md"
} > "${state_dir3}/T3.touched-files"

LEADV2_TURNCAP_STATE_DIR="$state_dir3" "$COMMIT_SCRIPT" "T3" "$repo3" 2 6 60 >/dev/null 2>&1
note_content="$(cat "$repo3/docs/handoff/T3/CHECKPOINT.md")"

if printf '%s' "$note_content" | grep -q "Self-authored" \
  && ! printf '%s' "$note_content" | grep -q "automatic fallback"; then
  pass "self-authored CHECKPOINT.md is preserved, not overwritten by the fallback"
else
  fail "self-authored note was overwritten: $note_content"
fi

# --- Test 4: session-runner wiring — turn-cap death triggers the backstop ---
CLAUDE_STUB="$ROOT/claude-turncap"
cat > "$CLAUDE_STUB" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_TRACE"
printf '%s\n' '{"is_error":true,"num_turns":31,"stop_reason":"tool_use"}'
exit 1
STUB
chmod +x "$CLAUDE_STUB"

repo4="$ROOT/repo4"
mk_repo "$repo4"
task_id="TURNCAP-CKPT-WIRING"
mkdir -p "$repo4/docs/handoff/$task_id"
mkdir -p "$repo4/lane4"
printf 'in flight\n' > "$repo4/lane4/inflight.py"
state_dir4="$ROOT/state4"
mkdir -p "$state_dir4"
printf '%s\n' "$repo4/lane4/inflight.py" > "${state_dir4}/${task_id}.touched-files"

STUB_TRACE="$repo4/claude.args" LEADV2_PROJECT_ROOT="$repo4" LEADV2_TASK_ID="$task_id" \
LEADV2_FANOUT_CLAUDE_BIN="$CLAUDE_STUB" LEADV2_CLAUDE_MAX_TURNS=30 \
LEADV2_RUNNER_MAX_ATTEMPTS=2 LEADV2_RUNNER_RETRY_SLEEP_S=0 \
LEADV2_RUNNER_NOOP_MAX=99 LEADV2_RUNNER_STALL_MAX=99 \
LEADV2_TURNCAP_STATE_DIR="$state_dir4" \
"$RUNNER" >"$ROOT/t4.log" 2>&1 || true

committed4="$(git -C "$repo4" show --stat -1 --format='' 2>/dev/null || true)"
resume_prompt="$(sed -n '2p' "$repo4/claude.args" 2>/dev/null || true)"

if printf '%s' "$committed4" | grep -q "lane4/inflight.py" \
  && printf '%s' "$committed4" | grep -q "CHECKPOINT.md" \
  && printf '%s' "$resume_prompt" | grep -q "CHECKPOINT.md FIRST"; then
  pass "session-runner invokes the checkpoint backstop on turn-cap death and the resume prompt points at CHECKPOINT.md"
else
  fail "wiring: committed4=[$committed4] resume_prompt=[$resume_prompt]"
fi

# --- Test 5: a lane that finishes normally is unaffected (no touched-files, no commit attempt) ---
CLAUDE_STUB_OK="$ROOT/claude-ok"
cat > "$CLAUDE_STUB_OK" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_TRACE"
printf '%s\n' '{"type":"result","subtype":"success","num_turns":5}'
mkdir -p "$(dirname "$SENTINEL_PATH")"
: > "$SENTINEL_PATH"
exit 0
STUB
chmod +x "$CLAUDE_STUB_OK"

repo5="$ROOT/repo5"
mk_repo "$repo5"
task_id5="TURNCAP-NORMAL-FINISH"
mkdir -p "$repo5/docs/handoff/$task_id5"
head_before5="$(git -C "$repo5" rev-parse HEAD)"

SENTINEL_PATH="$repo5/docs/handoff/$task_id5/phase8-passed.flag" \
STUB_TRACE="$repo5/claude.args" LEADV2_PROJECT_ROOT="$repo5" LEADV2_TASK_ID="$task_id5" \
LEADV2_FANOUT_CLAUDE_BIN="$CLAUDE_STUB_OK" LEADV2_CLAUDE_MAX_TURNS=30 \
LEADV2_RUNNER_MAX_ATTEMPTS=2 LEADV2_RUNNER_RETRY_SLEEP_S=0 \
LEADV2_TURNCAP_STATE_DIR="$ROOT/state5" \
"$RUNNER" >"$ROOT/t5.log" 2>&1
rc5=$?
head_after5="$(git -C "$repo5" rev-parse HEAD)"

if [[ "$rc5" -eq 0 && "$head_before5" == "$head_after5" ]]; then
  pass "a lane that finishes normally (no turn-cap death) triggers no checkpoint commit"
else
  fail "normal finish should be untouched: rc=$rc5 head_before=$head_before5 head_after=$head_after5"
fi

printf '[TEST] Results: PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
