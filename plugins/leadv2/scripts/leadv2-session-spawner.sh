#!/usr/bin/env bash
# leadv2-session-spawner.sh — Spawn a new /leadv2 daemon session for a given task.
#
# Usage: leadv2-session-spawner.sh <task_id_to_spawn>
#
# Environment:
#   LEADV2_DAEMON                   — set to 1 in child (passed via env)
#   LEADV2_GATE1_AUTO_ACCEPT_SEC    — auto-accept timeout for child gate1 (default 5)
#   LEADV2_MAX_SELF_SPAWNS_PER_DAY  — daily spawn cap (default 4)
#   LEADV2_PROJECT_ROOT             — project root (default pwd)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LEADV2_PROJECT_ROOT="${LEADV2_PROJECT_ROOT:-${PROJECT_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}}"

# shellcheck source=leadv2-active-registry.sh
source "$SCRIPT_DIR/leadv2-active-registry.sh"

log() { printf -- '[spawner] %s\n' "$*" >&2; }

task_id="${1:?Usage: leadv2-session-spawner.sh <task_id_to_spawn>}"

SPAWNED_DIR="${LEADV2_PROJECT_ROOT}/docs/leadv2/spawned"
SPAWN_LOG_DIR="${LEADV2_PROJECT_ROOT}/docs/leadv2/spawned"
MAX_SPAWNS_PER_DAY="${LEADV2_MAX_SELF_SPAWNS_PER_DAY:-4}"
TODAY_UTCZ=$(date -u +"%Y%m%d")

# ── 1: Check hard limit ────────────────────────────────────────────────────
if ! leadv2_active_check_limits "Standard"; then
  rc=$?
  case "$rc" in
    1) log "ERROR: hard session limit reached — refusing spawn"; exit 1 ;;
    2) log "ERROR: heavy/strategic conflict — refusing spawn"; exit 1 ;;
    *) log "ERROR: limit check failed (rc=$rc) — refusing spawn"; exit 1 ;;
  esac
fi

# ── Daily spawn cap check ──────────────────────────────────────────────────
mkdir -p "$SPAWNED_DIR"
today_spawn_count=0
if [[ -d "$SPAWNED_DIR" ]]; then
  today_spawn_count=$(find "$SPAWNED_DIR" -maxdepth 1 -name "${TODAY_UTCZ}-*.json" 2>/dev/null | wc -l | tr -d ' ')
fi
if [[ "$today_spawn_count" -ge "$MAX_SPAWNS_PER_DAY" ]]; then
  log "ERROR: daily spawn cap reached ($today_spawn_count/$MAX_SPAWNS_PER_DAY) — refusing"
  exit 1
fi

# ── 2: Generate child session ID ──────────────────────────────────────────
CHILD_SID="s-$(date -u +%Y%m%dT%H%M%SZ)-$$"

# ── 3: Write PENDING row to active.yaml BEFORE spawn ──────────────────────
yaml_file="$(_leadv2_yaml_file)"
lockfile="$(_leadv2_yaml_lockfile)"
ts_now="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
worktree="${LEADV2_PROJECT_ROOT}"
branch="$(git -C "$worktree" rev-parse --abbrev-ref HEAD 2>/dev/null || printf -- 'unknown')"
pulse_log="docs/leadv2/tasks/${task_id}/pulse.md"

_leadv2_yaml_py_lock \
  "$lockfile" "$yaml_file" register \
  "$CHILD_SID" "$task_id" "$worktree" "$branch" "$ts_now" \
  "spawning" "Standard" "null" "pending" "$$" \
  "true" "$ts_now" "$pulse_log"

log "pending row written for task=${task_id} sid=${CHILD_SID}"

# ── 4: Create spawned/<CHILD_SID>.json ────────────────────────────────────
mkdir -p "$SPAWNED_DIR"
SPAWN_JSON="${SPAWNED_DIR}/${CHILD_SID}.json"
python3 - "$SPAWN_JSON" "$CHILD_SID" "$task_id" "$ts_now" "$$" <<'PYEOF'
import sys, json
spawn_file, sid, task_id, started_at, parent_pid = sys.argv[1:]
with open(spawn_file, "w") as f:
    json.dump({
        "session_id": sid,
        "task_id": task_id,
        "started_at": started_at,
        "parent_session_id": f"s-parent-{parent_pid}",
        "pid": None,
        "status": "pending",
    }, f, indent=2)
PYEOF
log "spawn record created: $SPAWN_JSON"

# ── 5: Spawn the child session ─────────────────────────────────────────────
SPAWN_LOG="${SPAWN_LOG_DIR}/${CHILD_SID}.log"
mkdir -p "$SPAWN_LOG_DIR"

export LEADV2_DAEMON=1
export LEADV2_GATE1_AUTO_ACCEPT_SEC="${LEADV2_GATE1_AUTO_ACCEPT_SEC:-5}"
export LEADV2_PROJECT_ROOT
export LEADV2_PARENT_SESSION_ID="$CHILD_SID"

setsid nohup claude -p "/leadv2 next" \
  --output-format text \
  --max-turns 50 \
  --permission-mode acceptEdits \
  --max-budget-usd 5 \
  </dev/null \
  >>"$SPAWN_LOG" 2>&1 &

CHILD_PID=$!

# ── 6: Record child PID in spawned/<CHILD_SID>.json ───────────────────────
python3 - "$SPAWN_JSON" "$CHILD_PID" <<'PYEOF'
import sys, json
spawn_file, pid_str = sys.argv[1], sys.argv[2]
with open(spawn_file) as f:
    d = json.load(f)
d["pid"] = int(pid_str)
d["status"] = "running"
with open(spawn_file, "w") as f:
    json.dump(d, f, indent=2)
PYEOF

# Update pid in active.yaml now that we have the real pid
_leadv2_yaml_py_lock \
  "$lockfile" "$yaml_file" update_pulse "$task_id" "$ts_now" 2>/dev/null || true

# ── 7: Print summary ───────────────────────────────────────────────────────
printf -- 'spawned session %s → PID %d for task %s. log: %s\n' \
  "$CHILD_SID" "$CHILD_PID" "$task_id" "$SPAWN_LOG"

exit 0
