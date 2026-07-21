#!/usr/bin/env bash
# scripts/tests/test-nested-depth.sh -- hardened nested-spawn contract
# (depth cap / write-role denylist / per-task count), gated by
# LEADV2_NESTED_DEPTH_GATE.
#
# Tests:
#   1. Depth cap: caller is itself explore|general-purpose (already a nested
#      sub-run) -> DENY route.subrun.depth_exceeded.
#   2. Write-role denylist: nested spawn target is a write-capable role
#      (e.g. developer) -> DENY route.subrun.write_role_denied.
#   3. Per-task count: 3 prior allow entries from mixed callers already
#      in the task audit log -> next spawn DENY route.subrun.count_exceeded.
#   4. Kill-switch: LEADV2_NESTED_DEPTH_GATE=0 -> depth-cap case from test 1
#      is allowed again (pre-existing base_allowlist behavior).
#
# Run: bash scripts/tests/test-nested-depth.sh
# Exit 0 = all pass; non-zero = failures found.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/leadv2-temp.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="${SCRIPT_DIR}/../../hooks/leadv2-routing-guard.sh"

PASS=0
FAIL=0
ERRORS=()

log()  { printf -- '[TEST] %s\n' "$*"; }
pass() { PASS=$((PASS + 1)); log "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); ERRORS+=("FAIL: $1"); log "FAIL: $1"; }

_mktemp_dir() { lv2_mktemp_dir "nested-depth-test"; }

# Build fake hook input JSON: caller=$1, subagent_type=$2, model=$3, cwd=$4.
_make_input() {
  local caller="$1" stype="$2" model="$3" cwd="$4"
  python3 -c "
import json, sys
print(json.dumps({
    'agent_type': sys.argv[1],
    'tool_input': {'subagent_type': sys.argv[2], 'model': sys.argv[3]},
    'cwd': sys.argv[4]
}))
" "$caller" "$stype" "$model" "$cwd"
}

_run_guard() {
  # $1=input json, remaining args = env assignments (KEY=VAL ...)
  local input="$1"; shift
  local rc=0
  env "$@" bash "$GUARD_SH" <<< "$input" >/dev/null 2>/dev/null || rc=$?
  echo "$rc"
}

# -- Test 1: depth cap -- caller is itself a nested sub-run ------------------
T1_DIR="$(_mktemp_dir)"
mkdir -p "${T1_DIR}/.git"
INPUT1="$(_make_input "explore" "general-purpose" "claude-haiku-4-5" "$T1_DIR")"
RC1="$(_run_guard "$INPUT1")"
if [[ "$RC1" == "2" ]]; then
  pass "T1: depth-exceeded spawn denied (rc=2)"
else
  fail "T1: expected rc=2, got rc=${RC1}"
fi
LOG1="${T1_DIR}/docs/leadv2/nested-spawns.log"
if [[ -f "$LOG1" ]] && grep -q "route.subrun.depth_exceeded" "$LOG1"; then
  pass "T1: audit log has route.subrun.depth_exceeded"
else
  fail "T1: audit log missing route.subrun.depth_exceeded reason"
fi
rm -rf "$T1_DIR"

# -- Test 2: write-role denylist ---------------------------------------------
T2_DIR="$(_mktemp_dir)"
mkdir -p "${T2_DIR}/.git"
INPUT2="$(_make_input "developer" "developer" "claude-sonnet-5" "$T2_DIR")"
RC2="$(_run_guard "$INPUT2")"
if [[ "$RC2" == "2" ]]; then
  pass "T2: write-role nested spawn denied (rc=2)"
else
  fail "T2: expected rc=2, got rc=${RC2}"
fi
LOG2="${T2_DIR}/docs/leadv2/nested-spawns.log"
if [[ -f "$LOG2" ]] && grep -q "route.subrun.write_role_denied" "$LOG2"; then
  pass "T2: audit log has route.subrun.write_role_denied"
else
  fail "T2: audit log missing route.subrun.write_role_denied reason"
fi
rm -rf "$T2_DIR"

# -- Test 3: per-task count exceeded -----------------------------------------
T3_DIR="$(_mktemp_dir)"
mkdir -p "${T3_DIR}/.git"
TASK3="NESTED-CAP-01"
mkdir -p "${T3_DIR}/docs/leadv2/tasks/${TASK3}"
LOG3="${T3_DIR}/docs/leadv2/tasks/${TASK3}/nested-spawns.log"
printf -- '%s\n' \
  '2026-07-21T00:00:01Z caller=developer target=explore model=haiku verdict=allow reason=policy_base' \
  '2026-07-21T00:00:02Z caller=architect target=explore model=haiku verdict=allow reason=policy_base' \
  '2026-07-21T00:00:03Z caller=developer target=general-purpose model=sonnet verdict=allow reason=policy_base' > "$LOG3"
INPUT3="$(_make_input "developer" "explore" "claude-haiku-4-5" "$T3_DIR")"
RC3="$(_run_guard "$INPUT3" "LEADV2_TASK_ID=${TASK3}")"
if [[ "$RC3" == "2" ]]; then
  pass "T3: 4th task-wide nested spawn denied at max_nested_per_task=3 (rc=2)"
else
  fail "T3: expected rc=2, got rc=${RC3}"
fi
if grep -q "route.subrun.count_exceeded" "$LOG3"; then
  pass "T3: audit log has route.subrun.count_exceeded"
else
  fail "T3: audit log missing route.subrun.count_exceeded reason"
fi
rm -rf "$T3_DIR"

# -- Test 4: kill-switch off -- depth-cap case allowed again -----------------
T4_DIR="$(_mktemp_dir)"
mkdir -p "${T4_DIR}/.git"
INPUT4="$(_make_input "explore" "general-purpose" "claude-haiku-4-5" "$T4_DIR")"
RC4="$(_run_guard "$INPUT4" "LEADV2_NESTED_DEPTH_GATE=0")"
if [[ "$RC4" == "0" ]]; then
  pass "T4: kill-switch off restores pre-existing allow behavior (rc=0)"
else
  fail "T4: expected rc=0 with LEADV2_NESTED_DEPTH_GATE=0, got rc=${RC4}"
fi
rm -rf "$T4_DIR"

# -- Summary ------------------------------------------------------------------
printf -- '\n[TEST SUMMARY] PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
for e in "${ERRORS[@]+"${ERRORS[@]}"}"; do
  printf -- '  %s\n' "$e"
done

[[ "$FAIL" -eq 0 ]]
