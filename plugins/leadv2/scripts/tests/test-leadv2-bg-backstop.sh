#!/usr/bin/env bash
# tests/test-leadv2-bg-backstop.sh - Unit tests for STALL-BACKSTOP-01
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LEDGER_SH="${SCRIPT_DIR}/../../hooks/leadv2-bg-ledger.sh"
WARN_SH="${SCRIPT_DIR}/../../hooks/leadv2-bg-stop-warn.sh"

PASS=0; FAIL=0; ERRORS=()
log()  { printf -- "[TEST] %s\n" "$*"; }
pass() { PASS=$(( PASS + 1 )); log "PASS: $1"; }
fail() { FAIL=$(( FAIL + 1 )); ERRORS+=("FAIL: $1"); log "FAIL: $1"; }
_sid() { printf -- "test-sess-%s%s" "$(date +%s)" "$$"; }
_clean() { rm -f "/tmp/leadv2-bg-ledger/${1}.log" "/tmp/leadv2-bg-ledger/${1}.stop-count"; }

T1="$(_sid)"; _clean "$T1"
printf '{"session_id":"%s","tool_name":"Agent","agent_type":"dev","tool_input":{"run_in_background":true,"description":"t1"}}' "$T1" | bash "$LEDGER_SH" >/dev/null 2>&1 || true
[[ ! -f "/tmp/leadv2-bg-ledger/${T1}.log" ]] && pass "T1: subagent no ledger" || fail "T1: subagent must not write"
_clean "$T1"

T2="$(_sid)"; _clean "$T2"
printf '{"session_id":"%s","tool_name":"Agent","tool_input":{"run_in_background":true,"description":"bg-agent"}}' "$T2" | bash "$LEDGER_SH" >/dev/null 2>&1 || true
{ [[ -f "/tmp/leadv2-bg-ledger/${T2}.log" ]] && grep -q BG_SPAWN "/tmp/leadv2-bg-ledger/${T2}.log"; } && pass "T2: BG_SPAWN written" || fail "T2: BG_SPAWN missing"
_clean "$T2"

T3="$(_sid)"; _clean "$T3"
printf '{"session_id":"%s","tool_name":"Agent","tool_input":{"run_in_background":false,"description":"fg"}}' "$T3" | bash "$LEDGER_SH" >/dev/null 2>&1 || true
! grep -q BG_SPAWN "/tmp/leadv2-bg-ledger/${T3}.log" 2>/dev/null && pass "T3: fg agent not BG_SPAWN" || fail "T3: fg should not record"
_clean "$T3"

T4="$(_sid)"; _clean "$T4"
printf '{"session_id":"%s","tool_name":"Monitor"}' "$T4" | bash "$LEDGER_SH" >/dev/null 2>&1 || true
{ [[ -f "/tmp/leadv2-bg-ledger/${T4}.log" ]] && grep -q WATCHDOG "/tmp/leadv2-bg-ledger/${T4}.log"; } && pass "T4: WATCHDOG written" || fail "T4: WATCHDOG missing"
_clean "$T4"

T5="$(_sid)"; _clean "$T5"
OUT="$(printf '{"session_id":"%s","stop_hook_active":false}' "$T5" | bash "$WARN_SH" 2>/dev/null || true)"
[[ -z "$OUT" ]] && pass "T5: no ledger no advisory" || fail "T5: unexpected output: $OUT"
_clean "$T5"

T6="$(_sid)"; _clean "$T6"
mkdir -p /tmp/leadv2-bg-ledger
printf -- '%s\tBG_SPAWN\tmy-agent\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "/tmp/leadv2-bg-ledger/${T6}.log"
OUT="$(LEADV2_BG_WARN_EVERY=1 printf '{"session_id":"%s","stop_hook_active":false}' "$T6" | bash "$WARN_SH" 2>/dev/null || true)"
printf -- "%s" "$OUT" | python3 -c "import sys,json; d=json.load(sys.stdin); assert \"systemMessage\" in d" 2>/dev/null && pass "T6: advisory emitted (systemMessage)" || fail "T6: no systemMessage advisory, got: $OUT"
_clean "$T6"

T7="$(_sid)"; _clean "$T7"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf -- '%s\tBG_SPAWN\tagent\n%s\tWATCHDOG\t(monitor)\n' "$TS" "$TS" > "/tmp/leadv2-bg-ledger/${T7}.log"
OUT="$(LEADV2_BG_WARN_EVERY=1 printf '{"session_id":"%s","stop_hook_active":false}' "$T7" | bash "$WARN_SH" 2>/dev/null || true)"
[[ -z "$OUT" ]] && pass "T7: watchdog clears advisory" || fail "T7: unexpected advisory: $OUT"
_clean "$T7"

T8="$(_sid)"; _clean "$T8"
printf -- '%s\tBG_SPAWN\tthrottled\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "/tmp/leadv2-bg-ledger/${T8}.log"
LEADV2_BG_WARN_EVERY=3 printf '{"session_id":"%s","stop_hook_active":false}' "$T8" | bash "$WARN_SH" >/dev/null 2>&1 || true
OUT="$(LEADV2_BG_WARN_EVERY=3 printf '{"session_id":"%s","stop_hook_active":false}' "$T8" | bash "$WARN_SH" 2>/dev/null || true)"
[[ -z "$OUT" ]] && pass "T8: throttle suppresses 2nd stop" || fail "T8: should suppress, got: $OUT"
_clean "$T8"

echo ""; echo "Results: ${PASS} passed, ${FAIL} failed"
[[ ${#ERRORS[@]} -gt 0 ]] && { for e in "${ERRORS[@]}"; do echo "  $e"; done; exit 1; }
exit 0
