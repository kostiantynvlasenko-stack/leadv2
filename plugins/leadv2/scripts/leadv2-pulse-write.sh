#!/usr/bin/env bash
# leadv2-pulse-write.sh — Unconditional pulse writer for /leadv2 phase transitions.
#
# Unlike leadv2-pulse.sh (which respects LEADV2_PULSE_MODE=1 guard), this script
# writes pulse.md on every call regardless of LEADV2_PULSE_MODE. Intended to be
# called at every phase boundary so pulse.md is populated for all task classes.
#
# Usage: leadv2-pulse-write.sh <task_id> <phase> <summary>
#
# Output format (one line appended to docs/leadv2/tasks/<task_id>/pulse.md):
#   YYYY-MM-DD HH:MM | <phase> | <summary>
#
# Exit codes:
#   0 — success or soft-fail (pulse must never kill caller)
#
# Called by: leadv2_active_update_phase (via leadv2-active-registry.sh)

set -uo pipefail

TASK_ID="${1:-}"
PHASE="${2:-}"
SUMMARY="${3:-}"

if [[ -z "$TASK_ID" || -z "$PHASE" ]]; then
  printf -- '[leadv2-pulse-write] task_id or phase empty — skipping\n' >&2
  exit 0
fi

PROJECT_ROOT="${LEADV2_PROJECT_ROOT:-${PROJECT_ROOT:-$(pwd)}}"
PULSE_DIR="$PROJECT_ROOT/docs/leadv2/tasks/$TASK_ID"
PULSE_FILE="$PULSE_DIR/pulse.md"

# Create directory if needed — soft fail
mkdir -p "$PULSE_DIR" 2>/dev/null || {
  printf -- '[leadv2-pulse-write] cannot create dir %s, skipping\n' "$PULSE_DIR" >&2
  exit 0
}

# Compute timestamp: YYYY-MM-DD HH:MM (UTC, no seconds for readability)
TS="$(date -u +"%Y-%m-%d %H:%M" 2>/dev/null || python3 -c 'from datetime import datetime,timezone; print(datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M"))' 2>/dev/null || echo "0000-00-00 00:00")"

# Truncate summary to keep total line reasonable (max 120 chars)
MAX_SUMMARY=80
SUMMARY_TRUNC="${SUMMARY:0:$MAX_SUMMARY}"

LINE="${TS} | ${PHASE} | ${SUMMARY_TRUNC}"

# Append to pulse.md — soft fail
printf -- '%s\n' "$LINE" >> "$PULSE_FILE" 2>/dev/null || {
  printf -- '[leadv2-pulse-write] write failed for %s, skipping\n' "$PULSE_FILE" >&2
  exit 0
}

printf -- '%s\n' "$LINE"

# ── checkpoint.md: overwrite with latest phase state (soft-fail) ─────────────
CHECKPOINT_FILE="$PULSE_DIR/checkpoint.md"
{
  CKPT_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "0000-00-00T00:00:00Z")"

  # Last 3 lines of pulse.md
  PULSE_TAIL="$(tail -3 "$PULSE_FILE" 2>/dev/null || true)"

  # Newest file in docs/handoff/<task_id>/ if present
  HANDOFF_DIR="${PROJECT_ROOT}/docs/handoff/${TASK_ID}"
  NEWEST_HANDOFF=""
  if [[ -d "$HANDOFF_DIR" ]]; then
    NEWEST_HANDOFF="$(ls -t "$HANDOFF_DIR" 2>/dev/null | head -1 || true)"
  fi

  printf -- '# checkpoint: %s\n' "$TASK_ID"
  printf -- 'written: %s\n' "$CKPT_TS"
  printf -- 'task_id: %s\n' "$TASK_ID"
  printf -- 'phase: %s\n' "$PHASE"
  printf -- 'newest_handoff: %s\n' "${NEWEST_HANDOFF:-none}"
  printf -- '---\n'
  printf -- '## Last 3 pulse lines\n\n'
  printf -- '%s\n' "$PULSE_TAIL"
} > "$CHECKPOINT_FILE" 2>/dev/null || true

exit 0
