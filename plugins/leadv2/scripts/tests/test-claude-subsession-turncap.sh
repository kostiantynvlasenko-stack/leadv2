#!/usr/bin/env bash
# Offline regression coverage for the claude-subsession turn-cap default.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUBSESSION_SH="${SCRIPT_DIR}/../claude-subsession.sh"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/leadv2-subsession-turncap.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf '[TEST] PASS: %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '[TEST] FAIL: %s\n' "$1"; }

mkdir -p "$ROOT/.claude/agents" "$ROOT/docs/handoff/TURNCAP-TEST"
printf '%s\n' 'Test role body.' > "$ROOT/.claude/agents/developer.md"
printf '%s\n' 'Test mission.' > "$ROOT/mission.md"

capture_cap() {
  local capture="$1" override="${2:-}"
  (
    export PROJECT_ROOT="$ROOT" LEADV2_DRY_RUN=1 LEADV2_ROUTE_BANDIT=0
    [[ -n "$override" ]] && export LEADV2_SUBSESSION_MAX_TURNS="$override"
    trap 'printf "%s\n" "${MAX_TURNS:-missing}" > "'$capture'"' EXIT
    # shellcheck disable=SC1090
    source "$SUBSESSION_SH" --role developer --model sonnet --task-id TURNCAP-TEST \
      --mission-file "$ROOT/mission.md" --wait >/dev/null 2>&1
  )
  cat "$capture"
}

if [[ "$(capture_cap "$ROOT/default")" == "110" ]]; then
  pass "default max turns is 110"
else
  fail "default max turns is not 110"
fi

if [[ "$(capture_cap "$ROOT/override" "37")" == "37" ]]; then
  pass "LEADV2_SUBSESSION_MAX_TURNS override wins over the default"
else
  fail "LEADV2_SUBSESSION_MAX_TURNS override did not win"
fi

printf '[TEST] Results: PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
