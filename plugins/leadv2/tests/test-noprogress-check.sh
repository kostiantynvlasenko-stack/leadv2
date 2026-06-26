#!/usr/bin/env bash
# tests/test-noprogress-check.sh — smoke tests for leadv2-noprogress-check.sh
# Usage: bash tests/test-noprogress-check.sh
# Exit 0 = all pass; non-zero = failure count
set -euo pipefail

SCRIPT="${BASH_SOURCE[0]%/*}/../scripts/leadv2-noprogress-check.sh"
PASS=0
FAIL=0
TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

pass() { printf -- 'PASS: %s\n' "$1"; PASS=$(( PASS + 1 )); }
fail() { printf -- 'FAIL: %s\n' "$1"; FAIL=$(( FAIL + 1 )); }

run() {
  local expected_exit="$1" jsonl="$2" sig="$3"
  local max="${4:-2}"
  local actual_exit=0
  bash "$SCRIPT" "$jsonl" "$sig" "$max" >/dev/null 2>&1 || actual_exit=$?
  [[ "$actual_exit" -eq "$expected_exit" ]]
}

run_stdout() {
  local jsonl="$1" sig="$2"
  local max="${3:-2}"
  bash "$SCRIPT" "$jsonl" "$sig" "$max" 2>/dev/null || true
}

# (a) First call — single entry, not yet stalled -> PROGRESS (exit 0)
JSONL_A="$TMPDIR_BASE/a/sigs.jsonl"
if run 0 "$JSONL_A" "codex:high|security:critical"; then
  pass "(a) first call -> PROGRESS exit 0"
else
  fail "(a) first call -> expected PROGRESS exit 0"
fi

# (b) Second call same sig — reaches threshold -> STALLED (exit 1)
if run 1 "$JSONL_A" "codex:high|security:critical"; then
  pass "(b) second same sig -> STALLED exit 1"
else
  fail "(b) second same sig -> expected STALLED exit 1"
fi

# (c) Different sig after stall resets streak -> PROGRESS (exit 0)
JSONL_C="$TMPDIR_BASE/c/sigs.jsonl"
bash "$SCRIPT" "$JSONL_C" "codex:high" >/dev/null 2>&1 || true
bash "$SCRIPT" "$JSONL_C" "codex:high" >/dev/null 2>&1 || true
if run 0 "$JSONL_C" "security:critical"; then
  pass "(c) different sig resets streak -> PROGRESS exit 0"
else
  fail "(c) different sig resets streak -> expected PROGRESS exit 0"
fi

# (d) max_stalled=3 stalls at third consecutive
JSONL_D="$TMPDIR_BASE/d/sigs.jsonl"
run 0 "$JSONL_D" "codex:high" 3 || true
run 0 "$JSONL_D" "codex:high" 3 || true
if run 1 "$JSONL_D" "codex:high" 3; then
  pass "(d) max_stalled=3 stalls at third consecutive -> STALLED exit 1"
else
  fail "(d) max_stalled=3 -> expected STALLED exit 1 at third"
fi

# (e) stdout text
JSONL_E="$TMPDIR_BASE/e/sigs.jsonl"
out1=$(run_stdout "$JSONL_E" "sig-x")
out2=$(run_stdout "$JSONL_E" "sig-x")
if [[ "$out1" == "PROGRESS" && "$out2" == "STALLED" ]]; then
  pass "(e) stdout PROGRESS then STALLED"
else
  fail "(e) stdout mismatch: got '$out1' '$out2'"
fi

# (f) creates parent dirs automatically
JSONL_F="$TMPDIR_BASE/nested/deep/dir/sigs.jsonl"
if run 0 "$JSONL_F" "some-sig"; then
  pass "(f) creates parent dirs automatically"
else
  fail "(f) parent dir creation failed"
fi

# (g) sig with pipe and quotes — C1 fix: codex:high|file:"foo" twice -> STALLED
JSONL_G="$TMPDIR_BASE/g/sigs.jsonl"
run 0 "$JSONL_G" 'codex:high|file:"foo"' || true
if run 1 "$JSONL_G" 'codex:high|file:"foo"'; then
  pass '(g) sig with pipe+quotes twice -> STALLED exit 1'
else
  fail '(g) sig with pipe+quotes -> expected STALLED exit 1'
fi

# (h) sig with backslash — C1 fix: sec\critical twice -> STALLED
JSONL_H="$TMPDIR_BASE/h/sigs.jsonl"
run 0 "$JSONL_H" 'sec\critical' || true
if run 1 "$JSONL_H" 'sec\critical'; then
  pass '(h) sig with backslash twice -> STALLED exit 1'
else
  fail '(h) sig with backslash -> expected STALLED exit 1'
fi

# (i) sig with slash and colon — C1 fix: a/b:high twice -> STALLED
JSONL_I="$TMPDIR_BASE/i/sigs.jsonl"
run 0 "$JSONL_I" 'a/b:high' || true
if run 1 "$JSONL_I" 'a/b:high'; then
  pass '(i) sig with slash+colon twice -> STALLED exit 1'
else
  fail '(i) sig with slash+colon -> expected STALLED exit 1'
fi

printf -- '\n%d passed, %d failed\n' "$PASS" "$FAIL"
exit "$FAIL"
