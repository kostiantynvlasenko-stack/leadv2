#!/usr/bin/env bash
# leadv2-workflows-sync.sh — idempotent sync of workflow JS files from plugin repo to user-level workflows dir.
# Run after plugin updates to ensure ~/.claude/workflows/ has the latest versions.
# Usage: bash leadv2-workflows-sync.sh [--dry-run]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_WORKFLOWS_DIR="$(dirname "${SCRIPT_DIR}")/workflows"
USER_WORKFLOWS_DIR="${HOME}/.claude/workflows"

DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=true
fi

log() { printf -- '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }

if [[ ! -d "${PLUGIN_WORKFLOWS_DIR}" ]]; then
  log "ERROR: plugin workflows dir not found: ${PLUGIN_WORKFLOWS_DIR}"
  exit 1
fi

mkdir -p "${USER_WORKFLOWS_DIR}"

log "Syncing leadv2 workflow scripts: ${PLUGIN_WORKFLOWS_DIR} -> ${USER_WORKFLOWS_DIR}"

if [[ "${DRY_RUN}" == "true" ]]; then
  log "DRY_RUN: would run: rsync -u \"${PLUGIN_WORKFLOWS_DIR}/\"leadv2-*.js \"${USER_WORKFLOWS_DIR}/\""
  rsync -u --dry-run "${PLUGIN_WORKFLOWS_DIR}/leadv2-"*.js "${USER_WORKFLOWS_DIR}/"
else
  rsync -u "${PLUGIN_WORKFLOWS_DIR}/leadv2-"*.js "${USER_WORKFLOWS_DIR}/"
  log "Sync complete. Files in ${USER_WORKFLOWS_DIR}:"
  find "${USER_WORKFLOWS_DIR}" -name "leadv2-*.js" -print0 | xargs -0 -I{} basename {}
fi
