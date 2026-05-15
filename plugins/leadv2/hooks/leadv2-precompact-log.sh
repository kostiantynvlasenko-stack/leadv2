#!/usr/bin/env bash
# PreCompact + PostCompact hook: log every compaction event for audit + metrics.
# Symlinked or invoked from both PreCompact and PostCompact in settings.json.
set -euo pipefail
trap 'echo "[$(basename "$0")] error at line $LINENO" >&2; exit 0' ERR

INPUT="$(cat 2>/dev/null || true)"
[[ -z "$INPUT" ]] && exit 0

EVENT="$(echo "$INPUT" | jq -r '.hook_event_name // empty' 2>/dev/null || echo "?")"
SESSION_ID="$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || echo "?")"
TRIGGER="$(echo "$INPUT" | jq -r '.trigger // empty' 2>/dev/null || echo "?")"
CWD="$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || echo "?")"

LOG="$HOME/.claude/leadv2-compact-log.jsonl"
mkdir -p "$(dirname "$LOG")"

# Find JSONL size at this moment
JSONL="$(find "$HOME/.claude/projects/" -maxdepth 2 -name "${SESSION_ID}.jsonl" -type f 2>/dev/null | head -1)"
SIZE=0
[[ -f "$JSONL" ]] && SIZE=$(wc -c < "$JSONL" | tr -d ' ')

# Reset bloat-warned marker on PostCompact (so warnings can fire again as session re-grows)
if [[ "$EVENT" == "PostCompact" ]]; then
  rm -f "/tmp/.leadv2-compact-warned-${SESSION_ID}"
fi

jq -n \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg event "$EVENT" \
  --arg session "$SESSION_ID" \
  --arg trigger "$TRIGGER" \
  --arg cwd "$CWD" \
  --argjson size "$SIZE" \
  '{ts:$ts, event:$event, session:$session, trigger:$trigger, cwd:$cwd, jsonl_bytes:$size}' \
  >> "$LOG"

exit 0
