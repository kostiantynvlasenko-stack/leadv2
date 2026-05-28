#!/usr/bin/env bash
# outcome-watch.sh — watch VPS service health after deploy
set -euo pipefail

: "${LEAD_V2_TASK_ID:?LEAD_V2_TASK_ID env required}"
VPS_HOST="${DEPLOY_VPS_HOST:?DEPLOY_VPS_HOST not set}"
SERVICE="${DEPLOY_SERVICE_NAME:?DEPLOY_SERVICE_NAME not set}"
WATCH_DURATION="${OUTCOME_WATCH_SEC:-300}"
POLL_INTERVAL="${OUTCOME_POLL_INTERVAL:-20}"

echo "[outcome-watch] watching $SERVICE on $VPS_HOST for ${WATCH_DURATION}s"

end=$(($(date +%s) + WATCH_DURATION))
failures=0
MAX_FAILURES=3

while (( $(date +%s) < end )); do
  status=$(ssh -o ConnectTimeout=10 "$VPS_HOST" "systemctl is-active '$SERVICE' 2>/dev/null || echo inactive")
  if [[ "$status" == "active" ]]; then
    failures=0
    echo "[outcome-watch] $(date '+%H:%M:%S') $SERVICE active"
  else
    (( failures++ )) || true
    echo "[outcome-watch] $(date '+%H:%M:%S') $SERVICE $status ($failures/$MAX_FAILURES)"
    if (( failures >= MAX_FAILURES )); then
      echo "[outcome-watch] $MAX_FAILURES consecutive non-active — deploy unstable"
      exit 1
    fi
  fi
  sleep "$POLL_INTERVAL"
done

echo "[outcome-watch] watch complete — service stable"
exit 0
