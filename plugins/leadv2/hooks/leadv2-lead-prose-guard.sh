#!/usr/bin/env bash
# Stop hook — count words in last assistant message. If >100 prose words AND no tool_use,
# log violation + emit additionalContext warning for next turn (self-correction).
#
# Doesn't block — Stop hooks can't unsend output. Goal: train lead to be tool-only.

set -euo pipefail
trap 'echo "[$(basename "$0")] error at line $LINENO" >&2; exit 0' ERR

# Only when /leadv2 active (skip routine chat)
[[ "${LEADV2_LEAD_GUARD:-0}" == "1" ]] || exit 0

# Liveness gate: only fire when active.yaml has a session with a live pid
ACTIVE_YAML=""
for candidate in "$PWD/docs/leadv2/active.yaml" \
                 "/Users/kostiantyn.vlasenko/Projects/persona-engine/docs/leadv2/active.yaml"; do
  [[ -f "$candidate" ]] && ACTIVE_YAML="$candidate" && break
done
if [[ -n "$ACTIVE_YAML" ]]; then
  ACTIVE_OUT=$(python3 -c "
import yaml, sys, os
d = yaml.safe_load(open(sys.argv[1])) or {}
for sess in (d.get('sessions') or []):
    pid = sess.get('pid')
    if not pid: continue
    try:
        os.kill(int(pid), 0)
        print(sess.get('phase','')); break
    except (OSError, ValueError):
        pass
" "$ACTIVE_YAML" 2>/dev/null || true)
  [[ -n "$ACTIVE_OUT" ]] || exit 0
  LEADV2_PHASE="$ACTIVE_OUT"
else
  exit 0
fi

# Phase-aware threshold (cleared by-phase ceiling; still has tool/no-tool distinction)
case "${LEADV2_PHASE:-}" in
  intake|classify) PHASE_CAP=300 ;;
  plan)            PHASE_CAP=600 ;;
  build)           PHASE_CAP=350 ;;
  review)          PHASE_CAP=400 ;;
  deploy|verify)   PHASE_CAP=250 ;;
  close)           PHASE_CAP=200 ;;
  *)               PHASE_CAP=300 ;;
esac

INPUT="$(cat 2>/dev/null || true)"
[[ -z "$INPUT" ]] && exit 0

SESSION_ID="$(printf '%s' "$INPUT" | python3 -c "
import sys, json
try:
    r = json.loads(sys.stdin.read())
    print(r.get('session_id',''))
except Exception:
    pass
" 2>/dev/null || true)"

[[ -z "$SESSION_ID" ]] && exit 0

JSONL="$(python3 -c "
import os, glob
for p in glob.glob(os.path.expanduser('~/.claude/projects/*/${SESSION_ID}.jsonl')):
    print(p); break
" 2>/dev/null || true)"

[[ -z "$JSONL" || ! -f "$JSONL" ]] && exit 0

# Get last assistant message
LAST_TEXT="$(python3 -c "
import json
last = None
with open('$JSONL') as f:
    for line in f:
        try:
            r = json.loads(line)
            if r.get('type') == 'assistant':
                m = r.get('message', {})
                content = m.get('content', [])
                if isinstance(content, list):
                    text_parts = [c.get('text','') for c in content if c.get('type') == 'text']
                    has_tool = any(c.get('type') == 'tool_use' for c in content)
                    last = ('\\n'.join(text_parts), has_tool)
        except Exception:
            continue
if last:
    text, has_tool = last
    print(f'TOOL={1 if has_tool else 0}')
    print('TEXT_START')
    print(text)
" 2>/dev/null || true)"

[[ -z "$LAST_TEXT" ]] && exit 0

HAS_TOOL="$(echo "$LAST_TEXT" | grep -E '^TOOL=' | head -1 | sed 's/TOOL=//')"
TEXT_BODY="$(echo "$LAST_TEXT" | awk '/^TEXT_START$/{f=1; next} f' | head -200)"
WORD_COUNT=$(echo "$TEXT_BODY" | wc -w | tr -d ' ')

# Threshold: phase-aware cap, with tool_use turns getting 60% of phase cap
THRESHOLD="$PHASE_CAP"
[[ "$HAS_TOOL" == "1" ]] && THRESHOLD=$(( PHASE_CAP * 60 / 100 ))

if [[ "$WORD_COUNT" -le "$THRESHOLD" ]]; then exit 0; fi

# Log violation
LOG="$HOME/.claude/leadv2-prose-violations.log"
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) session=$SESSION_ID words=$WORD_COUNT threshold=$THRESHOLD has_tool=$HAS_TOOL" >> "$LOG"

# Retry guard: max 2 blocks per stop, then let through (avoid infinite loop)
RETRY_FILE="$HOME/.claude/leadv2-prose-retry-${SESSION_ID}.txt"
RETRY_COUNT=0
if [[ -f "$RETRY_FILE" ]]; then
  RETRY_COUNT=$(tr -d '[:space:]' < "$RETRY_FILE" 2>/dev/null || true)
  RETRY_COUNT="${RETRY_COUNT:-0}"
fi

if [[ "$RETRY_COUNT" -ge 2 ]]; then
  rm -f "$RETRY_FILE"
  exit 0
fi
printf '%d\n' $(( RETRY_COUNT + 1 )) > "$RETRY_FILE"

# Emit continue:false to force retry
if [[ "$WORD_COUNT" -gt "$THRESHOLD" ]]; then
  python3 - "$WORD_COUNT" "$THRESHOLD" <<'PYEOF2'
import sys, json
wc, th = sys.argv[1], sys.argv[2]
print(json.dumps({
    'continue': False,
    'stopReason': 'PROSE_GUARD: ' + wc + ' words (limit ' + th + '). Tighten or use tool calls.'
}))
PYEOF2
  exit 0
fi

# Stop hooks cannot inject additionalContext (schema-invalid).
# Write warning to per-session file; user-prompt-context.sh picks it up next turn.
WARN_FILE="$HOME/.claude/leadv2-pending-warn-${SESSION_ID}.txt"
echo "[leadv2-lead-prose-guard] Last response had $WORD_COUNT words of prose (limit $THRESHOLD). Lead's job is dispatch, not narration. Next response: tool calls only OR ≤30 words ack." > "$WARN_FILE"
exit 0
