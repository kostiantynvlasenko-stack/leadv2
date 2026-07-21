#!/usr/bin/env bash
# Offline integration test: autonomous spawn paths must delegate exact tasks
# to the common provider-neutral fanout and honor shared daily caps.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPAWNER="$TEST_DIR/../leadv2-session-spawner.sh"
ROOT="$(mktemp -d /tmp/leadv2-spawner-test-XXXXXX)"
trap 'rm -rf "$ROOT"' EXIT
PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf -- '[TEST] PASS: %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf -- '[TEST] FAIL: %s\n' "$1"; }

PROJECT="$ROOT/project"
STATE_ROOT="$ROOT/state"
TRACE="$ROOT/fanout.args"
mkdir -p "$PROJECT" "$STATE_ROOT"
git -C "$PROJECT" init -q
git -C "$PROJECT" config user.email test@example.com
git -C "$PROJECT" config user.name test
git -C "$PROJECT" commit -q --allow-empty -m init

FANOUT_STUB="$ROOT/fanout"
cat > "$FANOUT_STUB" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf -- '%s\n' "$*" >> "$STUB_TRACE"
task_id=""
dry=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tasks) task_id="$2"; shift 2 ;;
    --dry-run) dry=true; shift ;;
    *) shift ;;
  esac
done
if [[ "$dry" != "true" ]]; then
  mkdir -p "$LEADV2_STATE_ROOT/completions"
  printf -- '{"schema_version":1,"task_id":"%s","status":"phase8_passed","assertions":"7/7"}\n' "$task_id" \
    > "$LEADV2_STATE_ROOT/completions/$task_id.json"
fi
STUB
chmod +x "$FANOUT_STUB"

if bash -n "$SPAWNER"; then
  pass "spawner syntax"
else
  fail "spawner syntax"
fi

set +e
STUB_TRACE="$TRACE" \
LEADV2_FANOUT_BIN="$FANOUT_STUB" \
LEADV2_PROJECT_ROOT="$PROJECT" \
LEADV2_STATE_ROOT="$STATE_ROOT" \
LEADV2_SPAWN_PROVIDER=codex \
LEADV2_MAX_SELF_SPAWNS_PER_DAY=3 \
  "$SPAWNER" --wait SPAWN-EXACT-01 >"$ROOT/out" 2>"$ROOT/err"
rc=$?
set -e
args="$(<"$TRACE")"
if [[ "$rc" -eq 0 && "$args" == *"--tasks SPAWN-EXACT-01"* \
   && "$args" == *"--provider codex"* && "$args" == *"--headless"* ]]; then
  pass "exact task/provider delegated to common fanout; --wait trusts validated receipt"
else
  fail "delegation mismatch rc=$rc args=$args"
fi

spawn_count="$(find "$STATE_ROOT/spawned" -name '*.json' | wc -l | tr -d ' ')"
if [[ "$spawn_count" -eq 1 ]]; then
  pass "spawn audit receipt is stored in the shared control plane"
else
  fail "expected one shared spawn receipt, got $spawn_count"
fi

set +e
cap_out="$(STUB_TRACE="$TRACE" \
  LEADV2_FANOUT_BIN="$FANOUT_STUB" \
  LEADV2_PROJECT_ROOT="$PROJECT" \
  LEADV2_STATE_ROOT="$STATE_ROOT" \
  LEADV2_MAX_SELF_SPAWNS_PER_DAY=1 \
  "$SPAWNER" SPAWN-CAP-02 2>&1)"
cap_rc=$?
set -e
if [[ "$cap_rc" -ne 0 && "$cap_out" == *"daily spawn cap reached"* ]]; then
  pass "daily cap is shared and fails closed before another dispatch"
else
  fail "daily cap did not fail closed rc=$cap_rc out=$cap_out"
fi

printf -- '[TEST] Results: PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
