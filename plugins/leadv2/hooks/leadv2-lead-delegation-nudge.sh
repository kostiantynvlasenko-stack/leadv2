#!/usr/bin/env bash
# PostToolUse hook: warn when lead session makes too many direct tool calls without delegating.
# Tracks consecutive Bash+Read calls without an Agent call (streak counter).
# Only fires in the main lead session — not inside */subagents/* transcript paths.
# Does NOT block. Emits warning to stderr only.
set -euo pipefail
trap 'exit 0' ERR

INPUT="$(cat 2>/dev/null || true)"
[[ -z "$INPUT" ]] && exit 0

# Determine tool name from hook input
TOOL_NAME="$(printf -- '%s' "$INPUT" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print((d.get('tool_name') or d.get('tool') or '').strip())
except Exception:
    pass
" 2>/dev/null || true)"

[[ -z "$TOOL_NAME" ]] && exit 0

# Only care about Bash, Read, Agent
case "$TOOL_NAME" in
  Bash|Read|Agent) ;;
  *) exit 0 ;;
esac

# Check transcript_path — skip if we're inside a subagent session
TRANSCRIPT_PATH="$(printf -- '%s' "$INPUT" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print((d.get('transcript_path') or '').strip())
except Exception:
    pass
" 2>/dev/null || true)"

if [[ "$TRANSCRIPT_PATH" == *"/subagents/"* ]]; then
    exit 0
fi

# Extract session_id for state file
SESSION_ID="$(printf -- '%s' "$INPUT" | python3 -c "
import sys, json, os
try:
    d = json.load(sys.stdin)
    sid = d.get('session_id') or ''
    if not sid and d.get('transcript_path'):
        sid = os.path.splitext(os.path.basename(d['transcript_path']))[0]
    print(sid.strip())
except Exception:
    pass
" 2>/dev/null || true)"

[[ -z "$SESSION_ID" ]] && SESSION_ID="default"

# Sanitize session_id
SAFE_SID="$(printf -- '%s' "$SESSION_ID" | tr -cd 'A-Za-z0-9._-')"
[[ -z "$SAFE_SID" ]] && SAFE_SID="default"

STATE_DIR="$HOME/.claude/state/leadv2"
mkdir -p "$STATE_DIR"
STREAK_FILE="${STATE_DIR}/${SAFE_SID}.lead-streak"

if [[ "$TOOL_NAME" == "Agent" ]]; then
    # Reset streak on any Agent call
    printf '0\n' > "$STREAK_FILE"
    exit 0
fi

# Bash or Read — increment streak
CURRENT=0
if [[ -f "$STREAK_FILE" ]]; then
    CURRENT="$(cat "$STREAK_FILE" 2>/dev/null || printf '0')"
    CURRENT="${CURRENT//[^0-9]/}"
    [[ -z "$CURRENT" ]] && CURRENT=0
fi

CURRENT=$(( CURRENT + 1 ))
printf '%d\n' "$CURRENT" > "$STREAK_FILE"

if [[ "$CURRENT" -ge 6 ]]; then
    printf '[leadv2-lead-delegation-nudge] lead has done %d direct tool calls without delegation — Opus pre-delegation budget = 3-4. Spawn Agent(developer/Explore) now.\n' "$CURRENT" >&2
fi

exit 0
