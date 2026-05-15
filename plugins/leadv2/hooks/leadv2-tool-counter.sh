#!/usr/bin/env bash
# PostToolUse hook: count tool calls per active leadv2 task.
# Counter file: ~/.claude/state/leadv2/<task-id>.tool-count (one line per call).
# Final count: wc -l on that file.
# Silent exit when no active leadv2 task — safe for all sessions.
set -euo pipefail
trap 'exit 0' ERR

INPUT="$(cat 2>/dev/null || true)"
[[ -z "$INPUT" ]] && exit 0

# Locate the project cwd from hook input (falls back to PWD)
CWD="$(printf -- '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)"
[[ -z "$CWD" ]] && CWD="$PWD"

ACTIVE_YAML=""
for f in "$CWD/docs/leadv2/active.yaml" "$CWD/.claude/leadv2-tasks/active.yaml"; do
  [[ -f "$f" ]] && ACTIVE_YAML="$f" && break
done

# No active.yaml found → not a leadv2 session, exit silently
[[ -z "$ACTIVE_YAML" ]] && exit 0

# Extract first active task_id (python3 always available in this env)
TASK_ID="$(python3 - "$ACTIVE_YAML" <<'PYEOF' 2>/dev/null || true
import sys, yaml
try:
    d = yaml.safe_load(open(sys.argv[1])) or {}
    sessions = d.get('sessions') or []
    if sessions:
        print(sessions[0].get('task_id', '').strip())
except Exception:
    pass
PYEOF
)"

# No active task → exit silently
[[ -z "$TASK_ID" ]] && exit 0

# Sanitize task_id to safe filename chars (alphanumeric, dash, dot, underscore)
SAFE_ID="$(printf -- '%s' "$TASK_ID" | tr -cd 'A-Za-z0-9._-')"
[[ -z "$SAFE_ID" ]] && exit 0

STATE_DIR="$HOME/.claude/state/leadv2"
mkdir -p "$STATE_DIR"

# Append one line per tool call; count = wc -l
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf -- '%s\n' "$TS" >> "${STATE_DIR}/${SAFE_ID}.tool-count"

# --- Per-subagent tracking (best-effort) ---
# Try to extract agent_id from hook input
AGENT_ID="$(printf -- '%s' "$INPUT" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    # SubagentStop / Agent tool may provide agent_id
    aid = d.get('agent_id') or d.get('tool_input', {}).get('agent_id') or ''
    # Fall back: extract basename from transcript_path if it's in */subagents/* dir
    if not aid:
        tp = d.get('transcript_path', '')
        if '/subagents/' in tp:
            import os
            aid = os.path.splitext(os.path.basename(tp))[0]
    print(aid.strip())
except Exception:
    pass
" 2>/dev/null || true)"

if [[ -n "$AGENT_ID" ]]; then
    # Sanitize agent_id
    SAFE_AGENT_ID="$(printf -- '%s' "$AGENT_ID" | tr -cd 'A-Za-z0-9._-')"
    if [[ -n "$SAFE_AGENT_ID" ]]; then
        AGENT_COUNT_FILE="${STATE_DIR}/${SAFE_ID}.${SAFE_AGENT_ID}.tool-count"
        printf -- '%s\n' "$TS" >> "$AGENT_COUNT_FILE"
        AGENT_COUNT="$(wc -l < "$AGENT_COUNT_FILE" 2>/dev/null || printf '0')"
        AGENT_COUNT="${AGENT_COUNT// /}"
        if [[ "$AGENT_COUNT" -ge 30 ]]; then
            printf '[leadv2-tool-counter] subagent %s exceeded 30 tool calls — consider DELIVERABLE_BLOCKED if not converging\n' "$SAFE_AGENT_ID" >&2
        fi
    fi
fi

exit 0
