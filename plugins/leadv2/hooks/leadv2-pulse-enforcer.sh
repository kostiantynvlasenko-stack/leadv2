#!/usr/bin/env bash
# UserPromptSubmit hook — ADVISORY pulse-mode word-count warner.
# Emits a warning via additionalContext when lead's last assistant turn exceeds
# the phase word budget.  ADVISORY ONLY: never returns continue:false, never
# blocks or silences the session (founder decision: pulse silence is advisory).
# Retry guard and continue:false logic removed — exit 0 always.
# Self-contained: no external Python helper files.
# PO-064: active.yaml reads use 5s cache; LEADV2_HOOK_PROFILE=1 enables timing log.

set -euo pipefail
trap 'echo "[$(basename "$0")] error at line $LINENO" >&2; exit 0' ERR

# ── PO-064: profiling start ─────────────────────────────────────────────────
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
    printf '%s,%s\n' "leadv2-pulse-enforcer" "$dur" \
      >> "$HOME/.claude/state/leadv2/hook-profile.log"
  fi
}
trap '_hook_profile_end; exit 0' EXIT

[[ "${LEADV2_LEAD_GUARD:-0}" == "1" ]] || exit 0
# Resolve leadv2_dir from state-paths.yaml (fallback: docs/leadv2)
_lv2_sp_root="${CLAUDE_PROJECT_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
_lv2_sp_yaml="${_lv2_sp_root}/.claude/leadv2-overrides/state-paths.yaml"
_lv2_leadv2_dir=$(grep -E "^[[:space:]]*leadv2_dir[[:space:]]*:" "$_lv2_sp_yaml" 2>/dev/null | head -1 | sed -E "s/^[[:space:]]*leadv2_dir[[:space:]]*:[[:space:]]*//" | sed -E "s/^['\"]//; s/['\"][[:space:]]*$//" | tr -d '\r' || true)
[[ -z "$_lv2_leadv2_dir" || "$_lv2_leadv2_dir" == "null" || "$_lv2_leadv2_dir" == "~" ]] && _lv2_leadv2_dir="docs/leadv2"
# LEADV2_TASK_ID is not exported to hook env — derive from active.yaml
if [[ -z "${LEADV2_TASK_ID:-}" ]]; then
  CWD_ACTIVE=""
  for candidate in "$PWD/${_lv2_leadv2_dir}/active.yaml" \
                   "${_lv2_sp_root}/${_lv2_leadv2_dir}/active.yaml"; do
    [[ -f "$candidate" ]] && CWD_ACTIVE="$candidate" && break
  done
  [[ -z "$CWD_ACTIVE" ]] && exit 0
  # ── PO-064: use 5s cache instead of raw python3 parse ──────────────────────
  # shellcheck source=/dev/null
  source "$HOME/.claude/hooks/leadv2-active-cache.sh"
  leadv2_read_active_yaml "$CWD_ACTIVE"
  LEADV2_TASK_ID="${ACTIVE_TASK_ID:-}"
  LEADV2_PHASE="${ACTIVE_PHASE:-}"
fi
[[ -n "${LEADV2_TASK_ID:-}" ]] || exit 0

# Phase-aware word budget (was global 100w → killed planning/review subagents)
case "${LEADV2_PHASE:-}" in
  intake|classify) WORD_LIMIT=200 ;;
  plan)            WORD_LIMIT=500 ;;
  build)           WORD_LIMIT=250 ;;
  review)          WORD_LIMIT=300 ;;
  deploy|verify)   WORD_LIMIT=200 ;;
  close)           WORD_LIMIT=150 ;;
  *)               WORD_LIMIT=200 ;;
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

# Inline JSONL parsing — pass JSONL path via argv to avoid stdin heredoc conflict
PARSE_OUT="$(python3 - "$JSONL" <<'PYEOF' 2>/dev/null || true
import sys, json

jsonl_path = sys.argv[1]
last = None
with open(jsonl_path) as f:
    for line in f:
        try:
            r = json.loads(line)
            if r.get('type') == 'assistant':
                m = r.get('message', {})
                content = m.get('content', [])
                if isinstance(content, list):
                    text_parts = [c.get('text', '') for c in content if c.get('type') == 'text']
                    last = '\n'.join(text_parts)
        except Exception:
            continue
if last is not None:
    print('TEXT_START')
    print(last)
PYEOF
)"

[[ -z "$PARSE_OUT" ]] && exit 0

TEXT_BODY="$(printf '%s' "$PARSE_OUT" | awk '/^TEXT_START$/{f=1; next} f' | head -200)"
WORD_COUNT=$(printf '%s' "$TEXT_BODY" | wc -w | tr -d ' ')

[[ "$WORD_COUNT" -le "$WORD_LIMIT" ]] && exit 0

# Advisory warning only — log violation and inject a reminder via additionalContext.
# Never emit continue:false; never suppress the session.
printf '%s WARN session=%s words=%s limit=%s task=%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$SESSION_ID" "$WORD_COUNT" "$WORD_LIMIT" "$LEADV2_TASK_ID" \
    >> "$HOME/.claude/leadv2-prose-violations.log" 2>/dev/null || true

python3 - "$WORD_COUNT" "$LEADV2_TASK_ID" "$WORD_LIMIT" "${LEADV2_PHASE:-}" <<'PYEOF' 2>/dev/null || true
import sys, json
wc, tid, lim, phase = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
print(json.dumps({
    'hookSpecificOutput': {
        'hookEventName': 'UserPromptSubmit',
        'additionalContext': f'[PULSE_WARN] phase={phase}: last turn {wc} words (limit {lim}). Tighten prose or use tool calls. task={tid}'
    }
}))
PYEOF
