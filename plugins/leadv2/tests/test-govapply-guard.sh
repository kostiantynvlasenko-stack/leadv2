#!/usr/bin/env bash
# tests/test-govapply-guard.sh — smoke tests for leadv2-govapply-guard.sh
# Usage: bash tests/test-govapply-guard.sh
# Exit 0 = all pass; non-zero = failure count
set -euo pipefail

GUARD="${BASH_SOURCE[0]%/*}/../scripts/leadv2-govapply-guard.sh"
PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$(( PASS + 1 )); }
fail() { echo "FAIL: $1"; FAIL=$(( FAIL + 1 )); }

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

sha256_of() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

# ---------------------------------------------------------------------------
# (a) Matching hash: applies (exit 0) and writes a timestamped .bak
# ---------------------------------------------------------------------------
TARGET_A="${TMP_DIR}/target-a.md"
echo "original content" > "$TARGET_A"
SHA_A="$(sha256_of "$TARGET_A")"

exit_code=0
bash "$GUARD" --target "$TARGET_A" --expected-sha256 "$SHA_A" >/dev/null 2>&1 || exit_code=$?
BAK_COUNT=$(find "$TMP_DIR" -maxdepth 1 -name "target-a.md.bak.*" | wc -l | tr -d ' ')

if [[ $exit_code -eq 0 && "$BAK_COUNT" -ge 1 ]]; then
  pass "(a) matching-hash: applies (exit 0) and creates a .bak backup"
else
  fail "(a) matching-hash: expected exit=0 + .bak (got exit=$exit_code bak_count=$BAK_COUNT)"
fi

# ---------------------------------------------------------------------------
# (b) Drifted hash: refuses (non-zero) and does NOT write a .bak
# ---------------------------------------------------------------------------
TARGET_B="${TMP_DIR}/target-b.md"
echo "original content" > "$TARGET_B"
SHA_B_STALE="$(sha256_of "$TARGET_B")"
echo "modified after proposal generation" >> "$TARGET_B"

exit_code=0
bash "$GUARD" --target "$TARGET_B" --expected-sha256 "$SHA_B_STALE" >/dev/null 2>&1 || exit_code=$?
BAK_COUNT_B=$(find "$TMP_DIR" -maxdepth 1 -name "target-b.md.bak.*" | wc -l | tr -d ' ')

if [[ $exit_code -ne 0 && "$BAK_COUNT_B" -eq 0 ]]; then
  pass "(b) drifted-hash: refuses (non-zero exit) and writes no backup"
else
  fail "(b) drifted-hash: expected non-zero exit + no backup (got exit=$exit_code bak_count=$BAK_COUNT_B)"
fi

# ---------------------------------------------------------------------------
# (c) No --expected-sha256: skips drift-check, still backs up (backup-only mode)
# ---------------------------------------------------------------------------
TARGET_C="${TMP_DIR}/target-c.md"
echo "no baseline recorded" > "$TARGET_C"

exit_code=0
bash "$GUARD" --target "$TARGET_C" >/dev/null 2>&1 || exit_code=$?
BAK_COUNT_C=$(find "$TMP_DIR" -maxdepth 1 -name "target-c.md.bak.*" | wc -l | tr -d ' ')

if [[ $exit_code -eq 0 && "$BAK_COUNT_C" -ge 1 ]]; then
  pass "(c) no --expected-sha256: backup-only mode applies (exit 0) and backs up"
else
  fail "(c) no --expected-sha256: expected exit=0 + backup (got exit=$exit_code bak_count=$BAK_COUNT_C)"
fi

# ---------------------------------------------------------------------------
# (d) Kill-switch LEADV2_GOVAPPLY_NOGUARD=1 bypasses drift-check AND backup
# ---------------------------------------------------------------------------
TARGET_D="${TMP_DIR}/target-d.md"
echo "original" > "$TARGET_D"
SHA_D_STALE="$(sha256_of "$TARGET_D")"
echo "drifted" >> "$TARGET_D"

exit_code=0
LEADV2_GOVAPPLY_NOGUARD=1 bash "$GUARD" --target "$TARGET_D" --expected-sha256 "$SHA_D_STALE" >/dev/null 2>&1 || exit_code=$?
BAK_COUNT_D=$(find "$TMP_DIR" -maxdepth 1 -name "target-d.md.bak.*" | wc -l | tr -d ' ')

if [[ $exit_code -eq 0 && "$BAK_COUNT_D" -eq 0 ]]; then
  pass "(d) LEADV2_GOVAPPLY_NOGUARD=1: bypasses drift-check (exit 0), no backup written"
else
  fail "(d) NOGUARD bypass: expected exit=0 + no backup (got exit=$exit_code bak_count=$BAK_COUNT_D)"
fi

# ---------------------------------------------------------------------------
# (e) Missing target file: exit 2
# ---------------------------------------------------------------------------
exit_code=0
bash "$GUARD" --target "${TMP_DIR}/does-not-exist.md" >/dev/null 2>&1 || exit_code=$?
if [[ $exit_code -eq 2 ]]; then
  pass "(e) missing target file: exit 2"
else
  fail "(e) missing target file: expected exit=2 (got exit=$exit_code)"
fi

# ---------------------------------------------------------------------------
# (f) Missing --target arg: usage error (exit 1)
# ---------------------------------------------------------------------------
exit_code=0
bash "$GUARD" >/dev/null 2>&1 || exit_code=$?
if [[ $exit_code -eq 1 ]]; then
  pass "(f) missing --target: usage error (exit 1)"
else
  fail "(f) missing --target: expected exit=1 (got exit=$exit_code)"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[[ $FAIL -eq 0 ]]
