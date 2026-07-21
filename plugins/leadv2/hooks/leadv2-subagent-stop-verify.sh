#!/usr/bin/env bash
# SubagentStop hook: verify subagent wrote a deliverable file with DELIVERABLE_COMPLETE marker.
# Also enforces terse final message: ≤50 words, no reasoning-dump patterns.
# Soft mode by default — emits warning. Strict via LEADV2_SUBAGENT_VERIFY_STRICT=1 → blocks Stop.
# Terse enforcement is always strict (blocks once, then passes through).
set -euo pipefail
trap 'echo "[$(basename "$0")] error at line $LINENO" >&2; exit 0' ERR

INPUT="$(cat 2>/dev/null || true)"
[[ -z "$INPUT" ]] && exit 0

# shellcheck source=leadv2-mode-isolation.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/leadv2-mode-isolation.sh"
leadv2_hook_is_supervisor_session "$INPUT" && exit 0

CWD="$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || echo "")"
[[ -z "$CWD" ]] && CWD="$PWD"
SESSION_ID="$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || echo "")"

# Find any active task's handoff dir
ACTIVE=""
for f in "$CWD/.claude/leadv2-tasks/active.yaml" "$CWD/docs/leadv2/active.yaml"; do
  [[ -f "$f" ]] && ACTIVE="$f" && break
done
[[ -z "$ACTIVE" ]] && exit 0

TASK_ID="$(leadv2_hook_resolve_task_id "$INPUT" "$ACTIVE" 2>/dev/null || true)"
[[ -z "$TASK_ID" ]] && exit 0

# Look for any .md deliverable in handoff dir modified within last 60s
HANDOFF_DIRS=(
  "$CWD/docs/handoff/$TASK_ID"
  "$CWD/.claude/leadv2-tasks/$TASK_ID"
)
HAS_RECENT=0
HAS_MARKER=0
for hd in "${HANDOFF_DIRS[@]}"; do
  [[ -d "$hd" ]] || continue
  while IFS= read -r -d '' f; do
    HAS_RECENT=1
    if tail -5 "$f" 2>/dev/null | grep -q 'DELIVERABLE_COMPLETE'; then
      HAS_MARKER=1
      break
    fi
  done < <(find "$hd" -maxdepth 2 -name '*.md' -mmin -1 -type f -print0 2>/dev/null)
  [[ "$HAS_MARKER" -eq 1 ]] && break
done

# If recent file exists but no marker → soft warn (or strict block)
if [[ "$HAS_RECENT" -eq 1 && "$HAS_MARKER" -eq 0 ]]; then
  if [[ "${LEADV2_SUBAGENT_VERIFY_STRICT:-0}" == "1" ]]; then
    jq -n '{
      decision: "block",
      reason: "Subagent wrote a deliverable but did not end with DELIVERABLE_COMPLETE marker. Add it before stopping so lead can verify completion."
    }'
    exit 0
  fi
  printf '[leadv2-subagent-stop-verify] WARN: deliverable written without DELIVERABLE_COMPLETE marker (task=%s)\n' "$TASK_ID" >&2
fi

# ── Terse final-message enforcement ──────────────────────────────────────────
# Check subagent's final assistant message: ≤50 words + no reasoning-dump.
# Blocks once (per session), then passes through to avoid deadlock.
if [[ -n "$SESSION_ID" ]]; then
  JSONL="$(python3 -c "
import os, glob
for p in glob.glob(os.path.expanduser('~/.claude/projects/*/${SESSION_ID}.jsonl')):
    print(p); break
" 2>/dev/null || true)"

  if [[ -n "$JSONL" && -f "$JSONL" ]]; then
    TERSE_CHECK="$(python3 - "$JSONL" <<'PYEOF' 2>/dev/null || true
import sys, json, re

jsonl_path = sys.argv[1]
last_text = ""
with open(jsonl_path) as f:
    for line in f:
        try:
            r = json.loads(line)
            if r.get('type') == 'assistant':
                m = r.get('message', {})
                content = m.get('content', [])
                if isinstance(content, list):
                    parts = [c.get('text', '') for c in content if c.get('type') == 'text']
                    last_text = '\n'.join(parts)
        except Exception:
            continue

if not last_text.strip():
    print('OK')
    sys.exit(0)

word_count = len(last_text.split())

# Reasoning-dump patterns: multi-paragraph prose OR leading narration phrases
paragraphs = [p.strip() for p in last_text.split('\n\n') if p.strip()]
is_multi_para = len(paragraphs) > 2

NARRATION_RE = re.compile(
    r'^(let me|first,?\s+i|now i\s+will|i\s+will\s+now|i\s+need\s+to|to\s+accomplish)',
    re.IGNORECASE
)
has_narration = bool(NARRATION_RE.match(last_text.lstrip()))

if word_count > 50:
    print(f'WORD_OVER:{word_count}')
elif is_multi_para and has_narration:
    print(f'REASONING_DUMP:{word_count}')
else:
    print('OK')
PYEOF
)"

    TERSE_RETRY_FILE="$HOME/.claude/leadv2-subagent-terse-retry-${SESSION_ID}.txt"
    TERSE_ALREADY_BLOCKED=0
    if [[ -f "$TERSE_RETRY_FILE" ]]; then
      TERSE_ALREADY_BLOCKED=1
    fi

    if [[ "$TERSE_CHECK" == WORD_OVER:* || "$TERSE_CHECK" == REASONING_DUMP:* ]]; then
      if [[ "$TERSE_ALREADY_BLOCKED" -eq 0 ]]; then
        touch "$TERSE_RETRY_FILE"
        WORD_N="${TERSE_CHECK#*:}"
        jq -n --arg wc "$WORD_N" --arg reason "$TERSE_CHECK" '{
          decision: "block",
          reason: ("Subagent final message is too verbose (" + $reason + "). Final message must be ≤50 words with no reasoning narration (no multi-paragraph prose, no \"Let me\"/\"First, I\"/\"Now I will\" preamble). Emit ONE line: verdict + deliverable path.")
        }'
        exit 0
      else
        # Already blocked once — pass through
        rm -f "$TERSE_RETRY_FILE"
      fi
    else
      # Clean run — clear any leftover retry file
      rm -f "$TERSE_RETRY_FILE" 2>/dev/null || true
    fi
  fi
fi

exit 0
