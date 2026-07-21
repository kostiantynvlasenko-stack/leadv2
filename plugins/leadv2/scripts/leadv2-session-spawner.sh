#!/usr/bin/env bash
# leadv2-session-spawner.sh — compatibility entrypoint for autonomous child
# dispatch. All launches delegate to leadv2-fanout.sh so self-spawn, daemon,
# and interactive supervise use the same classifier, provider router,
# active-registry schema, Phase 0..8 runner, and completion contract.
#
# Usage:
#   leadv2-session-spawner.sh [--dry-run] [--wait] <task_id>
#
# Environment:
#   LEADV2_PROJECT_ROOT               project root
#   LEADV2_SPAWN_PROVIDER             auto|claude|codex (default auto)
#   LEADV2_SPAWN_MODEL                optional explicit model override
#   LEADV2_SPAWN_BUDGET               Claude per-attempt USD ceiling
#   LEADV2_SPAWN_PERMISSION_MODE      Claude permission mode override
#   LEADV2_MAX_SELF_SPAWNS_PER_DAY    default 4
#   LEADV2_SPAWN_WAIT_TIMEOUT_S       default 7200 when --wait is used
#   LEADV2_SPAWN_WAIT_POLL_S          default 5

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${LEADV2_PROJECT_ROOT:-${CLAUDE_PROJECT_DIR:-${PROJECT_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}}}"
FANOUT="${LEADV2_FANOUT_BIN:-$SCRIPT_DIR/leadv2-fanout.sh}"
STATE_PATH="${LEADV2_STATE_PATH_BIN:-$SCRIPT_DIR/leadv2-state-path.sh}"

log() { printf -- '[spawner] %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

DRY_RUN=false
WAIT_FOR_CLOSE="${LEADV2_SPAWN_WAIT:-0}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --wait) WAIT_FOR_CLOSE=1; shift ;;
    -h|--help)
      sed -n '2,19p' "$0"
      exit 0
      ;;
    --*) die "unknown option: $1" ;;
    *) break ;;
  esac
done

TASK_ID="${1:-}"
[[ -n "$TASK_ID" && $# -eq 1 ]] || die "usage: leadv2-session-spawner.sh [--dry-run] [--wait] <task_id>"
[[ -x "$FANOUT" ]] || die "provider-neutral fanout missing/not executable: $FANOUT"

PROVIDER="${LEADV2_SPAWN_PROVIDER:-${LEADV2_SESSION_PROVIDER:-auto}}"
case "$PROVIDER" in
  auto|claude|codex) ;;
  *) die "LEADV2_SPAWN_PROVIDER must be auto, claude, or codex (got: $PROVIDER)" ;;
esac

# Daily cap lives in the shared control plane; worktree-local spawned/ folders
# previously let parallel sessions each believe they had their own fresh cap.
SPAWNED_DIR="$(PROJECT_ROOT="$PROJECT_ROOT" "$STATE_PATH" --no-link spawned)"
mkdir -p "$SPAWNED_DIR"
MAX_SPAWNS_PER_DAY="${LEADV2_MAX_SELF_SPAWNS_PER_DAY:-4}"
TODAY_UTCZ="$(date -u +%Y%m%d)"
SPAWN_COUNT="$(find "$SPAWNED_DIR" -maxdepth 1 -name "${TODAY_UTCZ}-*.json" 2>/dev/null | wc -l | tr -d ' ')"
if (( SPAWN_COUNT >= MAX_SPAWNS_PER_DAY )); then
  die "daily spawn cap reached (${SPAWN_COUNT}/${MAX_SPAWNS_PER_DAY})"
fi

fanout_args=(--tasks "$TASK_ID" --n 1 --provider "$PROVIDER" --headless)
[[ "$DRY_RUN" == "true" ]] && fanout_args+=(--dry-run)
[[ -n "${LEADV2_SPAWN_MODEL:-}" ]] && fanout_args+=(--lead-model "$LEADV2_SPAWN_MODEL")

log "delegating task=${TASK_ID} provider=${PROVIDER} to the common full-cycle fanout"
export LEADV2_PROJECT_ROOT="$PROJECT_ROOT"
export LEADV2_DAEMON=1
export LEADV2_ASYNC_QUESTIONS=1
export LEADV2_CLAUDE_MAX_BUDGET_USD="${LEADV2_CLAUDE_MAX_BUDGET_USD:-${LEADV2_SPAWN_BUDGET:-}}"
export LEADV2_CLAUDE_PERMISSION_MODE="${LEADV2_CLAUDE_PERMISSION_MODE:-${LEADV2_SPAWN_PERMISSION_MODE:-acceptEdits}}"
"$FANOUT" "${fanout_args[@]}"

if [[ "$DRY_RUN" == "true" ]]; then
  exit 0
fi

SPAWN_ID="${TODAY_UTCZ}-$(date -u +%H%M%S)-$$"
SPAWN_RECORD="${SPAWNED_DIR}/${SPAWN_ID}.json"
python3 - "$SPAWN_RECORD" "$SPAWN_ID" "$TASK_ID" "$PROVIDER" <<'PYEOF'
import datetime, json, os, sys, tempfile
path, spawn_id, task_id, provider = sys.argv[1:]
payload = {
    "schema_version": 2,
    "spawn_id": spawn_id,
    "task_id": task_id,
    "requested_provider": provider,
    "status": "dispatched",
    "dispatched_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
}
fd, tmp = tempfile.mkstemp(prefix=".spawn.", suffix=".tmp", dir=os.path.dirname(path))
with os.fdopen(fd, "w", encoding="utf-8") as fh:
    json.dump(payload, fh, indent=2, sort_keys=True)
    fh.write("\n")
os.replace(tmp, path)
PYEOF

if [[ "$WAIT_FOR_CLOSE" != "1" && "$WAIT_FOR_CLOSE" != "true" ]]; then
  log "dispatched ${TASK_ID}; receipt=${SPAWN_RECORD}"
  exit 0
fi

COMPLETION_RECEIPT="$(PROJECT_ROOT="$PROJECT_ROOT" "$STATE_PATH" --no-link "completions/${TASK_ID}.json")"
LOCAL_SENTINEL="$PROJECT_ROOT/docs/handoff/$TASK_ID/phase8-passed.flag"
RUNNER_PID_FILE="$PROJECT_ROOT/docs/handoff/$TASK_ID/.session-runner.pid"
WAIT_TIMEOUT_S="${LEADV2_SPAWN_WAIT_TIMEOUT_S:-7200}"
WAIT_POLL_S="${LEADV2_SPAWN_WAIT_POLL_S:-5}"
START_EPOCH="$(date +%s)"
SAW_RUNNER=false

completion_valid() {
  [[ -f "$LOCAL_SENTINEL" ]] && return 0
  [[ -f "$COMPLETION_RECEIPT" ]] || return 1
  python3 - "$COMPLETION_RECEIPT" "$TASK_ID" <<'PYEOF' >/dev/null 2>&1
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
raise SystemExit(0 if data.get("schema_version") == 1
                 and data.get("task_id") == sys.argv[2]
                 and data.get("status") == "phase8_passed"
                 and data.get("assertions") == "7/7" else 1)
PYEOF
}

while true; do
  if completion_valid; then
    log "task=${TASK_ID} reached validated Phase-8 completion"
    exit 0
  fi

  if [[ -s "$RUNNER_PID_FILE" ]]; then
    runner_pid="$(tr -d '[:space:]' < "$RUNNER_PID_FILE")"
    if [[ "$runner_pid" =~ ^[0-9]+$ ]] && kill -0 "$runner_pid" 2>/dev/null; then
      SAW_RUNNER=true
    elif [[ "$SAW_RUNNER" == "true" ]]; then
      die "runner pid=${runner_pid:-unknown} exited without validated Phase-8 completion"
    fi
  fi

  now_epoch="$(date +%s)"
  if (( now_epoch - START_EPOCH >= WAIT_TIMEOUT_S )); then
    die "timed out after ${WAIT_TIMEOUT_S}s waiting for task=${TASK_ID} completion"
  fi
  sleep "$WAIT_POLL_S"
done
