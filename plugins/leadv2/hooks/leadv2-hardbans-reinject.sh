#!/usr/bin/env bash
# PostToolUse hook: periodic re-injection of leadv2 hard-bans digest to fight long-context drift.
# Fires every LEADV2_REINJECT_EVERY tool calls (default 25) in the lead session only.
# Fail-open: any parse error -> exit 0, never block.
set -euo pipefail
trap 'exit 0' ERR

INPUT="$(cat 2>/dev/null || true)"
[[ -z "$INPUT" ]] && exit 0

# shellcheck source=leadv2-mode-isolation.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/leadv2-mode-isolation.sh"
leadv2_hook_is_supervisor_session "$INPUT" && exit 0

# --- Guard 1: lead-only — subagents have agent_type field; skip if present ---
HAS_AGENT_TYPE="$(printf -- '%s' "$INPUT" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print('yes' if 'agent_type' in d else 'no')
except Exception:
    print('no')
" 2>/dev/null || printf 'no')"
[[ "$HAS_AGENT_TYPE" == "yes" ]] && exit 0

# --- Guard 2: disabled check ---
REINJECT_EVERY="${LEADV2_REINJECT_EVERY:-25}"
[[ "$REINJECT_EVERY" -eq 0 ]] && exit 0

# --- Guard 3: active leadv2 session ---
CWD="$(printf -- '%s' "$INPUT" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('cwd') or '')
except Exception:
    print('')
" 2>/dev/null || printf '')"
[[ -z "$CWD" ]] && CWD="$PWD"

ACTIVE_YAML=""
for f in "$CWD/docs/leadv2/active.yaml" "$CWD/.claude/leadv2-tasks/active.yaml"; do
  [[ -f "$f" ]] && ACTIVE_YAML="$f" && break
done

if [[ -z "$ACTIVE_YAML" ]]; then
  [[ -z "${LEADV2_TASK_ID:-}" ]] && exit 0
fi

# --- Read active task info for payload ---
TASK_ID_PHASE="none"
TASK_ID="$(leadv2_hook_resolve_task_id "$INPUT" "$ACTIVE_YAML" 2>/dev/null || true)"
[[ -z "$TASK_ID" ]] && exit 0
ACTIVE_PHASE="$(leadv2_hook_resolve_phase "$INPUT" "$ACTIVE_YAML" 2>/dev/null || true)"
TASK_ID_PHASE="${TASK_ID}: ${ACTIVE_PHASE:-unknown}"

# --- Extract session_id for counter file ---
SESSION_ID="$(printf -- '%s' "$INPUT" | python3 -c "
import sys, json, os
try:
    d = json.load(sys.stdin)
    sid = d.get('session_id') or ''
    if not sid and d.get('transcript_path'):
        sid = os.path.splitext(os.path.basename(d['transcript_path']))[0]
    print(sid.strip())
except Exception:
    print('')
" 2>/dev/null || printf '')"
[[ -z "$SESSION_ID" ]] && SESSION_ID="$PPID"
SAFE_SID="$(printf -- '%s' "$SESSION_ID" | tr -cd 'A-Za-z0-9._-')"
[[ -z "$SAFE_SID" ]] && SAFE_SID="default"

# --- Counter file: /tmp/leadv2-reinject-<session_id>.count ---
COUNTER_FILE="/tmp/leadv2-reinject-${SAFE_SID}.count"

CURRENT=0
if [[ -f "$COUNTER_FILE" ]]; then
    CURRENT="$(cat "$COUNTER_FILE" 2>/dev/null || printf '0')"
    CURRENT="${CURRENT//[^0-9]/}"
    [[ -z "$CURRENT" ]] && CURRENT=0
fi

CURRENT=$(( CURRENT + 1 ))
printf '%d\n' "$CURRENT" > "$COUNTER_FILE"

# --- Emit only on modulo hit ---
REMAINDER=$(( CURRENT % REINJECT_EVERY ))
[[ "$REMAINDER" -ne 0 ]] && exit 0

# --- Emit additionalContext JSON payload ---
jq -n --arg ctx "[LEADV2 HARD-BANS REFRESH] (periodic anti-drift reminder)
- No code by lead (.py/.sh/.ts/.sql) — delegate to developer/devops.
- SILENCE PROTOCOL: pulse lines only; no narration between phases.
- Agent spawns: run_in_background=true; read deliverables via Read limit=30 / critic-tail.sh.
- Read always offset/limit; Bash output pre-truncated at source.
- Active task/phase: ${TASK_ID_PHASE}" '{
  hookSpecificOutput: {
    hookEventName: "PostToolUse",
    additionalContext: $ctx
  }
}'

exit 0
