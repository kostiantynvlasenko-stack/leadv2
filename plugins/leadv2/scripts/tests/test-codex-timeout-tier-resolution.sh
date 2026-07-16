#!/usr/bin/env bash
# tests/test-codex-timeout-tier-resolution.sh — SUPERVISE-V2-01 item 6d:
# CODEX_TIMEOUT tier-aware resolution in codex-task.sh (D-g). Verifies the
# resolved timeout SECONDS value passed to the timeout wrapper for each
# --tier, and that an explicit CODEX_TIMEOUT env always wins — WITHOUT ever
# calling Codex.
#
# Mechanism: codex-task.sh's G1 block runs
#   "$_TIMEOUT_CMD" "$_CODEX_TIMEOUT" node "$COMPANION" "$@"
# and prefers `gtimeout` on PATH. We prepend a fake `gtimeout` shim to PATH
# that only echoes the seconds value it was invoked with to stderr and exits
# 0 immediately — `node`/the real Codex CLI is never executed, no network
# call is made. This isolates the pure bash tier -> timeout resolution logic
# (lines around the "G1 -- hard timeout" comment) from the Codex dispatch
# itself.
#
# Tests:
#   1. --tier top      -> 1800s
#   2. --tier standard  -> 900s
#   3. no --tier (default) -> 600s
#   4. CODEX_TIMEOUT explicit env wins over --tier top
#   5. bash -n syntax check
#
# Portable: no GNU-only date/sed -i/timeout/flock. The fake `gtimeout` shim
# is itself a plain POSIX shell script.
# Run: bash scripts/tests/test-codex-timeout-tier-resolution.sh
# Exit 0 = all pass; non-zero = failures found.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODEX_TASK_SH="${SCRIPT_DIR}/../codex-task.sh"

PASS=0; FAIL=0; ERRORS=()
log()  { printf -- '[TEST] %s\n' "$*"; }
pass() { PASS=$((PASS + 1)); log "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); ERRORS+=("FAIL: $1"); log "FAIL: $1"; }

FAKE_BIN_DIR="$(mktemp -d /tmp/ctt-test-XXXXXX)"
cleanup() { rm -rf "$FAKE_BIN_DIR"; return 0; }
trap cleanup EXIT

# Fake `gtimeout` shim: intercepts `"$_TIMEOUT_CMD" "$_CODEX_TIMEOUT" node ...`
# — captures argv[1] (the resolved timeout seconds) to stderr, never runs the
# forwarded command (i.e. never touches `node`/Codex).
cat > "${FAKE_BIN_DIR}/gtimeout" <<'SHIM'
#!/usr/bin/env bash
printf -- 'MOCK_TIMEOUT_SECONDS=%s\n' "$1" >&2
exit 0
SHIM
chmod +x "${FAKE_BIN_DIR}/gtimeout"

_resolved_seconds() {
  # _resolved_seconds [--tier <tier>] [env VAR=val ...] -- runs codex-task.sh
  # task with the fake gtimeout ahead on PATH, returns the captured seconds.
  local extra_env=() tier_args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --tier) tier_args=(--tier "$2"); shift 2 ;;
      *) extra_env+=("$1"); shift ;;
    esac
  done
  # NOTE: codex-task.sh's _run_with_fallback captures the timeout-wrapped
  # command's stdout+stderr via an internal `$(... 2>&1)`, then reprints it
  # on codex-task.sh's own STDOUT (piped through _strip_meta). So our shim's
  # stderr line does NOT survive as raw stderr of the outer process — it
  # resurfaces on stdout. Capture combined output, don't split streams.
  local out
  out="$(PATH="${FAKE_BIN_DIR}:${PATH}" env "${extra_env[@]}" \
    bash "$CODEX_TASK_SH" task "portable test — no real Codex call" "${tier_args[@]}" 2>&1)" || true
  printf -- '%s\n' "$out" | grep -oE 'MOCK_TIMEOUT_SECONDS=[0-9]+' | tail -1 | cut -d= -f2
}

test_1_tier_top() {
  log "Test 1: --tier top -> 1800s"
  local secs
  secs="$(_resolved_seconds --tier top)"
  [[ "$secs" == "1800" ]] && pass "Test 1: 1800s" || fail "Test 1: got '$secs' (expected 1800)"
}

test_2_tier_standard() {
  log "Test 2: --tier standard -> 900s"
  local secs
  secs="$(_resolved_seconds --tier standard)"
  [[ "$secs" == "900" ]] && pass "Test 2: 900s" || fail "Test 2: got '$secs' (expected 900)"
}

test_3_no_tier_default() {
  log "Test 3: no --tier -> 600s (default)"
  local secs
  secs="$(_resolved_seconds)"
  [[ "$secs" == "600" ]] && pass "Test 3: 600s" || fail "Test 3: got '$secs' (expected 600)"
}

test_4_explicit_env_wins() {
  log "Test 4: explicit CODEX_TIMEOUT wins over --tier top"
  local secs
  secs="$(_resolved_seconds --tier top "CODEX_TIMEOUT=42")"
  [[ "$secs" == "42" ]] && pass "Test 4: 42s (explicit override honored)" || fail "Test 4: got '$secs' (expected 42)"
}

test_5_syntax() {
  log "Test 5: bash -n syntax check"
  bash -n "$CODEX_TASK_SH" 2>/dev/null && pass "Test 5: bash -n OK" || fail "Test 5: bash -n FAILED"
}

main() {
  log "=== codex-task.sh CODEX_TIMEOUT tier resolution unit tests ==="
  log "Script: $CODEX_TASK_SH"
  echo ""
  test_5_syntax
  test_1_tier_top
  test_2_tier_standard
  test_3_no_tier_default
  test_4_explicit_env_wins
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
