#!/usr/bin/env bash
# tests/test-supervise-failclosed.sh — SUPERVISE-V2-01 item 6a: B1 fail-closed
# root resolution + registry honesty for leadv2-supervise.sh.
#
# Tests:
#   1. wrong cwd (no LEADV2_PROJECT_ROOT/CLAUDE_PROJECT_DIR, cwd not a git repo)
#      -> non-zero exit, typed root_error JSON
#   2. missing active.yaml (root resolves fine) -> non-zero exit, registry_error
#   3. malformed active.yaml (invalid YAML) -> non-zero exit, registry_error
#   4. honest-empty: cleanly-parsed empty registry -> exit 0, table: []
#   5. unwritable snapshot dir -> non-zero exit, state_write_error
#   6. bash -n syntax check
#
# Portable: no GNU-only date/sed -i/timeout/flock. Only fcntl/python3 + POSIX
# chmod. Run: bash scripts/tests/test-supervise-failclosed.sh
# Exit 0 = all pass; non-zero = failures found.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/leadv2-temp.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUPERVISE_SH="${SCRIPT_DIR}/../leadv2-supervise.sh"

PASS=0; FAIL=0; ERRORS=()
log()  { printf -- '[TEST] %s\n' "$*"; }
pass() { PASS=$((PASS + 1)); log "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); ERRORS+=("FAIL: $1"); log "FAIL: $1"; }

CLEANUP_DIRS=()
cleanup() {
  for d in "${CLEANUP_DIRS[@]:-}"; do
    [[ -n "$d" && -d "$d" ]] && chmod -R u+rwx "$d" 2>/dev/null || true
  done
  for d in "${CLEANUP_DIRS[@]:-}"; do
    [[ -n "$d" ]] && rm -rf "$d"
  done
  return 0
}
trap cleanup EXIT

_tmp_dir() {
  local d
  d="$(lv2_mktemp_dir "svfc-test")"
  CLEANUP_DIRS+=("$d")
  printf -- '%s' "$d"
}

json_error_kind() {
  # Extracts the "error" field from a JSON blob without a jq dependency.
  python3 -c '
import json, sys
try:
    d = json.loads(sys.stdin.read())
    print(d.get("error", ""))
except Exception:
    print("")
'
}

# ── Test 1: wrong cwd -> root_error ─────────────────────────────────────────

test_1_wrong_cwd_root_error() {
  log "Test 1: no LEADV2_PROJECT_ROOT/CLAUDE_PROJECT_DIR, cwd not a git repo -> root_error"

  local nongit_dir out rc kind
  nongit_dir="$(_tmp_dir)"

  out="$(cd "$nongit_dir" && env -u LEADV2_PROJECT_ROOT -u CLAUDE_PROJECT_DIR \
    bash "$SUPERVISE_SH" --json 2>/dev/null)" && rc=0 || rc=$?

  if [[ "$rc" -eq 0 ]]; then
    fail "Test 1: expected non-zero exit, got 0 (out=$out)"
    return
  fi
  kind="$(printf -- '%s' "$out" | json_error_kind)"
  if [[ "$kind" == "root_error" ]]; then
    pass "Test 1: rc=$rc kind=root_error"
  else
    fail "Test 1: rc=$rc kind='$kind' (expected root_error) out=$out"
  fi
}

# ── Test 2: missing registry -> registry_error ──────────────────────────────

test_2_missing_registry() {
  log "Test 2: root resolves, active.yaml never created -> registry_error"

  local proj state out rc kind
  proj="$(_tmp_dir)"
  state="$(_tmp_dir)"

  out="$(LEADV2_PROJECT_ROOT="$proj" LEADV2_STATE_ROOT="$state" \
    bash "$SUPERVISE_SH" --json 2>/dev/null)" && rc=0 || rc=$?

  if [[ "$rc" -eq 0 ]]; then
    fail "Test 2: expected non-zero exit, got 0 (out=$out)"
    return
  fi
  kind="$(printf -- '%s' "$out" | json_error_kind)"
  if [[ "$kind" == "registry_error" ]]; then
    pass "Test 2: rc=$rc kind=registry_error"
  else
    fail "Test 2: rc=$rc kind='$kind' (expected registry_error) out=$out"
  fi
}

# ── Test 3: malformed YAML -> registry_error ────────────────────────────────

test_3_malformed_yaml() {
  log "Test 3: active.yaml exists but is not valid YAML -> registry_error"

  local proj state out rc kind
  proj="$(_tmp_dir)"
  state="$(_tmp_dir)"
  # Force the sandbox state layout (no git-common-dir resolution needed since
  # LEADV2_STATE_ROOT is set) — write directly to the resolved path.
  mkdir -p "$state"
  printf -- 'sessions: [\n  this is not: valid: yaml::::\n' > "${state}/active.yaml"

  out="$(LEADV2_PROJECT_ROOT="$proj" LEADV2_STATE_ROOT="$state" \
    bash "$SUPERVISE_SH" --json 2>/dev/null)" && rc=0 || rc=$?

  if [[ "$rc" -eq 0 ]]; then
    fail "Test 3: expected non-zero exit, got 0 (out=$out)"
    return
  fi
  kind="$(printf -- '%s' "$out" | json_error_kind)"
  if [[ "$kind" == "registry_error" ]]; then
    pass "Test 3: rc=$rc kind=registry_error"
  else
    fail "Test 3: rc=$rc kind='$kind' (expected registry_error) out=$out"
  fi
}

# ── Test 4: honest-empty -> exit 0, table: [] ───────────────────────────────

test_4_honest_empty() {
  log "Test 4: cleanly-parsed empty registry -> exit 0, table: []"

  local proj state out rc table_len
  proj="$(_tmp_dir)"
  state="$(_tmp_dir)"
  mkdir -p "$state"
  printf -- 'meta:\n  schema_version: 2\nsessions: []\n' > "${state}/active.yaml"

  out="$(LEADV2_PROJECT_ROOT="$proj" LEADV2_STATE_ROOT="$state" \
    bash "$SUPERVISE_SH" --json 2>/dev/null)" && rc=0 || rc=$?

  if [[ "$rc" -ne 0 ]]; then
    fail "Test 4: expected exit 0, got rc=$rc (out=$out)"
    return
  fi
  table_len="$(printf -- '%s' "$out" | python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); print(len(d.get("table", ["NOPE"])))' 2>/dev/null || echo "PARSE_ERROR")"
  if [[ "$table_len" == "0" ]]; then
    pass "Test 4: rc=0 table=[]"
  else
    fail "Test 4: rc=$rc table_len='$table_len' (expected 0) out=$out"
  fi
}

# ── Test 5: unwritable snapshot dir -> state_write_error ───────────────────

test_5_unwritable_state() {
  log "Test 5: valid registry but snapshot dir not writable -> state_write_error"

  local proj state out rc kind
  proj="$(_tmp_dir)"
  state="$(_tmp_dir)"
  mkdir -p "$state"
  printf -- 'meta:\n  schema_version: 2\nsessions: []\n' > "${state}/active.yaml"
  # r-x only: active.yaml stays readable, but no new file (the snapshot tmp
  # file) can be created in this directory.
  chmod 0500 "$state"

  out="$(LEADV2_PROJECT_ROOT="$proj" LEADV2_STATE_ROOT="$state" \
    bash "$SUPERVISE_SH" --json 2>/dev/null)" && rc=0 || rc=$?

  chmod 0700 "$state"  # restore before cleanup / any later assertions

  if [[ "$rc" -eq 0 ]]; then
    fail "Test 5: expected non-zero exit, got 0 (out=$out)"
    return
  fi
  kind="$(printf -- '%s' "$out" | json_error_kind)"
  if [[ "$kind" == "state_write_error" ]]; then
    pass "Test 5: rc=$rc kind=state_write_error"
  else
    fail "Test 5: rc=$rc kind='$kind' (expected state_write_error) out=$out"
  fi
}

# ── Test 6: syntax ───────────────────────────────────────────────────────────

test_6_syntax() {
  log "Test 6: bash -n syntax check"
  bash -n "$SUPERVISE_SH" 2>/dev/null && pass "Test 6: bash -n OK" || fail "Test 6: bash -n FAILED"
}

main() {
  log "=== leadv2-supervise fail-closed unit tests ==="
  log "Script: $SUPERVISE_SH"
  echo ""
  test_6_syntax
  test_1_wrong_cwd_root_error
  test_2_missing_registry
  test_3_malformed_yaml
  test_4_honest_empty
  test_5_unwritable_state
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
