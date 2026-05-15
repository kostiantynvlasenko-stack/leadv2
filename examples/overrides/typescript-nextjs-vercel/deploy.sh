#!/usr/bin/env bash
# deploy.sh — Vercel production deploy
set -euo pipefail

log() { printf -- '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }

: "${LEAD_V2_TASK_ID:?LEAD_V2_TASK_ID env required}"
WEB_DIR="${WEB_DIR:-web}"

log "deploying task=$LEAD_V2_TASK_ID via Vercel"

cd "$WEB_DIR"

# Build + deploy to production. Vercel CLI handles env vars from .vercel/project.json.
DEPLOY_URL=$(vercel --prod --confirm --yes 2>&1 | tail -1)

if [[ -z "$DEPLOY_URL" ]]; then
  log "ERROR: vercel did not return a deploy URL"
  exit 1
fi

log "deployed: $DEPLOY_URL"
echo "$DEPLOY_URL" > /tmp/leadv2-last-deploy-url
