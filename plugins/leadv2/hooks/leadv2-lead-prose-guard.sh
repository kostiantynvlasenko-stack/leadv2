#!/usr/bin/env bash
# Stop hook — pulse-mode HARD clamp on assistant prose.
# Sums ALL text blocks in the turn (not just last).
# Phase caps: intake/classify/build/deploy/verify=80, review=100, plan=150, close=120.
# Tool-use turns: 60% of cap.
# Blocks AT MOST ONCE per turn (corrective message), then passes through — no deadlock.

set -euo pipefail
trap 'echo "[$(basename "$0")] error at line $LINENO" >&2; exit 0' ERR

# Only when /leadv2 active (skip routine chat)
[[ "${LEADV2_LEAD_GUARD:-0}" == "1" ]] || exit 0

# Resolve leadv2_dir from state-paths.yaml (fallback: docs/leadv2)
_lv2_sp_root="${CLAUDE_PROJECT_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
_lv2_sp_yaml="${_lv2_sp_root}/.claude/leadv2-overrides/state-paths.yaml"
_lv2_leadv2_dir=$(grep -E "^[[:space:]]*leadv2_dir[[:space:]]*:" "$_lv2_sp_yaml" 2>/dev/null | head -1 | sed -E "s/^[[:space:]]*leadv2_dir[[:space:]]*:[[:space:]]*//" | sed -E "s/^['\"]//; s/['\"][[:space:]]*$//" | tr -d '\r' || true)
[[ -z "$_lv2_leadv2_dir" || "$_lv2_leadv2_dir" == "null" || "$_lv2_leadv2_dir" == "~" ]] && _lv2_leadv2_dir="docs/leadv2"
# Liveness gate: only fire when active.yaml has a session with a live pid
ACTIVE_YAML=""
for candidate in "$PWD/${_lv2_leadv2_dir}/active.yaml" \
                 "${_lv2_sp_root}/${_lv2_leadv2_dir}/active.yaml"; do
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

# Pulse-mode phase caps (tight)
case "${LEADV2_PHASE:-}" in
  intake|classify) PHASE_CAP=80  ;;
  plan)            PHASE_CAP=150 ;;
  build)           PHASE_CAP=80  ;;
  review)          PHASE_CAP=100 ;;
  deploy|verify)   PHASE_CAP=80  ;;
  close)           PHASE_CAP=120 ;;
  *)               PHASE_CAP=80  ;;
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

# Sum ALL text blocks in the turn; detect tool_use presence
PARSE_OUT="$(python3 - "$JSONL" <<'PYEOF' 2>/dev/null || true
import sys, json

jsonl_path = sys.argv[1]
last_turn_text_parts = []
last_turn_has_tool = False
last_turn_found = False

with open(jsonl_path) as f:
    for line in f:
        try:
            r = json.loads(line)
            if r.get('type') == 'assistant':
                m = r.get('message', {})
                content = m.get('content', [])
                if isinstance(content, list):
                    text_parts = [c.get('text', '') for c in content if c.get('type') == 'text']
                    has_tool = any(c.get('type') == 'tool_use' for c in content)
                    last_turn_text_parts = text_parts
                    last_turn_has_tool = has_tool
                    last_turn_found = True
        except Exception:
            continue

if last_turn_found:
    print(f'TOOL={1 if last_turn_has_tool else 0}')
    print('TEXT_START')
    print('\n'.join(last_turn_text_parts))
PYEOF
)"

[[ -z "$PARSE_OUT" ]] && exit 0

HAS_TOOL="$(printf '%s' "$PARSE_OUT" | grep -E '^TOOL=' | head -1 | sed 's/TOOL=//')"
TEXT_BODY="$(printf '%s' "$PARSE_OUT" | awk '/^TEXT_START$/{f=1; next} f')"
WORD_COUNT=$(printf '%s' "$TEXT_BODY" | wc -w | tr -d ' ')

# Apply 60% cap when tool_use present in turn
THRESHOLD="$PHASE_CAP"
if [[ "${HAS_TOOL:-0}" == "1" ]]; then
  THRESHOLD=$(( PHASE_CAP * 60 / 100 ))
fi

if [[ "$WORD_COUNT" -le "$THRESHOLD" ]]; then
  rm -f "$HOME/.claude/leadv2-prose-retry-${SESSION_ID}.txt" 2>/dev/null || true
  exit 0
fi

# Log violation
LOG="$HOME/.claude/leadv2-prose-violations.log"
printf '%s session=%s words=%s threshold=%s has_tool=%s phase=%s\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$SESSION_ID" "$WORD_COUNT" "$THRESHOLD" \
  "${HAS_TOOL:-0}" "${LEADV2_PHASE:-}" >> "$LOG" 2>/dev/null || true

# Block AT MOST ONCE per turn: check retry counter
RETRY_FILE="$HOME/.claude/leadv2-prose-retry-${SESSION_ID}.txt"
RETRY_COUNT=0
if [[ -f "$RETRY_FILE" ]]; then
  RETRY_COUNT=$(tr -d '[:space:]' < "$RETRY_FILE" 2>/dev/null || true)
  RETRY_COUNT="${RETRY_COUNT:-0}"
fi

if [[ "$RETRY_COUNT" -ge 1 ]]; then
  # Already blocked once this turn — pass through to avoid deadlock
  rm -f "$RETRY_FILE"
  exit 0
fi
printf '1\n' > "$RETRY_FILE"

# Block with corrective message (once only)
python3 - "$WORD_COUNT" "$THRESHOLD" "$PHASE_CAP" "${LEADV2_PHASE:-}" <<'PYEOF2'
import sys, json
wc, th, cap, phase = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
print(json.dumps({
    'continue': False,
    'stopReason': (
        f'Pulse only: emit a ≤80-word pulse line; move detail to a deliverable file. '
        f'No reasoning narration. '
        f'({wc} words, limit {th} [{phase} cap={cap}])'
    )
}))
PYEOF2
exit 0
