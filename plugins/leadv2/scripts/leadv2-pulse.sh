#!/usr/bin/env bash
# leadv2-pulse.sh — standalone pulse writer for /leadv2 orchestrator.
# Usage: leadv2-pulse.sh <task_id> <phase> <text>
# Writes 1 line <=80 bytes to docs/leadv2/tasks/<task_id>/pulse.md
# Honors LEADV2_PULSE_MODE=1 guard (no-op if 0 or unset).
#
# Exit codes:
#   0 — success (or pulse disabled: LEADV2_PULSE_MODE != 1)
#   Note: failures inside the script are suppressed; pulse must never kill caller.

set -uo pipefail

# Guard: no-op when pulse mode not enabled
[[ "${LEADV2_PULSE_MODE:-1}" == "1" ]] || exit 0  # default ON for fresh installs

usage() {
  printf -- 'Usage: leadv2-pulse.sh <task_id> <phase> <text>\n' >&2
  exit 0  # soft exit — pulse must never kill caller
}

[[ $# -lt 3 ]] && usage

TASK_ID="$1"
PHASE="$2"
TEXT="$3"

# Validate task_id is non-empty
if [[ -z "$TASK_ID" ]]; then
  printf -- '[leadv2-pulse] task_id empty, skipping\n' >&2
  exit 0
fi

# Anchor to project root (prefer exported env var, fallback to cwd)
PROJECT_ROOT="${LEADV2_PROJECT_ROOT:-${PROJECT_ROOT:-$(pwd)}}"
PULSE_DIR="$PROJECT_ROOT/docs/leadv2/tasks/$TASK_ID"
PULSE_FILE="$PULSE_DIR/pulse.md"

# Create directory if needed — soft fail
mkdir -p "$PULSE_DIR" 2>/dev/null || {
  printf -- '[leadv2-pulse] cannot create dir %s, skipping\n' "$PULSE_DIR" >&2
  exit 0
}

# Compute ISO-8601 timestamp with milliseconds.
# gnu date supports %3N; macOS date does not.
# Fall back to python3 (always available in this project), then plain seconds.
if ts="$(python3 -c 'from datetime import datetime,timezone; print(datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.") + f"{datetime.now(timezone.utc).microsecond//1000:03d}Z")' 2>/dev/null)"; then
  : # python3 succeeded
elif ts="$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ" 2>/dev/null)" && [[ "$ts" != *3NZ ]]; then
  : # gnu date with %3N succeeded (Linux)
else
  ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"  # plain seconds fallback
fi

# Compute prefix: [YYYY-MM-DDTHH:MM:SS.mmmZ] <phase> |
printf -v prefix '[%s] %s | ' "$ts" "$PHASE"

# Budget: total line length <= 80 bytes
body_budget=$(( 80 - ${#prefix} ))
# Enforce minimum body of 10 chars so we always emit something meaningful
if [[ $body_budget -lt 10 ]]; then
  body_budget=10
fi

# Truncate text to budget
body="${TEXT:0:$body_budget}"

LINE="${prefix}${body}"

# Append to pulse.md (soft fail — pulse must never kill caller)
printf -- '%s\n' "$LINE" >> "$PULSE_FILE" 2>/dev/null || {
  printf -- '[leadv2-pulse] write failed for %s, skipping\n' "$PULSE_FILE" >&2
  exit 0
}

# Echo line to stdout so lead can pipe to chat
printf -- '%s\n' "$LINE"

exit 0
