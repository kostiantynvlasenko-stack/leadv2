#!/usr/bin/env bash
# Authoritative lane liveness. Provider status wins; files/processes are only
# explicitly-labelled fallbacks. Codex discovery stays inside codex-task.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${LEADV2_PROJECT_ROOT:-$PWD}"
JOB_ID=""
JSON=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-root) PROJECT_ROOT="$2"; shift 2 ;;
    --job) JOB_ID="$2"; shift 2 ;;
    --json) JSON=1; shift ;;
    *) echo "[lane-liveness] unknown arg: $1" >&2; exit 2 ;;
  esac
done

# Do not derive ~/.claude/.../state paths here: codex-task.sh owns provider
# state resolution and survives plugin layout changes. Tests may inject a shim.
CODEX_TASK="${CODEX_TASK_SH:-${SCRIPT_DIR}/codex-task.sh}"
raw=''
if [[ -x "$CODEX_TASK" || -f "$CODEX_TASK" ]]; then
  if [[ -n "$JOB_ID" ]]; then
    raw="$(bash "$CODEX_TASK" status "$JOB_ID" --json --cwd "$PROJECT_ROOT" 2>/dev/null || true)"
  else
    raw="$(bash "$CODEX_TASK" status --all --json --cwd "$PROJECT_ROOT" 2>/dev/null || true)"
  fi
fi

python3 - "$raw" "$JOB_ID" "$PROJECT_ROOT" <<'PY'
import json, sys
raw, wanted, root = sys.argv[1:]
out = {"provider": "codex", "precedence": "authoritative_provider_status", "jobs": [], "availability": "unavailable"}
try:
    payload = json.loads(raw)
    jobs = []
    if wanted:
        job = payload.get("job") if isinstance(payload, dict) else None
        jobs = [job] if isinstance(job, dict) else []
    elif isinstance(payload, dict):
        jobs = list(payload.get("running") or [])
        if payload.get("latestFinished"):
            jobs.append(payload["latestFinished"])
        jobs.extend(payload.get("recent") or [])
    for job in jobs:
        status = str(job.get("status") or "unknown").lower()
        phase = str(job.get("phase") or status or "unknown").lower()
        # Provider statuses are facts. Never convert absent sidecars/processes
        # into dead; unknown stays unknown rather than dead.
        verdict = {"queued": "running", "running": "running", "completed": "done",
                   "done": "done", "cancelled": "cancelled", "failed": "failed"}.get(status, "unknown")
        out["jobs"].append({"id": job.get("id", "?"), "status": status,
                            "phase": phase, "verdict": verdict,
                            "started_at": job.get("startedAt") or job.get("createdAt"),
                            "updated_at": job.get("updatedAt"),
                            "reason": job.get("reason") or job.get("error") or job.get("message"),
                            "source": "codex-task.sh status"})
    out["availability"] = "authoritative" if isinstance(payload, dict) else "unavailable"
except Exception:
    pass
print(json.dumps(out))
PY
