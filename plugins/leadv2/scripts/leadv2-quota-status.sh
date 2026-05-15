#!/usr/bin/env bash
# leadv2-quota-status.sh — Report rolling 5h + weekly token quota usage from ~/.claude/burn/history.db.
#
# Replaces leadv2-daily-budget.sh. Subscription-aware: counts tokens, not $.
#
# Usage:
#   --check     Exit 0 if under 85% of 5h window, exit 1 otherwise (logs WARN at 60%)
#   --report    Human-readable summary
#   --json      JSON for programmatic consumers
#
# Budgets (heuristic — tune via .claude/ref/leadv2-main-model.yaml):
#   5h input cap   ≈ 8M tokens  (max_5h_input_tokens)
#   weekly input   ≈ 100M       (max_weekly_input_tokens)

set -euo pipefail

MODE="report"
[[ "${1:-}" == "--check"  ]] && MODE="check"
[[ "${1:-}" == "--json"   ]] && MODE="json"
[[ "${1:-}" == "--report" ]] && MODE="report"

DB="$HOME/.claude/burn/history.db"
CFG="$(dirname "$0")/../ref/leadv2-main-model.yaml"

MAX_5H_IN=8000000
MAX_WK_IN=100000000
MIN_CACHE_HIT=0.30

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
    echo "Quota: unknown (burn DB missing — ~/.claude/burn/history.db)"
    exit 0
  fi
fi

read -r IN_5H OUT_5H CR_5H CC_5H <<EOF2
$(sqlite3 -separator ' ' "$DB" "SELECT COALESCE(SUM(input),0), COALESCE(SUM(output),0), COALESCE(SUM(cr),0), COALESCE(SUM(cc),0) FROM turn_events WHERE ts > datetime('now','-5 hours');" 2>/dev/null || echo "0 0 0 0")
EOF2

read -r IN_WK OUT_WK CR_WK <<EOF3
$(sqlite3 -separator ' ' "$DB" "SELECT COALESCE(SUM(input),0), COALESCE(SUM(output),0), COALESCE(SUM(cr),0) FROM turn_events WHERE ts > datetime('now','-7 days');" 2>/dev/null || echo "0 0 0")
EOF3

read -r IN_24 CR_24 <<EOF4
$(sqlite3 -separator ' ' "$DB" "SELECT COALESCE(SUM(input),0), COALESCE(SUM(cr),0) FROM turn_events WHERE ts > datetime('now','-24 hours');" 2>/dev/null || echo "0 0")
EOF4

PCT_5H=0
[[ "$MAX_5H_IN" -gt 0 ]] && PCT_5H=$(( IN_5H * 100 / MAX_5H_IN ))
PCT_WK=0
[[ "$MAX_WK_IN" -gt 0 ]] && PCT_WK=$(( IN_WK * 100 / MAX_WK_IN ))

CACHE_HIT_24=0
DENOM=$(( IN_24 + CR_24 ))
if [[ "$DENOM" -gt 0 ]]; then
  CACHE_HIT_24=$(awk -v a="$CR_24" -v b="$DENOM" 'BEGIN{printf "%.2f", a/b}')
fi

STATUS="safe"
REC="proceed"
if [[ "$PCT_5H" -ge 85 ]]; then
  STATUS="exhausted"
  REC="pause"
elif [[ "$PCT_5H" -ge 60 ]]; then
  STATUS="warn_60"
  REC="downgrade_to_sonnet"
elif [[ "$PCT_WK" -ge 85 ]]; then
  STATUS="weekly_warn"
  REC="downgrade_to_sonnet"
fi

case "$MODE" in
  check)
    if [[ "$STATUS" == "exhausted" ]]; then
      echo "QUOTA-EXHAUSTED: 5h input ${PCT_5H}% (${IN_5H}/${MAX_5H_IN})" >&2
      exit 1
    fi
    [[ "$PCT_5H" -ge 60 ]] && echo "QUOTA-WARN: 5h input ${PCT_5H}%" >&2
    exit 0
    ;;
  json)
    printf '{"window_5h":{"input":%d,"output":%d,"cr":%d,"pct":%d,"cap":%d},"window_weekly":{"input":%d,"pct":%d,"cap":%d},"cache_hit_24h":%s,"status":"%s","recommendation":"%s"}\n' \
      "$IN_5H" "$OUT_5H" "$CR_5H" "$PCT_5H" "$MAX_5H_IN" \
      "$IN_WK" "$PCT_WK" "$MAX_WK_IN" \
      "$CACHE_HIT_24" "$STATUS" "$REC"
    ;;
  report)
    printf "Quota: 5h %d%% (%s / %s in) | weekly %d%% | cache-hit %s | %s\n" \
      "$PCT_5H" "$IN_5H" "$MAX_5H_IN" "$PCT_WK" "$CACHE_HIT_24" "$STATUS"
    ;;
esac
