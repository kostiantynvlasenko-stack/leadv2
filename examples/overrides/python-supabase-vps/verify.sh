#!/usr/bin/env bash
# verify.sh — tail app log for success signal, abort on error spike
# Exit 0 = pass, 1 = timeout, 2 = negative signal
set -euo pipefail

: "${LEAD_V2_TASK_ID:?LEAD_V2_TASK_ID env required}"
VPS_HOST="${DEPLOY_VPS_HOST:?DEPLOY_VPS_HOST not set}"
LOG_PATH="${VERIFY_LOG_PATH:-/var/log/myapp/cycle.log}"
SUCCESS_PATTERN="${VERIFY_SUCCESS_PATTERN:-cycle_complete|task_done}"
TIMEOUT="${VERIFY_TIMEOUT_SEC:-300}"

# Wait for deploy to settle
sleep 15

# Tail log with timeout, exit on first success match or first error match
result=$(ssh -o ConnectTimeout=15 "$VPS_HOST" "timeout $TIMEOUT tail -F '$LOG_PATH'" 2>/dev/null | \
  awk -v ok="$SUCCESS_PATTERN" -v err="ERROR|CRITICAL|Traceback" '
    $0 ~ err { print "NEG"; exit }
    $0 ~ ok  { print "OK"; exit }
  ')

case "$result" in
  OK)  echo "[verify] success signal seen"; exit 0 ;;
  NEG) echo "[verify] error signal seen"; exit 2 ;;
  *)   echo "[verify] timeout after ${TIMEOUT}s"; exit 1 ;;
esac
