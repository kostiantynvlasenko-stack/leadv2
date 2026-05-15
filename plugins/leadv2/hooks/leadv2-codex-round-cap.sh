#!/usr/bin/env bash
# PreToolUse:Bash — block codex adversarial-review invocations beyond round 2.
# Reads JSON input from stdin to extract command; if it matches the pattern,
# runs leadv2-codex-round-gate.sh and blocks if exit != 0.
set -euo pipefail
trap 'echo "[$(basename "$0")] error at line $LINENO" >&2; exit 0' ERR

INPUT="$(cat 2>/dev/null || true)"
[[ -z "$INPUT" ]] && exit 0

CMD="$(printf '%s' "$INPUT" | python3 -c "
import sys, json
try:
    r = json.loads(sys.stdin.read())
    print(r.get('tool_input', {}).get('command', ''))
except Exception:
    pass
" 2>/dev/null || true)"

[[ -z "$CMD" ]] && exit 0

# Match codex adversarial-review launches
if [[ "$CMD" == *"codex-task.sh adversarial-review"* ]] || [[ "$CMD" == *"codex-task.sh "* && "$CMD" == *"adversarial"* ]]; then
  GATE="${CLAUDE_PROJECT_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}/.claude/scripts/leadv2-codex-round-gate.sh"
  if [[ -x "$GATE" ]]; then
    if ! bash "$GATE" "${LEADV2_TASK_ID:-}" 2>&1; then
      python3 - <<'PYEOF'
import json
print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": "leadv2-codex-round-cap: max 2 codex rounds reached. Use architect-alt / judge-review / founder. Set ROUND_GATE_OVERRIDE=1 to force."
    }
}))
PYEOF
      exit 0
    fi
  fi
fi
exit 0
