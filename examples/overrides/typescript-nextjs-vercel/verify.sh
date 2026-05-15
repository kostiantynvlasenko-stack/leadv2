#!/usr/bin/env bash
# verify.sh — health-check the deployed URL
set -euo pipefail

: "${LEAD_V2_TASK_ID:?LEAD_V2_TASK_ID env required}"
URL_FILE="/tmp/leadv2-last-deploy-url"

if [[ ! -f "$URL_FILE" ]]; then
  echo "[verify] no deploy URL — was deploy.sh skipped?"
  exit 1
fi

URL=$(cat "$URL_FILE")
HEALTH_PATH="${VERIFY_HEALTH_PATH:-/api/health}"
TIMEOUT="${VERIFY_TIMEOUT_SEC:-120}"

echo "[verify] probing $URL$HEALTH_PATH (timeout ${TIMEOUT}s)"

# Give Vercel a moment to promote the deploy
sleep 5

end=$(($(date +%s) + TIMEOUT))
while (( $(date +%s) < end )); do
  if curl -fsS --max-time 10 "$URL$HEALTH_PATH" > /dev/null; then
    echo "[verify] $URL$HEALTH_PATH → 200 OK"
    exit 0
  fi
  sleep 5
done

echo "[verify] timeout — $URL$HEALTH_PATH never returned 200"
exit 1
