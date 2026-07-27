#!/usr/bin/env bash
# PreToolUse hook - wire leadv2-loop-detect.py as plugin-default tool-cap guard.
#
# Defaults (no env setup required for fresh install):
#   LEADV2_TOOL_HARD_LIMIT=50   block at 50 total calls per tool type
#   LEADV2_TOOL_FREQ_WARN=30    warn at 30 total calls per tool type
#   LEADV2_UNCAPPED_TOOLS=Agent tool names exempt from the per-tool frequency cap
#                               above (2026-07-27: a supervisor's job is spawning
#                               subagents; Agent must not share Bash's 50-call cap)
#   LEADV2_LOOP_DETECT=1        on by default (set to 0 to disable)
#
# WARN -> non-blocking advisory on stderr (exit 0)
# BLOCK -> deny decision JSON + exit 2 (hard block)
# Fail-safe: any internal error exits 0 (never bricks the session).

set -euo pipefail
_LV2_D="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
trap 'echo "[$(basename "$0")] error at line $LINENO — continuing" >&2; exit 0' ERR

DETECT="${LEADV2_LOOP_DETECT:-1}"
[[ "$DETECT" == "0" ]] && exit 0

INPUT="$(cat 2>/dev/null || true)"
[[ -z "$INPUT" ]] && exit 0

# Parse all needed fields in a single python3 call to reduce subprocess overhead.
# Emit 3 lines: tool_name, session_id, args_json (json.dumps — guaranteed single line,
# ensure_ascii=True default means no embedded newlines, so line-split is safe).
# fix-round-2 (task 6d0c93f4a7b2, item 6): also extract hook_event_name (so
# PostToolUse can be routed to the record-only path) and agent_id (so a
# spawned child agent gets its own counter namespace instead of inheriting
# the parent session's -- same extraction convention as leadv2-tool-counter.sh).
PARSED="$(printf -- '%s' "$INPUT" | python3 -c "
import sys, json, os
try:
    r = json.loads(sys.stdin.read())
    tool_name  = r.get('tool_name', '')
    session_id = r.get('session_id', '')
    args_json  = json.dumps(r.get('tool_input', {}))  # single line, ensure_ascii=True
    hook_event = r.get('hook_event_name', '') or 'PreToolUse'
    agent_id   = r.get('agent_id') or r.get('tool_input', {}).get('agent_id') or ''
    if not agent_id:
        tp = r.get('transcript_path', '')
        if '/subagents/' in tp:
            agent_id = os.path.splitext(os.path.basename(tp))[0]
    print(tool_name)
    print(session_id)
    print(args_json)
    print(hook_event)
    print(agent_id.strip())
except Exception:
    pass
" 2>/dev/null || true)"

[[ -z "$PARSED" ]] && exit 0

# Split captured output on newlines — one read, no extra subprocesses.
TOOL_NAME="$(printf -- '%s' "$PARSED" | sed -n '1p')"
SESSION_ID="$(printf -- '%s' "$PARSED" | sed -n '2p')"
ARGS_JSON="$(printf -- '%s' "$PARSED" | sed -n '3p')"
HOOK_EVENT="$(printf -- '%s' "$PARSED" | sed -n '4p')"
AGENT_ID="$(printf -- '%s' "$PARSED" | sed -n '5p')"
[[ -z "$ARGS_JSON" ]] && ARGS_JSON="{}"
[[ -z "$HOOK_EVENT" ]] && HOOK_EVENT="PreToolUse"

[[ -z "$TOOL_NAME" ]] && exit 0
[[ -z "$SESSION_ID" ]] && exit 0

TASK_ID="${LEADV2_TASK_ID:-default}"

DETECT_SCRIPT=""
if [[ -n "${CLAUDE_PLUGIN_ROOT:-}" && -f "${CLAUDE_PLUGIN_ROOT}/scripts/leadv2-loop-detect.py" ]]; then
    DETECT_SCRIPT="${CLAUDE_PLUGIN_ROOT}/scripts/leadv2-loop-detect.py"
elif [[ -f "$_LV2_D/../scripts/leadv2-loop-detect.py" ]]; then
    DETECT_SCRIPT="$_LV2_D/../scripts/leadv2-loop-detect.py"
fi
[[ -z "$DETECT_SCRIPT" ]] && exit 0

export LEADV2_LOOP_DETECT="$DETECT"
export LEADV2_TOOL_FREQ_WARN="${LEADV2_TOOL_FREQ_WARN:-30}"
export LEADV2_TOOL_HARD_LIMIT="${LEADV2_TOOL_HARD_LIMIT:-50}"
export LEADV2_UNCAPPED_TOOLS="${LEADV2_UNCAPPED_TOOLS:-Agent}"

# Build JSON payload safely via python3 to avoid shell quoting issues
# NOTE (D6/F4, task 6d0c93f4a7b2): earlier versions passed a `--` separator
# before the positional args. `python3 -c` does NOT strip `--` from sys.argv
# (confirmed on 3.11-3.14: sys.argv becomes ['\''-c'\'', '\''--'\'', ...]), so every
# arg was shifted one slot right and $DETECT_SCRIPT silently resolved to the
# TASK_ID string. That made the inner subprocess.run() invoke
# `python3 <task_id>`, which fails, so the detector never ran, no state file
# was ever written, and the whole tool-cap guard was permanently inert. Do
# NOT reintroduce `--` here. Genuine internal failures are now logged to
# stderr (not swallowed by 2>/dev/null) before the fail-open CLEAR fallback.
VERDICT="$(python3 -c "
import sys, json, subprocess
tool_name = sys.argv[1]
args_json = sys.argv[2]
session_id = sys.argv[3]
task_id = sys.argv[4]
detect_script = sys.argv[5]
hook_event = sys.argv[6]
agent_id = sys.argv[7]
payload = json.dumps({
    'tool_name': tool_name,
    'args_canonical_json': args_json,
    'session_id': session_id,
    'task_id': task_id,
    'hook_event_name': hook_event,
    'agent_id': agent_id,
})
result = subprocess.run(['python3', detect_script], input=payload, capture_output=True, text=True, timeout=10)
if result.returncode != 0:
    print(f'[leadv2-loop-detect] detector exited {result.returncode}: {result.stderr.strip()}', file=sys.stderr)
    print('CLEAR')
else:
    if result.stderr.strip():
        print(f'[leadv2-loop-detect] detector stderr: {result.stderr.strip()}', file=sys.stderr)
    print(result.stdout.strip() or 'CLEAR')
" "$TOOL_NAME" "$ARGS_JSON" "$SESSION_ID" "$TASK_ID" "$DETECT_SCRIPT" "$HOOK_EVENT" "$AGENT_ID" || echo "CLEAR")"

# fix-round-2 (task 6d0c93f4a7b2, item 6): PostToolUse fires after the call
# already executed -- there is nothing left to deny. The detector itself only
# ever returns CLEAR for a PostToolUse payload (it just records the count), but
# this branch is defense-in-depth so a future change to the detector can never
# turn a record-only Post call into a retroactive block.
if [[ "$HOOK_EVENT" == "PostToolUse" ]]; then
  exit 0
fi

case "$VERDICT" in
  CLEAR*) exit 0 ;;
  WARN*)
    printf '[leadv2-loop-detect] %s\n' "$VERDICT" >&2
    exit 0
    ;;
  BLOCK*)
    # Emit deny JSON to stdout for SDK permit-decision; then hard-block via exit 2.
    # Disable ERR trap first so the intentional exit 2 is not swallowed.
    trap - ERR
    # F1 (task 6d0c93f4a7b2): the deny reason must ALSO reach stderr -- on
    # exit 2 the harness surfaces stderr to the caller, not stdout JSON, so a
    # stdout-only reason is a textless denial. Build the message once in bash
    # (no `--` before the python arg -- see the D6/F4 note above) and print it
    # to both channels so it can never desync.
    REASON_MSG="TOOL_CAP: ${VERDICT}. Override: export LEADV2_TOOL_HARD_LIMIT=<n>, add this tool to LEADV2_UNCAPPED_TOOLS, or LEADV2_LOOP_DETECT=0"
    python3 -c "
import sys, json
reason = sys.argv[1]
print(json.dumps({'hookSpecificOutput':{'hookEventName':'PreToolUse','permissionDecision':'deny','permissionDecisionReason':reason}}))
" "$REASON_MSG"
    printf '[leadv2-loop-detect] %s\n' "$REASON_MSG" >&2 || true
    exit 2
    ;;
  *) exit 0 ;;
esac
