#!/usr/bin/env bash
# Offline regression coverage for FIX-SESSION-RUNNER-TURNCAP-01.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RUNNER="$SCRIPTS_ROOT/leadv2-session-runner.sh"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/leadv2-turncap.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf '[TEST] PASS: %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '[TEST] FAIL: %s\n' "$1"; }

CLAUDE_STUB="$ROOT/claude"
cat > "$CLAUDE_STUB" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_TRACE"
printf '%s\n' '{"is_error":true,"num_turns":31,"stop_reason":"tool_use"}'
exit 1
STUB
chmod +x "$CLAUDE_STUB"

run_runner() {
  local project="$1" task_id="$2" trace="$3"
  STUB_TRACE="$trace" LEADV2_PROJECT_ROOT="$project" LEADV2_TASK_ID="$task_id" \
  LEADV2_FANOUT_CLAUDE_BIN="$CLAUDE_STUB" LEADV2_CLAUDE_MAX_TURNS=30 \
  LEADV2_RUNNER_MAX_ATTEMPTS=2 LEADV2_RUNNER_RETRY_SLEEP_S=0 \
  LEADV2_RUNNER_NOOP_MAX=99 LEADV2_RUNNER_STALL_MAX=99 "$RUNNER"
}

if bash -n "$RUNNER"; then pass "runner syntax"; else fail "runner syntax"; fi

task_id="TURNCAP-EXHAUSTION"
project="$ROOT/turncap-project"
mkdir -p "$project/docs/handoff/$task_id"
set +e
turncap_out="$(run_runner "$project" "$task_id" "$project/claude.args" 2>&1)"
turncap_rc=$?
set -e
calls="$(wc -l < "$project/claude.args")"
if [[ "$turncap_rc" -eq 3 && "$calls" -eq 2 \
  && "$turncap_out" == *"exhausted max_turns (31/30) — NOT a crash"* \
  && "$(sed -n '2p' "$project/claude.args")" == *"--resume"* \
  && "$(sed -n '2p' "$project/claude.args")" == *"--max-turns 30"* ]]; then
  pass "terminal num_turns at cap is resumed as turn-cap exhaustion with a fresh budget"
else
  fail "turn-cap rc=$turncap_rc calls=$calls out=$turncap_out"
fi

task_id="TURNCAP-E2E-COMPLETE"
project="$ROOT/e2e-project"
mkdir -p "$project/docs/handoff/$task_id"
: > "$project/docs/handoff/$task_id/e2e-gate-passed.flag"
set +e
e2e_out="$(run_runner "$project" "$task_id" "$project/claude.args" 2>&1)"
e2e_rc=$?
set -e
if [[ "$e2e_rc" -eq 0 && ! -e "$project/claude.args" \
  && "$e2e_out" == *"E2E gate completion flag already present"* ]]; then
  pass "E2E completion flag prevents a relaunch"
else
  fail "e2e rc=$e2e_rc out=$e2e_out"
fi

printf '[TEST] Results: PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
