#!/usr/bin/env bash
# tests/test-quota-glm-filter.sh — QUOTA-GAUGE-COUNTS-GLM-AS-ANTHROPIC-01 regression test.
#
# Guards the load-bearing fix: the quota gauge must split queries by provider and the --check
# breaker must gate on claude% ONLY. If anyone ever drops the `AND model LIKE 'claude%'` filter
# from the 5h query, GLM volume gets attributed to Anthropic and the breaker trips on GLM —
# throttling the Claude-Max lead for work pushed onto GLM (punishing GLM-FIRST-01).
#
# Fixture: GLM row with 7,000,000 input (would be 87% of the 8M cap → EXHAUSTED if unfiltered),
# Anthropic row with 1,000 input (0.01%). Assertions:
#   1. bash -n syntax
#   2. --check exits 0  (GLM does NOT trip the Anthropic breaker)             [acceptance #3]
#   3. --json window_5h.input == 1000  (Anthropic bucket excludes GLM)        [the filter-drop detector]
#   4. --json providers.glm.w5h.input == 7000000  (GLM bucketed separately)
#   5. --json window_5h.pct < 60  (GLM not counted toward the Anthropic %)
#   6. --report anthropic line shows 1.0K, never 7.0M
#
# Portable: only sqlite3 + sh/sed builtins (no jq / GNU date / sed -i). Exit 0 = pass.
# Run: bash scripts/tests/test-quota-glm-filter.sh

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QUOTA_SH="${SCRIPT_DIR}/../leadv2-quota-status.sh"

PASS=0; FAIL=0; ERRORS=()
log()  { printf -- '[TEST] %s\n' "$*"; }
pass() { PASS=$((PASS+1)); log "PASS: $1"; }
fail() { FAIL=$((FAIL+1)); ERRORS+=("FAIL: $1"); log "FAIL: $1"; }

TMP="$(mktemp -d /tmp/quota-glm-XXXXXX)"
DB="$TMP/test.db"
CFG="$TMP/ref.yaml"
trap 'rm -rf "$TMP"' EXIT

printf 'max_5h_input_tokens: 8000000\nmax_weekly_input_tokens: 100000000\nmin_cache_hit_rate: 0.30\n' > "$CFG"

sqlite3 "$DB" "
CREATE TABLE turn_events(id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT, ts TEXT,
  cc INTEGER DEFAULT 0, cr INTEGER DEFAULT 0, input INTEGER DEFAULT 0, output INTEGER DEFAULT 0,
  model TEXT, tools_json TEXT);
CREATE TABLE kv(key TEXT PRIMARY KEY, value TEXT);
CREATE INDEX turn_events_ts ON turn_events(ts);
INSERT INTO turn_events(session_id,ts,input,output,model) VALUES
  ('glm1',    datetime('now','-30 minutes'), 7000000, 100000, 'glm-5.2'),
  ('claude1', datetime('now','-1 hour'),     1000,    500,    'claude-opus-4-8');
"
export LEADV2_BURN_DB="$DB" LEADV2_MAIN_MODEL_CFG="$CFG"

# 1. syntax
if bash -n "$QUOTA_SH"; then pass "1 bash -n syntax"; else fail "1 bash -n syntax"; fi

# 2. --check exits 0 — GLM's 7M must NOT trip the Anthropic breaker.
set +e
out_check="$(bash "$QUOTA_SH" --check 2>&1 >/dev/null)"; rc=$?
set -e
if [[ $rc -eq 0 ]]; then
  pass "2 --check exit 0 (GLM 7M did not trip Anthropic breaker)"
else
  fail "2 --check exit $rc — GLM tripped the Anthropic breaker (model filter dropped?): $out_check"
fi

# 3/4/5. JSON bucket separation (pinned to the script's JSON layout).
json="$(bash "$QUOTA_SH" --json)"
claude_in="$(printf '%s' "$json" | sed -n 's/.*"window_5h":{"input":\([0-9]*\).*/\1/p' | head -1)"
glm_in="$(printf '%s'    "$json" | sed -n 's/.*"glm":{"w5h":{"input":\([0-9]*\).*/\1/p' | head -1)"
pct5="$(printf '%s'      "$json" | sed -n 's/.*"window_5h":{[^}]*"pct":\([0-9]*\).*/\1/p' | head -1)"
if [[ "$claude_in" == "1000" ]]; then
  pass "3 anthropic 5h input=$claude_in (GLM excluded from Anthropic)"
else
  fail "3 anthropic 5h input='${claude_in:-<empty>}' expected 1000 — model filter dropped? (GLM leaked into Anthropic)"
fi
if [[ "$glm_in" == "7000000" ]]; then pass "4 glm 5h input=$glm_in (GLM bucketed)"; else fail "4 glm 5h input='${glm_in:-<empty>}' expected 7000000"; fi
if [[ "${pct5:-0}" -lt 60 ]]; then pass "5 window_5h.pct=$pct5 < 60 (claude% only)"; else fail "5 window_5h.pct='${pct5:-?}' >= 60 — GLM counted toward Anthropic?"; fi

# 6. --report human line.
rep="$(bash "$QUOTA_SH" --report)"
if printf '%s\n' "$rep" | grep -qE 'anthropic 5h:.*in 1\.0K' && ! printf '%s\n' "$rep" | grep -qE 'anthropic 5h:.*in 7\.0M'; then
  pass "6 report anthropic shows 1.0K, not 7.0M"
else
  fail "6 report anthropic line wrong: $(printf '%s\n' "$rep" | grep 'anthropic 5h')"
fi

echo
echo "PASS=$PASS FAIL=$FAIL"
if [[ $FAIL -gt 0 ]]; then printf '%s\n' "${ERRORS[@]}" >&2; exit 1; fi
log "ALL PASS — the provider filter is intact; GLM cannot throttle the Anthropic lead."
exit 0
