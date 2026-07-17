#!/usr/bin/env bash
# Stop hook: triggers compact reminder based on session JSONL size + founder-turn count.
# Real metric: bytes accumulated, not Stop-event count. Lead can burn 500KB in 5 founder turns.
# PO-064: active.yaml reads use 5s cache; LEADV2_HOOK_PROFILE=1 enables timing log.
set -euo pipefail
export PYTHONWARNINGS="ignore::DeprecationWarning"  # LEAD-ANCHOR-01: never let py warnings hit stderr as a hook error
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
# WAVE-RELIABILITY-01: stop_hook_active — true means THIS Stop event was itself caused by a
# prior decision:block from this same hook. Only consulted by the daemon-mode branch below
# (prevents an infinite block loop); interactive warn path never reads it.
STOP_ACTIVE="$(echo "$INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null || echo "false")"

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
_TOKENS_RESULT=$(python3 -c "
import json, sys

# lean: 'tool_result' and 'thinking' blocks are both stripped/evicted from the
# LIVE context window well before /compact — tool outputs get truncated by the
# harness once aged, and prior-turn thinking blocks are dropped from the
# request the API actually resends (only the latest turn's thinking survives).
# Both persist in full on-disk in the session JSONL forever, so summing them
# uncapped double-counts bytes that are no longer part of what the next API
# call actually sends. Calibrated 2026-07-10 against 4 real transcripts using
# each session's own last-turn usage (cache_read+cache_creation+input) as
# ground truth: capping tool_result alone (2000 chars) only cut the estimate
# ~3-5% because 'thinking' — not tool_result — is the dominant over-counted
# block in real sessions (37-53% of accumulated chars in 3/4 samples). Capping
# BOTH at 1500 chars brought worst-case ratio from 1.55x down to 1.39x anchor
# (others landed 0.82x-1.05x) — good enough for a WARN-only, non-blocking
# threshold. Biased slightly toward over- rather than under-estimating since
# under-estimating risks a missed/late warning; over-estimating just nags
# early, which is the safe failure mode here.
# upgrade when Stop-hook payload exposes a real token/context_window field —
# then prefer that over any text-based estimate (see 1c in the fix ladder).
CAPPED_BLOCK_CHAR_CAP = 1500  # ~375 tokens; applies to tool_result + thinking subtrees

def is_image(obj):
    if not isinstance(obj, dict):
        return False
    t = obj.get('type','')
    if t in ('image','image_url'):
        return True
    if 'source' in obj and isinstance(obj.get('source'), dict) and 'data' in obj['source']:
        return True
    return False

def is_capped_block(obj):
    return isinstance(obj, dict) and obj.get('type') in ('tool_result', 'thinking')

def walk(obj):
    text_chars = 0
    image_count = 0
    if isinstance(obj, dict):
        if is_image(obj):
            image_count += 1
            src = obj.get('source', {})
            for k, v in obj.items():
                if k == 'source':
                    for sk, sv in (src.items() if isinstance(src, dict) else []):
                        if sk == 'data':
                            continue
                        tc, ic = walk(sv)
                        text_chars += tc; image_count += ic
                else:
                    tc, ic = walk(v)
                    text_chars += tc; image_count += ic
        elif is_capped_block(obj):
            # Walk the subtree uncapped to get its true size, then cap the
            # contribution — only a bounded portion of an aged tool_result or
            # a prior-turn thinking block realistically remains resident.
            tc, ic = 0, 0
            for k, v in obj.items():
                if k == 'type':
                    continue
                sub_tc, sub_ic = walk(v)
                tc += sub_tc; ic += sub_ic
            text_chars += min(tc, CAPPED_BLOCK_CHAR_CAP)
            image_count += ic
        else:
            for k, v in obj.items():
                tc, ic = walk(v)
                text_chars += tc; image_count += ic
    elif isinstance(obj, list):
        for item in obj:
            tc, ic = walk(item)
            text_chars += tc; image_count += ic
    elif isinstance(obj, str):
        text_chars += len(obj)
    return text_chars, image_count

try:
    with open('$JSONL') as fh:
        lines = fh.readlines()
    start = int('$LAST_COMPACT_LINE') if '$LAST_COMPACT_LINE' else 0
    raw_bytes = sum(len(l) for l in lines[start:])
    text_chars = 0
    image_count = 0
    for line in lines[start:]:
        try:
            obj = json.loads(line)
            tc, ic = walk(obj)
            text_chars += tc; image_count += ic
        except:
            pass
    est_tokens = int(text_chars / 4) + image_count * 1500
    print(raw_bytes, est_tokens)
except Exception:
    import os
    size = os.path.getsize('$JSONL')
    print(size, size // 4)
" 2>/dev/null || echo "0 0")
_RAW_BYTES=$(echo "$_TOKENS_RESULT" | awk '{print $1}')
_EST_TOKENS=$(echo "$_TOKENS_RESULT" | awk '{print $2}')
BYTES=${_RAW_BYTES:-0}
KB=$((BYTES / 1024))
EST_TOKENS=${_EST_TOKENS:-0}
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
  HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [[ -f "$HOOK_DIR/leadv2-active-cache.sh" ]]; then
    source "$HOOK_DIR/leadv2-active-cache.sh"
  elif [[ -f "$HOME/.claude/hooks/leadv2-active-cache.sh" ]]; then
    source "$HOME/.claude/hooks/leadv2-active-cache.sh"
  else
    # NB3: neither active-cache.sh path found — task note will be empty; observable via debug log
    printf '[leadv2-compact-trigger] debug: leadv2-active-cache.sh not found in %s or %s — task note skipped\n' "$HOOK_DIR" "$HOME/.claude/hooks" >&2
  fi
  if declare -f leadv2_read_active_yaml >/dev/null 2>&1; then
    leadv2_read_active_yaml "$ACTIVE"
  fi
  TID="${ACTIVE_TASK_ID:-}"
  [[ -n "$TID" ]] && TASK_NOTE=" task=$TID"
fi

# Thresholds — token-driven, image-corrected (EST_TOKENS not raw bytes).
# Override via env: LEADV2_COMPACT_WARN_TOKENS / HARD / EMERGENCY.
# Defaults: 200K warn, 400K hard, 650K emergency.
# Raw file KB is still shown for display; level decision uses EST_TOKENS.
WARN_T="${LEADV2_COMPACT_WARN_TOKENS:-200000}"
HARD_T="${LEADV2_COMPACT_HARD_TOKENS:-400000}"
EMERG_T="${LEADV2_COMPACT_EMERGENCY_TOKENS:-650000}"

# Throttle: write a marker so we don't re-emit on every Stop after threshold crossed
MARKER="/tmp/.leadv2-compact-warned-${SESSION_ID}"
LEVEL=""
if [[ "$EST_TOKENS" -ge "$EMERG_T" ]]; then LEVEL="emergency"
elif [[ "$EST_TOKENS" -ge "$HARD_T" ]]; then LEVEL="hard"
elif [[ "$EST_TOKENS" -ge "$WARN_T" ]]; then LEVEL="warn"
elif [[ "$FOUNDER_TURNS" -ge 30 ]]; then LEVEL="long_chat"
fi
[[ -z "$LEVEL" ]] && exit 0

# ── WAVE-RELIABILITY-01: daemon-mode branch — FORCE /compact instead of dead-letter warn ──
# WHY: in a `/goal` daemon loop (LEADV2_DAEMON=1), turn continuation is driven entirely by
# THIS Stop hook (see leadv2-self-spawn.sh) — there is no UserPromptSubmit event mid-loop,
# so the interactive warn path below (writes leadv2-pending-warn-<session>.txt, delivered
# only by leadv2-user-prompt-context.sh on the next UserPromptSubmit) never fires: written,
# never read. "Tell the founder" is also moot — nobody is watching an unattended child.
#
# Mechanism: decision:"block" prevents Claude Code from stopping and re-injects `reason` as
# the next turn's content — the exact continuation channel /goal itself already relies on to
# self-drive turn after turn with no new shell invocation. Setting reason to the literal
# string "/compact" mirrors a real user submitting that slash command — the only lever a
# headless (-p, no tty) hook has to force compaction programmatically.
# lean: not live-verified against a real daemon run collapsing token count (would spend a
# real fanout child's context to prove) — upgrade when a session JSONL shows a hook-forced
# /compact actually firing in a live daemon child; until then this is the plan's documented
# "or equivalent programmatic compact trigger" fallback (WAVE-RELIABILITY-PLAN-01 step 2).
#
# HUMAN-PRESENCE GATE (COMPACT-FORCED-ON-HUMAN-01): LEADV2_DAEMON is set repo-wide in some
# settings.json, so an interactive founder session is indistinguishable from a daemon child
# by env alone — env read daemon=1 even as FOUNDER_TURNS was 73. A session where a human has
# actually typed is NOT a daemon, whatever the env says. FOUNDER_TURNS > 0 ⇒ fall through to
# the interactive pending-warn path (tell the lead to MENTION compact) and NEVER emit a
# decision:block / forged "/compact" — that arrives as a real user turn the lead obeys.
# LEADV2_NO_FORCE_COMPACT=1 is a hard kill-switch that disables forcing unconditionally.
#
# Guards: only real token thresholds (never "long_chat", which has no compact-relevant
# signal); only when NO human is present (FOUNDER_TURNS -eq 0); kill-switch unset; skips
# entirely when stop_hook_active=true (this Stop event was itself caused by our own prior
# block — blocking again would loop forever); one-shot per level via the same MARKER file the
# interactive path uses below (so daemon and interactive never double-fire for the same level
# if a session flips modes).
# INTERACTIVE PATH BELOW THIS BLOCK IS UNTOUCHED.
if [[ "${LEADV2_DAEMON:-0}" == "1" \
   && "${LEADV2_NO_FORCE_COMPACT:-0}" != "1" \
   && "$FOUNDER_TURNS" -eq 0 \
   && "$LEVEL" != "long_chat" \
   && "$STOP_ACTIVE" != "true" ]]; then
  DAEMON_PREV_LEVEL="$(cat "$MARKER" 2>/dev/null || echo "")"
  if [[ "$LEVEL" != "$DAEMON_PREV_LEVEL" ]]; then
    echo "$LEVEL" > "$MARKER" 2>/dev/null || true
    printf '%s\n' '{"decision":"block","reason":"/compact"}'
  fi
  exit 0
fi

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
