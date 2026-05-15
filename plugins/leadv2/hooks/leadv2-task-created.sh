#!/usr/bin/env bash
# Fires on TaskCreated — logs task to per-project task log

LOG_DIR="$HOME/.claude/logs"
mkdir -p "$LOG_DIR"

TASK_JSON=$(cat)
SUBJECT=$(echo "$TASK_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('subject','unknown'))" 2>/dev/null)
PROJECT=$(basename "$PWD")
TIMESTAMP=$(date '+%Y-%m-%d %H:%M')

echo "$TIMESTAMP [$PROJECT] TASK_CREATED: $SUBJECT" >> "$LOG_DIR/task-log.txt"
exit 0
