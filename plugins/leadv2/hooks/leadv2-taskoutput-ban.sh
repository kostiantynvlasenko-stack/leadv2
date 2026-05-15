#!/usr/bin/env bash
# PreToolUse hook for TaskOutput. Block when target is a subagent .output file
# (those are full JSONL transcripts and reading them overflows lead context).
# Bash background tasks → allow (output is plain stdout/stderr).
set -euo pipefail
trap 'echo "[$(basename "$0")] error at line $LINENO" >&2; exit 0' ERR

INPUT="$(cat 2>/dev/null || true)"
[[ -z "$INPUT" ]] && exit 0

TASK_ID="$(echo "$INPUT" | jq -r '.tool_input.task_id // empty' 2>/dev/null || echo "")"
[[ -z "$TASK_ID" ]] && exit 0

# Best-effort: detect agent tasks. Their output files live under .../tasks/<id>.output
# and are JSONL transcripts. We can't always know the type without filesystem inspection,
# so we apply a soft policy: warn always, block when LEADV2_TASKOUTPUT_STRICT=1.

cat >&2 <<MSG
[leadv2-taskoutput-ban] WARN: TaskOutput on task=$TASK_ID
  If this is a sub-Agent task, its .output is a full JSONL transcript and will
  flood your context. Read the deliverable file path from the task-notification
  with Read(limit=30) instead.
  If this is a background Bash task: this is allowed and you can ignore.

  Strict mode: export LEADV2_TASKOUTPUT_STRICT=1 to hard-block all TaskOutput.
MSG

if [[ "${LEADV2_TASKOUTPUT_STRICT:-0}" == "1" ]]; then
  exit 2
fi
exit 0
