#!/usr/bin/env bash
# tests/test-quota-weekly-live.sh — PLUGIN-TRIO-01 Fix C regression test.
#
# Guards: leadv2-quota-status.sh surfaces GLM's REAL weekly % (from the live z.ai read, via
# LEADV2_QUOTA_LIVE) instead of only the claude%-only heuristic — and degrades to "unmeasured",
# never 0, when the live read is unavailable/fails. Hermetic: no network, LEADV2_QUOTA_LIVE is
# swapped for a fake script so this never depends on ZAI_AUTH_TOKEN / a real z.ai call.
#
# Assertions:
#   1. bash -n syntax
#   2. --report shows the live pct when the fake live helper reports status=ok
#   3. --json embeds glm_live_pct as a NUMBER (not null) when live read succeeds
#   4. --report shows "unmeasured" (never a bare 0%) when the fake helper fails
#   5. --json embeds glm_live_pct:null (never 0) on the same failure path
#   6. --check is unaffected either way (still claude%-only; exit 0 on empty/low usage)
#
# Run: bash scripts/tests/test-quota-weekly-live.sh

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QUOTA_SH="${SCRIPT_DIR}/../leadv2-quota-status.sh"

PASS=0; FAIL=0; ERRORS=()
log()  { printf -- '[TEST] %s\n' "$*"; }
pass() { PASS=$((PASS+1)); log "PASS: $1"; }
fail() { FAIL=$((FAIL+1)); ERRORS+=("FAIL: $1"); log "FAIL: $1"; }

TMP="$(mktemp -d /tmp/quota-weekly-live-XXXXXX)"
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
"
export LEADV2_BURN_DB="$DB" LEADV2_MAIN_MODEL_CFG="$CFG"

# 1. syntax
if bash -n "$QUOTA_SH"; then pass "1 bash -n syntax"; else fail "1 bash -n syntax"; fi

# ── fake live helper: reports status=ok, weekly pct=17 ──────────────────────
FAKE_LIVE_OK="$TMP/fake-live-ok.sh"
cat > "$FAKE_LIVE_OK" <<'EOF'
#!/usr/bin/env bash
echo '{"provider":"glm","status":"ok","five_hour":{"pct":83,"reset_iso":"2026-07-17T15:45:44Z"},"weekly":{"pct":17,"reset_iso":"2026-07-24T10:30:44Z"}}'
EOF
chmod +x "$FAKE_LIVE_OK"

# 2/3. --report / --json with a healthy fake live helper.
rep_ok="$(LEADV2_QUOTA_LIVE="$FAKE_LIVE_OK" bash "$QUOTA_SH" --report)"
if printf '%s\n' "$rep_ok" | grep -qE 'glm weekly \(live, z\.ai\): 17%'; then
  pass "2 --report shows live glm weekly=17%"
else
  fail "2 --report missing live glm weekly=17% line: $(printf '%s\n' "$rep_ok" | grep 'glm weekly')"
fi

json_ok="$(LEADV2_QUOTA_LIVE="$FAKE_LIVE_OK" bash "$QUOTA_SH" --json)"
if printf '%s' "$json_ok" | grep -q '"glm_live_status":"ok","glm_live_pct":17'; then
  pass "3 --json glm_live_pct=17 (number, not null)"
else
  fail "3 --json glm_live fields wrong: $(printf '%s' "$json_ok" | sed -n 's/.*\(window_weekly[^}]*}\).*/\1/p')"
fi

# ── fake live helper: simulates a failed/unreachable read (empty stdout) ────
FAKE_LIVE_FAIL="$TMP/fake-live-fail.sh"
cat > "$FAKE_LIVE_FAIL" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$FAKE_LIVE_FAIL"

# 4/5. --report / --json on failure -> unmeasured / null, never 0.
rep_fail="$(LEADV2_QUOTA_LIVE="$FAKE_LIVE_FAIL" bash "$QUOTA_SH" --report)"
if printf '%s\n' "$rep_fail" | grep -qE 'glm weekly \(live, z\.ai\): unmeasured'; then
  pass "4 --report shows unmeasured on live-read failure (never 0%)"
else
  fail "4 --report did not degrade to unmeasured: $(printf '%s\n' "$rep_fail" | grep 'glm weekly')"
fi

json_fail="$(LEADV2_QUOTA_LIVE="$FAKE_LIVE_FAIL" bash "$QUOTA_SH" --json)"
if printf '%s' "$json_fail" | grep -q '"glm_live_status":"unmeasured","glm_live_pct":null'; then
  pass "5 --json glm_live_pct=null on failure (never 0)"
else
  fail "5 --json did not degrade to null: $(printf '%s' "$json_fail" | sed -n 's/.*\(window_weekly[^}]*}\).*/\1/p')"
fi

# 6. --check unaffected by the live-read outcome (empty db -> 0% claude usage -> exit 0).
set +e
LEADV2_QUOTA_LIVE="$FAKE_LIVE_FAIL" bash "$QUOTA_SH" --check >/dev/null 2>&1; rc=$?
set -e
if [[ $rc -eq 0 ]]; then
  pass "6 --check exit 0 regardless of live-read outcome (claude%-only breaker unchanged)"
else
  fail "6 --check exit $rc — live-read failure must not affect the claude%-only breaker"
fi

echo
echo "PASS=$PASS FAIL=$FAIL"
if [[ $FAIL -gt 0 ]]; then printf '%s\n' "${ERRORS[@]}" >&2; exit 1; fi
log "ALL PASS — GLM's real weekly % surfaces from the live read; unmeasured never lies as 0."
exit 0
