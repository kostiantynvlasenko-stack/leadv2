#!/usr/bin/env bash
# leadv2-stale-sweeper.sh — Sweep active.yaml for stale sessions at /leadv2 startup.
#
# Usage: leadv2-stale-sweeper.sh [--non-interactive]
#
# What it does:
#   1. Load active.yaml
#   2. For each session: if last_pulse_at > 2h ago AND kill -0 <pid> fails → mark stale
#   3. Reconcile spawned/ vs active.yaml: ghost-spawn detection
#   4. Print summary
#   5. If stale found: prompt "recover / abandon?" (interactive only)
#   6. Reset daily quota if budget.yaml.date != today UTC

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LEADV2_PROJECT_ROOT="${LEADV2_PROJECT_ROOT:-${PROJECT_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}}"

# Source registry for mark_stale op
# shellcheck source=leadv2-active-registry.sh
source "$SCRIPT_DIR/leadv2-active-registry.sh"

log() { printf -- '[sweeper] %s\n' "$*" >&2; }

# ── Determine interactive mode ─────────────────────────────────────────────
INTERACTIVE=true
if [[ "${1:-}" == "--non-interactive" ]] || [[ ! -t 0 ]]; then
  INTERACTIVE=false
fi

YAML_FILE="${LEADV2_PROJECT_ROOT}/docs/leadv2/active.yaml"
SPAWNED_DIR="${LEADV2_PROJECT_ROOT}/docs/leadv2/spawned"
BUDGET_YAML="${LEADV2_PROJECT_ROOT}/docs/leadv2/budget.yaml"
QUOTA_SCRIPT="${SCRIPT_DIR}/leadv2-quota-status.sh"
STALE_THRESHOLD_SEC=7200  # 2 hours

# ── 1 + 2: Load active.yaml, detect stale sessions ────────────────────────
stale_task_ids=()

python3 - "$YAML_FILE" "$STALE_THRESHOLD_SEC" <<'PYEOF' > /tmp/leadv2-sweep-result.$$.json
import sys, os, json, time
from datetime import datetime, timezone

try:
    import yaml
except ImportError:
    print("[]")
    sys.exit(0)

yaml_file, threshold_str = sys.argv[1], sys.argv[2]
threshold_sec = int(threshold_str)
now_ts = time.time()

if not os.path.exists(yaml_file):
    print("[]")
    sys.exit(0)

with open(yaml_file, encoding="utf-8") as fh:
    data = yaml.safe_load(fh) or {}

sessions = data.get("sessions") or []
stale_results = []

for s in sessions:
    task_id = s.get("task_id", "?")
    pid = s.get("pid")
    last_pulse = s.get("last_pulse_at") or s.get("started_at") or ""
    already_stale = s.get("stale", False)

    if already_stale:
        continue

    # Check pid liveness
    pid_dead = True
    if pid is not None:
        try:
            os.kill(int(pid), 0)
            pid_dead = False
        except (ProcessLookupError, PermissionError):
            pid_dead = True
        except (TypeError, ValueError):
            pid_dead = True

    # Check pulse age
    pulse_old = True
    if last_pulse:
        try:
            # Parse ISO-Z timestamp
            ts_str = last_pulse.rstrip("Z")
            ts = datetime.fromisoformat(ts_str).replace(tzinfo=timezone.utc)
            age_sec = now_ts - ts.timestamp()
            pulse_old = age_sec > threshold_sec
        except (ValueError, TypeError):
            pulse_old = True

    if pid_dead and pulse_old:
        stale_results.append({
            "task_id": task_id,
            "pid": pid,
            "last_pulse_at": last_pulse,
        })

print(json.dumps(stale_results))
PYEOF

stale_json=$(cat /tmp/leadv2-sweep-result.$$.json)
rm -f /tmp/leadv2-sweep-result.$$.json

stale_count=0
if python3 -c "import sys,json; d=json.loads(sys.stdin.read()); sys.exit(0 if d else 1)" <<< "$stale_json" 2>/dev/null; then
  stale_count=$(python3 -c "import sys,json; print(len(json.loads(sys.stdin.read())))" <<< "$stale_json")
  # Mark stale in active.yaml
  mapfile -t stale_task_ids < <(python3 -c "import sys,json; [print(s['task_id']) for s in json.loads(sys.stdin.read())]" <<< "$stale_json")
  for tid in "${stale_task_ids[@]+"${stale_task_ids[@]}"}"; do
    _leadv2_yaml_py_lock "$(_leadv2_yaml_lockfile)" "$YAML_FILE" mark_stale "$tid"
    log "marked stale: $tid"
  done
fi

# ── 3: Reconcile spawned/ vs active.yaml ──────────────────────────────────
ghost_count=0
if [[ -d "$SPAWNED_DIR" ]]; then
  now_epoch=$(date -u +%s)
  while IFS= read -r -d '' spawn_file; do
    sid=$(basename "$spawn_file" .json)
    # Parse started_at and pid from spawn file
    spawn_data=$(python3 -c "
import sys, json, os
with open(sys.argv[1]) as f:
    d = json.load(f)
print(d.get('started_at',''))
print(d.get('pid',''))
print(d.get('task_id',''))
" "$spawn_file" 2>/dev/null) || continue

    started_at=$(printf '%s' "$spawn_data" | sed -n '1p')
    spawn_pid=$(printf '%s' "$spawn_data" | sed -n '2p')
    spawn_tid=$(printf '%s' "$spawn_data" | sed -n '3p')

    # Check if > 5 min old
    if [[ -n "$started_at" ]]; then
      spawn_epoch=$(python3 -c "
import sys
from datetime import datetime, timezone
ts = sys.argv[1].rstrip('Z')
try:
    dt = datetime.fromisoformat(ts).replace(tzinfo=timezone.utc)
    print(int(dt.timestamp()))
except Exception:
    print(0)
" "$started_at" 2>/dev/null) || spawn_epoch=0
      age=$(( now_epoch - spawn_epoch ))
    else
      age=999
    fi

    if [[ "$age" -lt 300 ]]; then
      continue  # too new to judge
    fi

    # Check if in active.yaml
    in_active=$(python3 -c "
import sys, os, yaml
f = sys.argv[1]
sid = sys.argv[2]
if not os.path.exists(f):
    print('no')
    sys.exit(0)
with open(f) as fh:
    d = yaml.safe_load(fh) or {}
sessions = d.get('sessions') or []
found = any(s.get('session_id') == sid for s in sessions)
print('yes' if found else 'no')
" "$YAML_FILE" "$sid" 2>/dev/null) || in_active="no"

    if [[ "$in_active" == "no" ]]; then
      # Check pid liveness
      pid_alive=false
      if [[ -n "$spawn_pid" ]] && kill -0 "$spawn_pid" 2>/dev/null; then
        pid_alive=true
      fi
      if [[ "$pid_alive" == "false" ]]; then
        log "ghost-spawn $sid (task=${spawn_tid:-?}, age=${age}s)"
        ghost_count=$(( ghost_count + 1 ))
      fi
    fi
  done < <(find "$SPAWNED_DIR" -maxdepth 1 -name "*.json" -print0 2>/dev/null)
fi

# ── 4: Print summary ───────────────────────────────────────────────────────
if [[ "$stale_count" -eq 0 && "$ghost_count" -eq 0 ]]; then
  log "all sessions current"
else
  log "${stale_count} stale session(s) found, ${ghost_count} ghost-spawn(s)"
fi

# ── 5: Interactive recover/abandon prompt ─────────────────────────────────
if [[ "$stale_count" -gt 0 && "$INTERACTIVE" == "true" ]]; then
  echo "[sweeper] Stale task IDs:"
  for tid in "${stale_task_ids[@]+"${stale_task_ids[@]}"}"; do
    echo "  - $tid"
  done
  printf -- 'recover / abandon? [recover/abandon/skip]: '
  read -r answer
  case "${answer:-skip}" in
    recover|r)
      log "recover selected — keeping stale rows for manual inspection"
      ;;
    abandon|a)
      log "abandon selected — removing stale rows"
      for tid in "${stale_task_ids[@]+"${stale_task_ids[@]}"}"; do
        leadv2_active_unregister "$tid"
        log "removed stale row: $tid"
      done
      ;;
    *)
      log "skipped — stale rows remain marked"
      ;;
  esac
fi

# ── 6: Reset budget if date mismatch ──────────────────────────────────────
today_utc=$(date -u +"%Y-%m-%d")

if [[ -f "$BUDGET_YAML" ]]; then
  budget_date=$(python3 -c "
import sys, yaml
with open(sys.argv[1]) as f:
    d = yaml.safe_load(f) or {}
print(d.get('date', ''))
" "$BUDGET_YAML" 2>/dev/null) || budget_date=""

  if [[ "$budget_date" != "$today_utc" ]]; then
    log "budget.yaml date=$budget_date != today=$today_utc — resetting token quota"
    python3 - "$BUDGET_YAML" "$today_utc" <<'PYEOF'
import sys, yaml, tempfile, os
budget_file, today = sys.argv[1], sys.argv[2]
if os.path.exists(budget_file):
    with open(budget_file) as f:
        d = yaml.safe_load(f) or {}
else:
    d = {}
d["date"] = today
d["tokens_used"] = 0
dir_ = os.path.dirname(budget_file)
tmp_fd, tmp_path = tempfile.mkstemp(dir=dir_, suffix=".tmp")
with os.fdopen(tmp_fd, "w") as tf:
    yaml.dump(d, tf, default_flow_style=False)
os.replace(tmp_path, budget_file)
PYEOF
  fi
fi

# Call quota status script if available
if [[ -x "$QUOTA_SCRIPT" ]]; then
  "$QUOTA_SCRIPT" 2>/dev/null || true
fi

# ── GC: remove merged worktrees (safe at every startup) ───────────────────────
log "scanning for merged zombie worktrees..."
WORKTREES_DIR="${LEADV2_PROJECT_ROOT}/.claude/worktrees"
if [[ -d "$WORKTREES_DIR" ]]; then
  while IFS= read -r wt_line; do
    wt_path="${wt_line#worktree }"
    [[ "$wt_path" == "$LEADV2_PROJECT_ROOT" ]] && continue  # skip main worktree
    wt_name=$(basename "$wt_path")
    branch="worktree-${wt_name}"
    # Only remove if branch is fully merged into main
    if git -C "$LEADV2_PROJECT_ROOT" branch --merged main 2>/dev/null | grep -qE "^\*?[[:space:]]+${branch}$"; then
      log "auto-GC merged worktree: $wt_name"
      bash "${SCRIPT_DIR}/leadv2-worktree-cleanup.sh" --name "$wt_name" --force 2>/dev/null || \
        log "GC failed for $wt_name (non-blocking)"
    fi
  done < <(git -C "$LEADV2_PROJECT_ROOT" worktree list --porcelain 2>/dev/null | grep '^worktree ')
fi

exit 0
