#!/usr/bin/env bash
# PreToolUse hook: block foreground Agent spawns when an active leadv2 task exists.
# Foreground spawns drop full subagent transcripts into lead chat — main token killer.
# Whitelist: Trivial-class tasks may use foreground.
set -euo pipefail
trap 'echo "[$(basename "$0")] error at line $LINENO" >&2; exit 0' ERR

INPUT="$(cat 2>/dev/null || true)"
[[ -z "$INPUT" ]] && exit 0

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

# NOTE: Claude Code does NOT pass run_in_background to PreToolUse hooks.
# Cannot distinguish fg from bg agents here.
# Strategy: only block during idle phases (async_wait) — active phases need agents.
# bg-agent discipline enforced via orchestrator protocol, not this hook.
#
# NESTED-SPAWN EXEMPTION (v2.1.172+):
# Subagent-initiated spawns always occur while the task is in an ACTIVE phase
# (the subagent is running as part of Phase 4 build or similar), never in async_wait.
# Therefore subagent nested spawns are inherently exempt from this block — the
# async_wait guard below will find no idle session and exit 0 before blocking.
# No caller-identity check is needed here; routing-guard.sh enforces the nested-spawn
# allow-list (Explore/general-purpose + explicit model=haiku|sonnet).
SHOULD_BLOCK="$(python3 - "$ACTIVE" 2>/dev/null <<'PY' || echo "false"
import sys, yaml, pathlib
try:
    d = yaml.safe_load(open(sys.argv[1])) or {}
except Exception:
    print("false"); sys.exit(0)
sessions = d.get('sessions') or []
hub = pathlib.Path(sys.argv[1]).parent.parent

# Only block when a non-trivial task is in async_wait with no active work expected
IDLE_PHASES = {'async_wait'}

for s in sessions:
    tid = s.get('task_id')
    phase = s.get('phase','')
    if not tid or phase not in IDLE_PHASES:
        continue
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
Agent spawn during async_wait phase — task is idle, no agents expected.
If resuming work: run /leadv2 resume <task-id> first to re-activate the task.
Override: set LEADV2_ALLOW_FG=1 if you intentionally need an agent here.
MSG

[[ "${LEADV2_ALLOW_FG:-0}" == "1" ]] && exit 0
exit 2
