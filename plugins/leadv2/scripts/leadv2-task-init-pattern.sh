#!/usr/bin/env bash
# leadv2-task-init-pattern.sh <task-id>
# Creates per-task STATE.md, registers in docs/leadv2/active.yaml.
# PATTERN VARIANT: reference implementation for PE task init conventions.
# PE's actual intake is handled by the /leadv2 orchestrator — use this script
# for manual init or testing of the init flow.
#
# Ported from m3-market/.claude/scripts/leadv2-task-init.sh
# Sanitized for persona-engine conventions:
#   - Task-id regex: LEADV2|LOCAL (PE) — NOT PENG (m3/Linear)
#   - Task state dir: docs/leadv2/tasks/<id>/ (PE convention)
#   - Active registry: docs/leadv2/active.yaml (PE convention)
#   - Template: docs/leadv2/tasks/.template/STATE.md (PE convention)
#   - Stripped: Linear API integration
#   - Stripped: CircleCI integration
# Linear integration intentionally omitted in PE port.
set -euo pipefail

usage() {
  echo "usage: $(basename "$0") <task-id>" >&2
  echo "  task-id format: LEADV2-<slug> | LOCAL-<n>-<slug>" >&2
  exit 64
}

[[ $# -lt 1 ]] && usage
TASK_ID="$1"

# PE task-id format: LEADV2-<anything> or LOCAL-<n>-<slug>
if [[ ! "$TASK_ID" =~ ^(LEADV2|LOCAL)-[A-Za-z0-9_-]+$ ]]; then
  echo "ERR: invalid task-id format: $TASK_ID" >&2
  echo "expected: LEADV2-<slug> | LOCAL-<n>-<slug>" >&2
  exit 65
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# PE path conventions
TASKS_DIR="$PROJECT_ROOT/docs/leadv2/tasks"
TASK_DIR="$TASKS_DIR/$TASK_ID"
STATE_FILE="$TASK_DIR/STATE.md"
ACTIVE_FILE="$PROJECT_ROOT/docs/leadv2/active.yaml"

# Template lookup: prefer .template/STATE.md, fall back to creating minimal one
TEMPLATE="$TASKS_DIR/.template/STATE.md"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Idempotency: STATE.md exists + registered → fully done
if [[ -f "$STATE_FILE" ]] && python3 -c "
import yaml, sys
try:
    d = yaml.safe_load(open('$ACTIVE_FILE')) or {}
    found = any(s.get('task_id') == '$TASK_ID' for s in (d.get('sessions') or []))
    sys.exit(0 if found else 1)
except Exception:
    sys.exit(1)
" 2>/dev/null; then
  echo "task already initialized: $TASK_ID"
  echo "state: $STATE_FILE"
  exit 0
fi

mkdir -p "$TASK_DIR"

# STATE.md exists but not in active.yaml (orphaned / resumed without init)
if [[ -f "$STATE_FILE" ]]; then
  echo "task state found on disk but unregistered — re-registering: $TASK_ID"
  [[ -f "$ACTIVE_FILE" ]] || printf 'meta:\n  schema_version: 1\nsessions: []\n' > "$ACTIVE_FILE"
  python3 - "$ACTIVE_FILE" "$TASK_ID" "$NOW" <<'PY'
import sys, re, pathlib
path, tid, now = sys.argv[1], sys.argv[2], sys.argv[3]
p = pathlib.Path(path)
src = p.read_text()
if re.search(rf'task_id:\s*{re.escape(tid)}', src, re.M):
    sys.exit(0)
# Read existing phase from STATE.md
tasks_dir = pathlib.Path(path).parent / 'tasks'
state = tasks_dir / tid / 'STATE.md'
phase = 'intake'
if state.exists():
    m = re.search(r'^- phase:\s*(\S+)', state.read_text(), re.MULTILINE)
    if m: phase = m.group(1)
entry = (
    f"  - task_id: {tid}\n"
    f"    phase: {phase}\n"
    f"    created_at: {now}\n"
    f"    last_seen_at: {now}\n"
    f"    branches: {{}}\n"
    f"    prs: {{}}\n"
)
if re.search(r'^sessions:\s*\[\]\s*$', src, re.M):
    src = re.sub(r'^sessions:\s*\[\]\s*$', 'sessions:\n' + entry.rstrip() + '\n', src, count=1, flags=re.M)
elif re.search(r'^sessions:\s*$', src, re.M):
    src = src.rstrip() + '\n' + entry
else:
    if 'sessions:' not in src:
        src = src.rstrip() + '\nsessions:\n'
    src = src.rstrip() + '\n' + entry
p.write_text(src)
PY
  echo "state: $STATE_FILE"
  exit 0
fi

# Create STATE.md from template or minimal scaffold
SLUG="${TASK_ID#*-}"
TITLE="$(echo "$SLUG" | tr '-' ' ')"

if [[ -f "$TEMPLATE" ]]; then
  sed \
    -e "s|{{task_id}}|$TASK_ID|g" \
    -e "s|{{title}}|$TITLE|g" \
    -e "s|{{created_at}}|$NOW|g" \
    -e "s|{{linear_url}}|null|g" \
    -e "s|{{slug}}|$SLUG|g" \
    "$TEMPLATE" > "$STATE_FILE"
else
  # Minimal scaffold when no template exists
  cat > "$STATE_FILE" <<EOF
# STATE: $TASK_ID

- task_id: $TASK_ID
- title: $TITLE
- phase: intake
- created_at: $NOW
- last_seen_at: $NOW

## Goal


## Plan


## History notes

EOF
fi

# Register in active.yaml
[[ -f "$ACTIVE_FILE" ]] || cat > "$ACTIVE_FILE" <<EOF
meta:
  schema_version: 1
sessions: []
EOF

python3 - "$ACTIVE_FILE" "$TASK_ID" "$NOW" <<'PY'
import sys, re, pathlib
path, tid, now = sys.argv[1], sys.argv[2], sys.argv[3]
p = pathlib.Path(path)
src = p.read_text()
if re.search(rf'task_id:\s*{re.escape(tid)}', src, re.M):
    sys.exit(0)
entry = (
    f"  - task_id: {tid}\n"
    f"    phase: intake\n"
    f"    created_at: {now}\n"
    f"    last_seen_at: {now}\n"
    f"    branches: {{}}\n"
    f"    prs: {{}}\n"
)
if re.search(r'^sessions:\s*\[\]\s*$', src, re.M):
    src = re.sub(r'^sessions:\s*\[\]\s*$', 'sessions:\n' + entry.rstrip() + '\n', src, count=1, flags=re.M)
elif re.search(r'^sessions:\s*$', src, re.M):
    src = src.rstrip() + '\n' + entry
else:
    if 'sessions:' not in src:
        src = src.rstrip() + '\nsessions:\n'
    src = src.rstrip() + '\n' + entry
p.write_text(src)
PY

echo "task initialized: $TASK_ID"
echo "state: $STATE_FILE"
