#!/usr/bin/env bash
# leadv2-soak-rollback.sh — thin wrapper over existing rollback path.
# C2.5/D6: delegates to .claude/leadv2-overrides/deploy.sh --rollback if present,
# else to rollback-fleet.sh. Refuses direct VPS ssh/scp/git-checkout ops.
#
# Usage:
#   LEADV2_TASK_ID=<id> LEADV2_PROJECT_ROOT=<root> bash leadv2-soak-rollback.sh
#
# Called ONLY by leadv2-outcome-watch.sh after regression detection and human-gate
# conditions are satisfied (D12: Standard requires LEADV2_SOAK_AUTOROLLBACK_STANDARD=1).
# Never call with --yes or direct ssh — this is a wrapper that delegates only.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LEADV2_PROJECT_ROOT="${LEADV2_PROJECT_ROOT:-${CLAUDE_PROJECT_DIR:-${PROJECT_ROOT:-$(git -C "$(dirname "$SCRIPT_DIR")" rev-parse --show-toplevel 2>/dev/null || pwd)}}}"

log()       { printf -- '[soak-rollback] %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
log_error() { log "ERROR: $*"; }

TASK_ID="${LEADV2_TASK_ID:-}"
if [[ -z "$TASK_ID" ]]; then
  log_error "LEADV2_TASK_ID is required"
  exit 1
fi

# D6: refuse direct VPS ssh/scp/git-checkout patterns
# This wrapper is a pure delegator; it must never contain direct remote ops.
_check_no_direct_ssh() {
  # Safety self-check: if this script somehow contains direct ssh/scp/git-checkout
  # lines (injected via env or override), refuse to proceed.
  local script_content
  script_content=$(cat "$0" 2>/dev/null || true)
  if printf '%s\n' "$script_content" | grep -qE '^\s*(ssh|scp)\s+[^#]' 2>/dev/null; then
    log_error "BLOCKED: direct ssh/scp detected in rollback script — D6 violation"
    exit 1
  fi
  if printf '%s\n' "$script_content" | grep -qE 'git\s+checkout' 2>/dev/null; then
    log_error "BLOCKED: direct git checkout detected — D6 violation (use deploy.sh --rollback)"
    exit 1
  fi
}
_check_no_direct_ssh

OVERRIDES_DIR="${LEADV2_PROJECT_ROOT}/.claude/leadv2-overrides"
OVERRIDE_DEPLOY="${OVERRIDES_DIR}/deploy.sh"
FLEET_ROLLBACK="${SCRIPT_DIR}/rollback-fleet.sh"

log "task=${TASK_ID} initiating soak rollback"

# Prefer per-repo override deploy.sh --rollback
if [[ -x "$OVERRIDE_DEPLOY" ]]; then
  log "delegating to override deploy.sh --rollback: ${OVERRIDE_DEPLOY}"
  LEADV2_TASK_ID="$TASK_ID" LEADV2_PROJECT_ROOT="$LEADV2_PROJECT_ROOT" \
    exec bash "$OVERRIDE_DEPLOY" --rollback
fi

# Fall back to rollback-fleet.sh if present
if [[ -x "$FLEET_ROLLBACK" ]]; then
  log "delegating to rollback-fleet.sh: ${FLEET_ROLLBACK}"
  LEADV2_TASK_ID="$TASK_ID" LEADV2_PROJECT_ROOT="$LEADV2_PROJECT_ROOT" \
    exec bash "$FLEET_ROLLBACK"
fi

# Neither override exists — cannot auto-rollback, caller opens human-needed lane
log_error "no rollback script found (override deploy.sh or rollback-fleet.sh)"
log_error "searched: ${OVERRIDE_DEPLOY}, ${FLEET_ROLLBACK}"
log_error "manual rollback required for task=${TASK_ID}"
exit 1
