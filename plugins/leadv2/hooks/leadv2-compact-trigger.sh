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

# Count only bytes from last /compact event (not pre-compact history)
LAST_COMPACT_LINE=$(python3 -c "
import json, sys
last = 0
try:
    with open('$JSONL') as fh:
        for i, line in enumerate(fh):
            try:
                r = json.loads(line)
                msg = r.get('message') or {}
                c = msg.get('content', '')
                if isinstance(c, str) and '<command-name>/compact</command-name>' in c:
                    last = i
            except: pass
except: pass
print(last)
" 2>/dev/null || echo 0)
BYTES=$(python3 -c "
import os, sys
with open('$JSONL') as fh:
    lines = fh.readlines()
start = int('$LAST_COMPACT_LINE') if '$LAST_COMPACT_LINE' else 0
print(sum(len(l) for l in lines[start:]))
" 2>/dev/null || wc -c < "$JSONL" | tr -d ' ')
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

# Write to pending-warn file so user-prompt-context.sh delivers it on next turn
PENDING_WARN="$HOME/.claude/leadv2-pending-warn-${SESSION_ID}.txt"

case "$LEVEL" in
  emergency)
    MSG="[COMPACT_NOW] Контекст: ${KB}KB (~${EST_K}K токенов после последнего /compact${TASK_NOTE}). Каждый ход = ${EST_K}K input. Скажи фаундеру одной строкой: 'Нужен /compact — контекст ${EST_K}K токенов.' Потом жди."
    ;;
  hard)
    MSG="[COMPACT_NEEDED] Контекст: ${KB}KB (~${EST_K}K токенов${TASK_NOTE}). На следующей фазовой границе скажи фаундеру: 'Нужен /compact перед следующей фазой.'"
    ;;
  warn)
    MSG="[COMPACT_WARN] Контекст: ${KB}KB (~${EST_K}K токенов${TASK_NOTE}). Упомяни /compact если фаундер спросит о сессии."
    ;;
  long_chat)
    MSG="[LONG_CHAT] Фаундер напечатал ${FOUNDER_TURNS}x в этой сессии."
    ;;
esac

# Append (don't overwrite — other hooks may also write)
echo "$MSG" >> "$PENDING_WARN" 2>/dev/null || true
exit 0
