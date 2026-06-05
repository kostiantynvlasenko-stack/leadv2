#!/usr/bin/env bash
# PreToolUse hook (Agent matcher) — gate on thinking directives in mission files.
# Extracts the mission file path from the Agent tool input, then runs
# leadv2-thinking-audit.sh --gate <mission-file>.
# Blocks if mission contains ultrathink/think hard/etc without explicit_reason_required: true.

set -euo pipefail
trap 'echo "[$(basename "$0")] error at line $LINENO" >&2; exit 0' ERR

INPUT="$(cat 2>/dev/null || true)"
[[ -z "$INPUT" ]] && exit 0

# Extract mission file path from Agent tool input
# Common field names: mission_file, task_file, prompt_file, or inline 'prompt' path reference
MISSION_FILE="$(printf '%s' "$INPUT" | python3 -c "
import sys, json, re
try:
    data = json.loads(sys.stdin.read())
    inp = data.get('tool_input', data)
    # Direct field
    for key in ('mission_file', 'task_file', 'prompt_file'):
        v = inp.get(key, '')
        if v and isinstance(v, str):
            print(v); sys.exit(0)
    # Scan prompt/task string for a file path pattern ending in .md
    for key in ('prompt', 'task', 'description'):
        v = inp.get(key, '')
        if not v or not isinstance(v, str): continue
        m = re.search(r'([^\s\"\']+\.md)', v)
        if m:
            print(m.group(1)); sys.exit(0)
except Exception:
    pass
" 2>/dev/null || true)"

[[ -z "$MISSION_FILE" ]] && exit 0

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
AUDIT_SCRIPT="${SCRIPT_DIR}/../scripts/leadv2-thinking-audit.sh"
[[ -x "$AUDIT_SCRIPT" ]] || exit 0

# Resolve relative mission file against project root
if [[ "${MISSION_FILE}" != /* ]]; then
  _root="${LEADV2_PROJECT_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
  MISSION_FILE="${_root}/${MISSION_FILE}"
fi

# Run gate — exits non-zero if blocked
if ! "$AUDIT_SCRIPT" --gate "$MISSION_FILE" 2>&1; then
  # Disable ERR trap before intentional exit 2
  trap - ERR
  python3 -c "
import sys, json
print(json.dumps({'hookSpecificOutput':{'hookEventName':'PreToolUse','permissionDecision':'deny','permissionDecisionReason':'Thinking-directive gate: mission contains ultrathink/think-hard without explicit_reason_required: true in context.yaml. Remove the directive or set explicit_reason_required: true.'}}))
"
  exit 2
fi
exit 0
