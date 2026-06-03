#!/bin/bash
set -euo pipefail
# ask-lead.sh — subagent-side question proxy. Writes question to mailbox, polls for answer.
# Called from inside a claude-subsession when subagent needs founder input.

usage() {
  cat >&2 <<EOF
Usage: ask-lead.sh <task-id> <question-text> [--context <text>] [--timeout <sec=600>]
EOF
  exit 1
}

[[ $# -lt 2 ]] && usage

TASK_ID="$1"; QUESTION="$2"; shift 2
CONTEXT=""; TIMEOUT=1800

while [[ $# -gt 0 ]]; do
  case "$1" in
    --context) CONTEXT="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    *) echo "[ask-lead] unknown arg: $1" >&2; usage ;;
  esac
done

PROJECT_ROOT="${PROJECT_ROOT:-$(pwd)}"
Q_DIR="$PROJECT_ROOT/docs/handoff/$TASK_ID/questions"
mkdir -p "$Q_DIR"

QID="q-$(date +%s)-$$"
PENDING="$Q_DIR/${QID}-pending.yaml"
ANSWERED="$Q_DIR/${QID}-answered.yaml"
SIGNAL="$Q_DIR/_signal"
ASKED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

{
  printf 'qid: "%s"\n' "$QID"
  printf 'question: |\n'
  printf '%s\n' "$QUESTION" | sed 's/^/  /'
  printf 'context: |\n'
  printf '%s\n' "$CONTEXT" | sed 's/^/  /'
  printf 'who: "%s"\n' "${CLAUDE_ROLE:-unknown}"
  printf 'asked_at: "%s"\n' "$ASKED_AT"
} > "$PENDING"

touch "$SIGNAL"

LOCK="$Q_DIR/${QID}-answer.lock"
DEADLINE=$(($(date +%s) + TIMEOUT))
# If lead writes the .lock file it signals "answer in progress — keep waiting even past soft deadline".
# Lead writes .lock immediately on receiving _signal, then writes -answered.yaml when founder responds.
LOCK_EXTENDED=0
while [[ $(date +%s) -lt $DEADLINE ]]; do
  if [[ -f "$ANSWERED" ]]; then
    awk '
      /^answer:/{
        flag=1
        sub(/^answer:[[:space:]]*/,"")
        if(length($0)) print
        next
      }
      flag && /^[[:space:]]/{
        sub(/^[[:space:]]+/,"")
        print
        next
      }
      flag && /^[^[:space:]]/{flag=0}
    ' "$ANSWERED"
    exit 0
  fi
  # Lock present but no answer yet: extend deadline once by another TIMEOUT seconds
  # so subagent survives long founder deliberation periods.
  if [[ -f "$LOCK" && "$LOCK_EXTENDED" -eq 0 ]]; then
    DEADLINE=$(($(date +%s) + TIMEOUT))
    LOCK_EXTENDED=1
  fi
  sleep 5
done

echo "TIMEOUT" >&2
exit 3
