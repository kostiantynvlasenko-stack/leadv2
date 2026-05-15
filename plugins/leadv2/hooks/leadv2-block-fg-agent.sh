#!/usr/bin/env bash
# PreToolUse hook: block foreground Agent spawns when an active leadv2 task exists.
# Foreground spawns drop full subagent transcripts into lead chat — main token killer.
# Whitelist: Trivial-class tasks may use foreground.
set -euo pipefail
trap 'echo "[$(basename "$0")] error at line $LINENO" >&2; exit 0' ERR

INPUT="$(cat 2>/dev/null || true)"
[[ -z "$INPUT" ]] && exit 0

# Extract run_in_background flag and session/cwd
BG="$(echo "$INPUT" | jq -r '.tool_input.run_in_background // false' 2>/dev/null || echo false)"
[[ "$BG" == "true" ]] && exit 0

CWD="$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || echo "")"
[[ -z "$CWD" ]] && CWD="$PWD"

# Find leadv2 active.yaml across known hubs
ACTIVE_FILES=(
  "$CWD/.claude/leadv2-tasks/active.yaml"
  "$CWD/docs/leadv2/active.yaml"
)

ACTIVE=""
for f in "${ACTIVE_FILES[@]}"; do
  if [[ -f "$f" ]]; then ACTIVE="$f"; break; fi
done
[[ -z "$ACTIVE" ]] && exit 0

# Any non-trivial active task? If yes, block.
SHOULD_BLOCK="$(python3 - "$ACTIVE" 2>/dev/null <<'PY' || echo "false"
import sys, yaml, pathlib
try:
    d = yaml.safe_load(open(sys.argv[1])) or {}
except Exception:
    print("false"); sys.exit(0)
sessions = d.get('sessions') or []
hub = pathlib.Path(sys.argv[1]).parent.parent
for s in sessions:
    tid = s.get('task_id')
    phase = s.get('phase','')
    if not tid or phase in ('close','async_wait'): continue
    state = hub / 'leadv2-tasks' / tid / 'STATE.md'
    if not state.exists(): state = hub.parent / 'docs/leadv2/tasks' / tid / 'STATE.md'
    klass = 'Standard'
    if state.exists():
        for line in state.read_text().splitlines():
            if line.lstrip().startswith('- class:'):
                klass = line.split(':',1)[1].strip(); break
    if klass not in ('Trivial',):
        print("true"); sys.exit(0)
print("false")
PY
)"

[[ "$SHOULD_BLOCK" != "true" ]] && exit 0

cat >&2 <<'MSG'
[leadv2-block-fg-agent] BLOCKED
Foreground Agent spawn detected during active non-Trivial leadv2 task.
Why: foreground spawns drop the full subagent transcript into lead chat → 30-100KB
     accumulates per spawn forever. This is the #1 token-burn cause.

Fix: add `run_in_background: true` to the Agent call. Lead receives task-notification,
then reads deliverable with `Read limit=30` (header + summary_for_lead only).

Override (rare, when subagent output is genuinely tiny):
  set env LEADV2_ALLOW_FG=1 just for this turn.
MSG

[[ "${LEADV2_ALLOW_FG:-0}" == "1" ]] && exit 0
exit 2
