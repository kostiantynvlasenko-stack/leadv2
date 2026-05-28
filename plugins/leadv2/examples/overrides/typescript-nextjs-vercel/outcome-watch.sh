#!/usr/bin/env bash
# outcome-watch.sh — poll Vercel deploy health until stable or timeout
set -euo pipefail

: "${LEAD_V2_TASK_ID:?LEAD_V2_TASK_ID env required}"
URL_FILE="/tmp/leadv2-last-deploy-url"
HEALTH_PATH="${VERIFY_HEALTH_PATH:-/api/health}"
WATCH_DURATION="${OUTCOME_WATCH_SEC:-300}"
POLL_INTERVAL="${OUTCOME_POLL_INTERVAL:-15}"

if [[ ! -f "$URL_FILE" ]]; then
  echo "[outcome-watch] no deploy URL file at $URL_FILE — skipping watch"
  exit 0
fi

URL=$(cat "$URL_FILE")
echo "[outcome-watch] watching $URL$HEALTH_PATH for ${WATCH_DURATION}s"

end=$(($(date +%s) + WATCH_DURATION))
failures=0
MAX_FAILURES=3

while (( $(date +%s) < end )); do
  if curl -fsS --max-time 10 "$URL$HEALTH_PATH" > /dev/null 2>&1; then
    failures=0
    echo "[outcome-watch] $(date '+%H:%M:%S') OK"
  else
    (( failures++ )) || true
    echo "[outcome-watch] $(date '+%H:%M:%S') FAIL ($failures/$MAX_FAILURES)"
    if (( failures >= MAX_FAILURES )); then
      echo "[outcome-watch] $MAX_FAILURES consecutive failures — deploy unstable"
      exit 1
    fi
  fi
  sleep "$POLL_INTERVAL"
done

echo "[outcome-watch] watch complete — no sustained failures"
exit 0
