#!/usr/bin/env bash
# deploy.sh — push main to VPS and restart systemd service
set -euo pipefail

log() { printf -- '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }

: "${LEAD_V2_TASK_ID:?LEAD_V2_TASK_ID env required}"
VPS_HOST="${DEPLOY_VPS_HOST:?DEPLOY_VPS_HOST not set (e.g. user@1.2.3.4)}"
REMOTE_REPO="${DEPLOY_REMOTE_REPO:?DEPLOY_REMOTE_REPO not set (e.g. /home/app/project)}"
SERVICE="${DEPLOY_SERVICE_NAME:?DEPLOY_SERVICE_NAME not set (e.g. myapp.service)}"

log "deploying task=$LEAD_V2_TASK_ID to $VPS_HOST"

# Push current main to remote
ssh -o ConnectTimeout=15 "$VPS_HOST" "cd '$REMOTE_REPO' && git fetch && git reset --hard origin/main"

# Restart service
ssh -o ConnectTimeout=15 "$VPS_HOST" "systemctl restart $SERVICE && systemctl is-active $SERVICE"

log "deploy complete"
