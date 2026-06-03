#!/usr/bin/env bash
# codex-poll-done.sh <job-id>
# Polls codex-task.sh status <job-id> --json and exits 0 only when the job
# has reached a terminal state (completed/failed/cancelled).
# Exits 1 for: running/queued, job not found, malformed JSON, missing arg.
# Never crashes — all errors exit 1 (non-terminal = keep waiting).
set -euo pipefail
trap 'exit 1' ERR

JOB_ID="${1:-}"
if [[ -z "$JOB_ID" ]]; then
  echo "[codex-poll-done] ERROR: job-id argument required" >&2
  exit 1
fi

CODEX_TASK="${CODEX_TASK_SH:-$HOME/.claude/scripts/codex-task.sh}"
if [[ ! -x "$CODEX_TASK" ]]; then
  echo "[codex-poll-done] ERROR: codex-task.sh not found at $CODEX_TASK" >&2
  exit 1
fi

# Fetch JSON status — if job not yet registered, codex-task.sh exits non-zero
RAW="$("$CODEX_TASK" status "$JOB_ID" --json 2>/dev/null || true)"

if [[ -z "$RAW" ]]; then
  # Job not registered yet or command failed
  exit 1
fi

# Parse .job.status from JSON — terminal states: completed, failed, cancelled
STATUS="$(python3 -c "
import sys, json
try:
    d = json.loads(sys.argv[1])
    # codex status --json returns {workspaceRoot, job:{status:...}}
    j = d.get('job') or {}
    print(j.get('status', '').strip().lower())
except Exception:
    pass
" "$RAW" 2>/dev/null || true)"

case "$STATUS" in
  completed|failed|cancelled)
    echo "[codex-poll-done] terminal: $STATUS (job=$JOB_ID)"
    exit 0
    ;;
  queued|running)
    exit 1
    ;;
  *)
    # Unknown or empty status — treat as non-terminal
    exit 1
    ;;
esac
