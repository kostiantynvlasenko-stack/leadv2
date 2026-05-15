#!/usr/bin/env bash
# Stop hook: triggers compact reminder based on session JSONL size + founder-turn count.
# Real metric: bytes accumulated, not Stop-event count. Lead can burn 500KB in 5 founder turns.
# PO-064: active.yaml reads use 5s cache; LEADV2_HOOK_PROFILE=1 enables timing log.
set -euo pipefail
trap 'echo "[$(basename "$0")] error at line $LINENO" >&2; exit 0' ERR

# ── PO-064: profiling ───────────────────────────────────────────────────────
_HOOK_START_MS=0
if [[ "${LEADV2_HOOK_PROFILE:-0}" == "1" ]]; then
  _HOOK_START_MS=$(python3 -c "import time; print(int(time.time()*1000))" 2>/dev/null || echo 0)
fi
_hook_profile_end() {
  if [[ "${LEADV2_HOOK_PROFILE:-0}" == "1" && "$_HOOK_START_MS" -gt 0 ]]; then
    local end_ms
    end_ms=$(python3 -c "import time; print(int(time.time()*1000))" 2>/dev/null || echo 0)
    local dur=$(( end_ms - _HOOK_START_MS ))
    mkdir -p "$HOME/.claude/state/leadv2"
    printf '%s,%s\n' "leadv2-compact-trigger" "$dur" \
      >> "$HOME/.claude/state/leadv2/hook-profile.log"
  fi
}
trap '_hook_profile_end; exit 0' EXIT

INPUT="$(cat 2>/dev/null || true)"
[[ -z "$INPUT" ]] && exit 0

SESSION_ID="$(echo "$INPUT" | jq -r '.session_id // .session.id // empty' 2>/dev/null || echo "")"
[[ -z "$SESSION_ID" ]] && exit 0
CWD="$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || echo "")"
[[ -z "$CWD" ]] && CWD="$PWD"

# Find the JSONL for this session
PROJECT_HASH="$(echo "$CWD" | sed 's|/|-|g; s|^-||')"
JSONL=""
for d in "$HOME/.claude/projects/-${PROJECT_HASH}" "$HOME/.claude/projects/${PROJECT_HASH}"; do
  if [[ -f "$d/${SESSION_ID}.jsonl" ]]; then
    JSONL="$d/${SESSION_ID}.jsonl"
    break
  fi
done
# Fallback: search by session id across project dirs
if [[ -z "$JSONL" ]]; then
  JSONL="$(find "$HOME/.claude/projects/" -maxdepth 2 -name "${SESSION_ID}.jsonl" -type f 2>/dev/null | head -1)"
fi
[[ -z "$JSONL" ]] && exit 0
[[ ! -f "$JSONL" ]] && exit 0

BYTES=$(wc -c < "$JSONL" | tr -d ' ')
KB=$((BYTES / 1024))
EST_TOKENS=$((BYTES / 4))
EST_K=$((EST_TOKENS / 1000))

# Count founder typed turns (excludes tool_results)
FOUNDER_TURNS=$(python3 -c "
import json
n = 0
for line in open('$JSONL'):
    try:
        r = json.loads(line)
        msg = r.get('message') or {}
        if msg.get('role') != 'user': continue
        c = msg.get('content')
        if isinstance(c, str) and c.strip() and not c.startswith('<'):
            n += 1
        elif isinstance(c, list):
            for p in c:
                if isinstance(p, dict) and p.get('type') == 'text':
                    t = p.get('text','')
                    if t.strip() and not t.startswith('<'):
                        n += 1; break
    except: pass
print(n)
" 2>/dev/null || echo 0)

# Look for active leadv2 task — PO-064: use 5s cache
ACTIVE=""
for f in "$CWD/.claude/leadv2-tasks/active.yaml" "$CWD/docs/leadv2/active.yaml"; do
  [[ -f "$f" ]] && ACTIVE="$f" && break
done
TASK_NOTE=""
if [[ -n "$ACTIVE" ]]; then
  # shellcheck source=/dev/null
  source "$HOME/.claude/hooks/leadv2-active-cache.sh"
  leadv2_read_active_yaml "$ACTIVE"
  TID="${ACTIVE_TASK_ID:-}"
  [[ -n "$TID" ]] && TASK_NOTE=" task=$TID"
fi

# Thresholds — bytes-driven, not turn-count
# 500KB ≈ 125K tokens of conversation prefix (each new turn re-sends this)
# 1.5MB ≈ 375K tokens — every turn now eats serious cap
# 3MB ≈ 750K tokens — emergency

# Throttle: write a marker so we don't re-emit on every Stop after threshold crossed
MARKER="/tmp/.leadv2-compact-warned-${SESSION_ID}"
LEVEL=""
if [[ "$BYTES" -ge 3145728 ]]; then LEVEL="emergency"
elif [[ "$BYTES" -ge 1572864 ]]; then LEVEL="hard"
elif [[ "$BYTES" -ge 524288 ]]; then LEVEL="warn"
elif [[ "$FOUNDER_TURNS" -ge 30 ]]; then LEVEL="long_chat"
fi
[[ -z "$LEVEL" ]] && exit 0

# Emit at most once per level per session
PREV_LEVEL="$(cat "$MARKER" 2>/dev/null || echo "")"
[[ "$LEVEL" == "$PREV_LEVEL" ]] && exit 0
echo "$LEVEL" > "$MARKER"

case "$LEVEL" in
  emergency)
    cat >> "$HOME/.claude/leadv2-compact-trigger.log" <<MSG
[leadv2-compact-trigger] EMERGENCY${TASK_NOTE}
  Session: ${KB}KB ≈ ${EST_K}K tokens prefix per turn (founder typed ${FOUNDER_TURNS}x).
  Each new turn now sends ${EST_K}K input. Daily Opus quota = ~50M.
  ACTION: /compact NOW. Or close session, /clear, resume from STATE.md.
MSG
    ;;
  hard)
    cat >> "$HOME/.claude/leadv2-compact-trigger.log" <<MSG
[leadv2-compact-trigger] HARD${TASK_NOTE}
  Session: ${KB}KB ≈ ${EST_K}K tokens prefix per turn (founder typed ${FOUNDER_TURNS}x).
  /compact at next phase boundary — past this point cost grows fast.
MSG
    ;;
  warn)
    cat >> "$HOME/.claude/leadv2-compact-trigger.log" <<MSG
[leadv2-compact-trigger] WARN${TASK_NOTE}
  Session: ${KB}KB (${EST_K}K tokens prefix). Plan a /compact at next phase boundary.
  Most common cause: lead doing too many tool calls per founder turn (read-everything pattern).
MSG
    ;;
  long_chat)
    cat >> "$HOME/.claude/leadv2-compact-trigger.log" <<MSG
[leadv2-compact-trigger] LONG${TASK_NOTE}
  Founder typed ${FOUNDER_TURNS}x in this session — usually means task should have been split.
  Consider closing this task (Phase 11) and starting fresh for next.
MSG
    ;;
esac
exit 0
