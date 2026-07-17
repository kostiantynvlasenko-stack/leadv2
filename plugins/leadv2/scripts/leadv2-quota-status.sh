#!/usr/bin/env bash
# leadv2-quota-status.sh — Report rolling 5h + weekly token quota usage from ~/.claude/burn/history.db,
# split by provider. Replaces leadv2-daily-budget.sh. Subscription-aware: counts tokens, not $.
#
# CRITICAL (QUOTA-GAUGE-COUNTS-GLM-AS-ANTHROPIC-01): every quota query filters by provider.
#   glm-coder.sh drives the SAME `claude` CLI against Z.AI's Anthropic-compatible endpoint, so GLM
#   runs land in the SAME history.db as Claude-Max runs. Summing with no model filter attributes
#   ~99.8% of the reported "Anthropic usage" to GLM — and the --check breaker then throttles the
#   Claude-Max lead for work pushed onto GLM, i.e. it punishes GLM-FIRST-01. The breaker MUST gate
#   on claude% only. There is a regression test that fails if this filter is dropped: see
#   scripts/tests/test-quota-glm-filter.sh.
#
# Provider split (by the `model` column on turn_events):
#   model LIKE 'claude%'  -> Claude Max subscription (opus/sonnet/fable/haiku)
#   model LIKE 'glm%'     -> Z.AI / GLM Coding Pro subscription
#   codex is NOT in this db — it goes through the ChatGPT subscription and is unmeasured; said so
#   explicitly (never imply zero). Rows matching neither pattern (e.g. <synthetic>) are excluded.
#
# Metrics per provider: input + cc(cache_creation) + cr(cache_read) + output. Anthropic sessions run
# almost entirely on cache (cr), so `input` alone measures nearly nothing of what a Max session burns
# — the full breakdown is reported. The --check breaker still uses the heuristic *input* cap below
# because that is what the cap was calibrated to; the report flags when claude% burn is
# cache-dominated so the operator knows input% under-counts.
#
# rate_limit_info hook: Anthropic's own quota signal (status / rateLimitType / resetsAt /
# overageStatus) appears in API responses but is NOT yet captured into history.db. Capturing it
# needs aggregator.py to parse the response envelope + a schema migration on the account-wide burn
# db — a separate, risk-bearing change that is out of scope for the gauge. As a read-side hook, the
# gauge consults the kv table for a key that the future capture writes; when present and fresh it is
# preferred over the heuristic cap and can trip --check directly (no further gauge change needed):
#     key:   rate_limit_anthropic
#     value: JSON {"status","rateLimitType","resetsAt","overageStatus","captured_epoch",...}
# Until that key exists, every mode labels the cap as a heuristic estimate.
#
# Weekly axis (PLUGIN-TRIO-01 Fix C): the "weekly" figure derived from history.db (below, PCT_WK)
# is a claude%-only INPUT-token heuristic against a guessed 100M cap — it is NOT the number the
# founder sees in the z.ai console (that console reports GLM's real weekly bucket). QUOTA-GATE-01
# already solved "read GLM's real weekly %" correctly (leadv2-quota-read.py disambiguates the 5h vs
# weekly TOKENS_LIMIT entries by nextResetTime distance, never by array index, and fails to
# status=unknown rather than 0 on any read error). This script now ALSO surfaces that live number
# (best-effort, via leadv2-quota-live.sh) alongside the heuristic one instead of leaving the
# reader to misread PCT_WK as "the GLM weekly %". Any failure -> printed as "unmeasured", never 0.
# --check is UNCHANGED (still claude%-only heuristic breaker; GLM's own breaker is
# leadv2-glm-quota-gate.sh, which already reads the live number). Override for tests:
# LEADV2_QUOTA_LIVE=<path to leadv2-quota-live.sh>.
#
# Usage:
#   --check     Exit 0 if Anthropic quota OK, exit 1 if exhausted (claude% only; WARN at 60%)
#   --report    Human-readable summary
#   --json      JSON for programmatic consumers
#
# Budgets (HEURISTIC ESTIMATES — tune via .claude/ref/leadv2-main-model.yaml):
#   5h input cap   ≈ 8M tokens  (max_5h_input_tokens)   [claude% only]
#   weekly input   ≈ 100M       (max_weekly_input_tokens) [claude% only]
#
# Test overrides: LEADV2_BURN_DB=/path/test.db  LEADV2_MAIN_MODEL_CFG=/path/ref.yaml

set -euo pipefail

MODE="report"
[[ "${1:-}" == "--check"  ]] && MODE="check"
[[ "${1:-}" == "--json"   ]] && MODE="json"
[[ "${1:-}" == "--report" ]] && MODE="report"

DB="${LEADV2_BURN_DB:-$HOME/.claude/burn/history.db}"
CFG="${LEADV2_MAIN_MODEL_CFG:-$(dirname "$0")/../ref/leadv2-main-model.yaml}"
QUOTA_LIVE="${LEADV2_QUOTA_LIVE:-$(dirname "$0")/leadv2-quota-live.sh}"

MAX_5H_IN=8000000
MAX_WK_IN=100000000
MIN_CACHE_HIT=0.30
# A captured rate_limit_info signal is trusted for this many seconds, then we fall back to the
# heuristic. 10 min ≈ the cadence at which a lane log typically refreshes.
RL_FRESH_SECS=600

if [[ -f "$CFG" ]]; then
  v=$(grep -E '^\s*max_5h_input_tokens:' "$CFG" | awk '{print $2}' | head -1 || true)
  [[ -n "${v:-}" ]] && MAX_5H_IN="$v"
  v=$(grep -E '^\s*max_weekly_input_tokens:' "$CFG" | awk '{print $2}' | head -1 || true)
  [[ -n "${v:-}" ]] && MAX_WK_IN="$v"
  v=$(grep -E '^\s*min_cache_hit_rate:' "$CFG" | awk '{print $2}' | head -1 || true)
  [[ -n "${v:-}" ]] && MIN_CACHE_HIT="$v"
fi

if [[ ! -f "$DB" ]]; then
  if [[ "$MODE" == "check" ]]; then
    echo "WARN: burn DB missing — proceeding conservatively" >&2
    exit 0
  elif [[ "$MODE" == "json" ]]; then
    echo '{"status":"unknown","reason":"burn_db_missing"}'
    exit 0
  else
    echo "Quota: unknown (burn DB missing — $DB)"
    exit 0
  fi
fi

# ── Per-provider stats. Each row: input cc cr output turns ────────────────
stats() {  # $1 = SQL predicate appended to WHERE
  sqlite3 -separator ' ' "$DB" \
    "SELECT COALESCE(SUM(input),0), COALESCE(SUM(cc),0), COALESCE(SUM(cr),0), COALESCE(SUM(output),0), COALESCE(COUNT(*),0) FROM turn_events WHERE $1;" 2>/dev/null \
    || echo "0 0 0 0 0"
}

read -r C5_IN C5_CC C5_CR C5_OUT C5_N <<EOF2
$(stats "ts > datetime('now','-5 hours') AND model LIKE 'claude%'")
EOF2

read -r G5_IN G5_CC G5_CR G5_OUT G5_N <<EOF5
$(stats "ts > datetime('now','-5 hours') AND model LIKE 'glm%'")
EOF5

read -r CW_IN CW_CC CW_CR CW_OUT CW_N <<EOF3
$(stats "ts > datetime('now','-7 days') AND model LIKE 'claude%'")
EOF3

read -r GW_IN GW_CC GW_CR GW_OUT GW_N <<EOF6
$(stats "ts > datetime('now','-7 days') AND model LIKE 'glm%'")
EOF6

# ── Live GLM weekly (real number; PLUGIN-TRIO-01 Fix C) ────────────────────
# Best-effort read via leadv2-quota-live.sh -> leadv2-quota-read.py, which already
# disambiguates the 5h vs weekly TOKENS_LIMIT bucket by nextResetTime distance
# (never array index) and never reports 0 on a read error. Any failure here
# (helper missing, network down, malformed JSON, status!=ok) degrades to
# GLM_WK_STATUS=unmeasured — never fabricates a percentage.
GLM_WK_STATUS="unmeasured"
GLM_WK_PCT=""
GLM_WK_RESET=""
if [[ -f "$QUOTA_LIVE" ]]; then
  _glm_live_json="$(bash "$QUOTA_LIVE" glm 2>/dev/null || true)"
  if [[ -n "$_glm_live_json" ]]; then
    _glm_parsed="$(printf '%s' "$_glm_live_json" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
    w = d.get("weekly") or {}
    pct = w.get("pct")
    if d.get("status") != "ok" or pct is None:
        raise ValueError("not ok / no pct")
    print("ok %s %s" % (pct, (w.get("reset_iso") or "?")[:19]))
except Exception:
    print("unmeasured 0 -")
' 2>/dev/null || echo "unmeasured 0 -")"
    read -r GLM_WK_STATUS GLM_WK_PCT GLM_WK_RESET <<<"$_glm_parsed"
  fi
fi

# 24h cache-hit is a Claude-Max subscription metric → claude% only.
read -r C24_IN C24_CR <<EOF4
$(sqlite3 -separator ' ' "$DB" "SELECT COALESCE(SUM(input),0), COALESCE(SUM(cr),0) FROM turn_events WHERE ts > datetime('now','-24 hours') AND model LIKE 'claude%';" 2>/dev/null || echo "0 0")
EOF4

# ── rate_limit_info hook (kv table; written by future aggregator capture) ──
RL_JSON=""
RL_STATUS=""
RL_OVERAGE=""
RL_RESETS=""
RL_CAP_BASIS="heuristic_estimate"
RL_FRESH=0
RL_RAW="$(sqlite3 "$DB" "SELECT value FROM kv WHERE key='rate_limit_anthropic';" 2>/dev/null || true)"
if [[ -n "$RL_RAW" ]]; then
  RL_JSON="$RL_RAW"
  RL_STATUS="$(printf '%s' "$RL_RAW" | sed -n 's/.*"status"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
  RL_OVERAGE="$(printf '%s' "$RL_RAW" | sed -n 's/.*"overageStatus"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
  RL_RESETS="$(printf '%s' "$RL_RAW" | sed -n 's/.*"resetsAt"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' | head -1)"
  RL_EPOCH="$(printf '%s' "$RL_RAW" | sed -n 's/.*"captured_epoch"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' | head -1)"
  if [[ -n "${RL_EPOCH:-}" ]]; then
    now_ep="$(date -u +%s)"
    [[ $(( now_ep - RL_EPOCH )) -lt $RL_FRESH_SECS ]] && RL_FRESH=1
    [[ "$RL_FRESH" == "1" ]] && RL_CAP_BASIS="rate_limit_info"
  fi
fi

# ── Percentages (claude% only; the cap is a heuristic estimate) ───────────
PCT_5H=0
[[ "$MAX_5H_IN" -gt 0 ]] && PCT_5H=$(( C5_IN * 100 / MAX_5H_IN ))
PCT_WK=0
[[ "$MAX_WK_IN" -gt 0 ]] && PCT_WK=$(( CW_IN * 100 / MAX_WK_IN ))

CACHE_HIT_24=0
DENOM=$(( C24_IN + C24_CR ))
if [[ "$DENOM" -gt 0 ]]; then
  CACHE_HIT_24=$(awk -v a="$C24_CR" -v b="$DENOM" 'BEGIN{printf "%.2f", a/b}')
fi

# Cache-dominated? Anthropic cr dwarfs input → the input% the breaker uses is not real burn.
CACHE_NOTE=""
if [[ "$C5_CR" -gt 0 && $(( C5_IN * 10 )) -lt "$C5_CR" ]]; then
  CACHE_NOTE="  [cache-dominated — input% under-counts real burn]"
fi

# ── Status / recommendation — claude% ONLY; rate_limit_info overrides when fresh ──
STATUS="safe"
REC="proceed"
if [[ "$RL_FRESH" == "1" && ( "$RL_STATUS" != "allowed" || "$RL_OVERAGE" == "rejected" ) ]]; then
  STATUS="exhausted"
  REC="pause"
  PCT_5H=100  # provider's own signal overrides the heuristic estimate
elif [[ "$PCT_5H" -ge 85 ]]; then
  STATUS="exhausted"; REC="pause"
elif [[ "$PCT_5H" -ge 60 ]]; then
  STATUS="warn_60"; REC="downgrade_to_sonnet"
elif [[ "$PCT_WK" -ge 85 ]]; then
  STATUS="weekly_warn"; REC="downgrade_to_sonnet"
fi

# Human-friendly token magnitude.
hm() { awk -v n="$1" 'BEGIN{ if(n>=1000000000) printf "%.2fB", n/1000000000; else if(n>=1000000) printf "%.1fM", n/1000000; else if(n>=1000) printf "%.1fK", n/1000; else printf "%d", n }'; }

case "$MODE" in
  check)
    if [[ "$STATUS" == "exhausted" ]]; then
      echo "QUOTA-EXHAUSTED: Anthropic 5h ${PCT_5H}% (claude% input ${C5_IN}/${MAX_5H_IN} est; basis=${RL_CAP_BASIS})" >&2
      exit 1
    fi
    [[ "$PCT_5H" -ge 60 ]] && echo "QUOTA-WARN: Anthropic 5h ${PCT_5H}% (claude% only, est)" >&2
    exit 0
    ;;
  json)
    # Backward-compatible top-level fields (now claude%-only) + per-provider breakdown.
    rl_block="null"
    [[ -n "$RL_JSON" ]] && rl_block="$RL_JSON"
    # window_weekly.pct/input stay the claude%-only heuristic (unchanged, backward-compat);
    # glm_live_* is the NEW real number (PLUGIN-TRIO-01 Fix C) — "unmeasured" degrades to
    # glm_live_pct:null, never 0.
    if [[ "$GLM_WK_STATUS" == "ok" ]]; then
      glm_live_pct_json="$GLM_WK_PCT"
    else
      glm_live_pct_json="null"
    fi
    printf '{"window_5h":{"input":%d,"cc":%d,"cr":%d,"output":%d,"pct":%d,"cap":%d,"cap_basis":"%s"},"window_weekly":{"input":%d,"pct":%d,"cap":%d,"glm_live_status":"%s","glm_live_pct":%s,"glm_live_reset":"%s"},"cache_hit_24h":%s,"status":"%s","recommendation":"%s","providers":{"anthropic":{"w5h":{"input":%d,"cc":%d,"cr":%d,"output":%d,"turns":%d},"weekly":{"input":%d,"cc":%d,"cr":%d,"output":%d,"turns":%d}},"glm":{"w5h":{"input":%d,"cc":%d,"cr":%d,"output":%d,"turns":%d},"weekly":{"input":%d,"cc":%d,"cr":%d,"output":%d,"turns":%d}},"codex":"unmeasured"},"rate_limit":%s}\n' \
      "$C5_IN" "$C5_CC" "$C5_CR" "$C5_OUT" "$PCT_5H" "$MAX_5H_IN" "$RL_CAP_BASIS" \
      "$CW_IN" "$PCT_WK" "$MAX_WK_IN" "$GLM_WK_STATUS" "$glm_live_pct_json" "$GLM_WK_RESET" \
      "$CACHE_HIT_24" "$STATUS" "$REC" \
      "$C5_IN" "$C5_CC" "$C5_CR" "$C5_OUT" "$C5_N" \
      "$CW_IN" "$CW_CC" "$CW_CR" "$CW_OUT" "$CW_N" \
      "$G5_IN" "$G5_CC" "$G5_CR" "$G5_OUT" "$G5_N" \
      "$GW_IN" "$GW_CC" "$GW_CR" "$GW_OUT" "$GW_N" \
      "$rl_block"
    ;;
  report)
    printf "Quota: 5h %d%% (%d / %d in, claude%% only, cap est.) | weekly(claude,heuristic) %d%% | cache-hit %s | %s\n" \
      "$PCT_5H" "$C5_IN" "$MAX_5H_IN" "$PCT_WK" "$CACHE_HIT_24" "$STATUS"
    printf "  anthropic 5h: in %s  cc %s  cr %s  out %s  (%d turns)%s\n" \
      "$(hm "$C5_IN")" "$(hm "$C5_CC")" "$(hm "$C5_CR")" "$(hm "$C5_OUT")" "$C5_N" "$CACHE_NOTE"
    printf "  glm 5h:      in %s  cc %s  cr %s  out %s  (%d turns)  [Z.AI sub — not gated]\n" \
      "$(hm "$G5_IN")" "$(hm "$G5_CC")" "$(hm "$G5_CR")" "$(hm "$G5_OUT")" "$G5_N"
    if [[ "$GLM_WK_STATUS" == "ok" ]]; then
      printf "  glm weekly (live, z.ai): %s%%  (resets %sZ)  — real provider number, matches z.ai console\n" "$GLM_WK_PCT" "$GLM_WK_RESET"
    else
      printf "  glm weekly (live, z.ai): unmeasured (read failed or ZAI_AUTH_TOKEN unavailable — never reported as 0%%)\n"
    fi
    printf "  codex:       unmeasured (ChatGPT subscription, not in this db)\n"
    if [[ "$RL_FRESH" == "1" ]]; then
      printf "  rate_limit:  %s (status=%s overage=%s resets=%s) — provider signal, preferred over cap est.\n" "$RL_CAP_BASIS" "${RL_STATUS:-?}" "${RL_OVERAGE:-?}" "${RL_RESETS:-?}"
    else
      printf "  rate_limit:  not captured (heuristic cap in use) — kv hook: key=rate_limit_anthropic\n"
    fi
    ;;
esac
