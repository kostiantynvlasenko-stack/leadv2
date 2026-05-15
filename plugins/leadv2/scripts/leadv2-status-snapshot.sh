#!/usr/bin/env bash
# Status snapshot — what lead quotes verbatim when founder asks "где мы / status".
# No LLM, just file reads + grep.
#
# Usage: leadv2-status-snapshot.sh [--task-id <id>]

set -euo pipefail
trap 'exit 0' ERR

PROJECT_ROOT="${PROJECT_ROOT:-$(pwd)}"
TASK_ID=""
while [[ $# -gt 0 ]]; do
  case "$1" in --task-id) TASK_ID="$2"; shift 2;; *) shift;; esac
done

ACTIVE=""
for f in "$PROJECT_ROOT/.claude/leadv2-tasks/active.yaml" "$PROJECT_ROOT/docs/leadv2/active.yaml"; do
  [[ -f "$f" ]] && ACTIVE="$f" && break
done

if [[ -z "$ACTIVE" ]]; then
  echo "no active.yaml — no /leadv2 task in flight"
  exit 0
fi

# Active sessions
python3 -c "
import yaml
try:
    d = yaml.safe_load(open('$ACTIVE')) or {}
    s = d.get('sessions') or []
    if not s:
        print('no in-flight sessions')
    else:
        for sess in s[:3]:
            tid = sess.get('task_id','?')
            phase = sess.get('phase','?')
            note = sess.get('note','') or sess.get('blocked_by','')
            extra = f' — {note}' if note else ''
            print(f'  task={tid} phase={phase}{extra}')
except Exception as e:
    print(f'(error reading active.yaml: {e})')
"

# Tail of LEAD_V2_STATE
STATE="$PROJECT_ROOT/docs/LEAD_V2_STATE.md"
[[ -f "$STATE" ]] || STATE="$PROJECT_ROOT/LEAD_V2_STATE.md"
if [[ -f "$STATE" ]]; then
  echo
  echo "=== LEAD_V2_STATE tail ==="
  tail -15 "$STATE"
fi

# Per-task verdicts if task_id given
if [[ -n "$TASK_ID" ]]; then
  HANDOFF="$PROJECT_ROOT/docs/handoff/$TASK_ID"
  if [[ -d "$HANDOFF" ]]; then
    echo
    echo "=== handoff/$TASK_ID verdicts ==="
    for f in "$HANDOFF"/*.summary.md; do
      [[ -f "$f" ]] || continue
      name="$(basename "$f" .summary.md)"
      v="$(head -5 "$f" | grep -E '^verdict:' | head -1 | sed 's/^verdict:[ ]*//' | tr -d '"')"
      [[ -n "$v" ]] && echo "  $name: $v"
    done
  fi
fi
