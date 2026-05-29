#!/usr/bin/env bash
# leadv2-outcome-watch.sh — schedule or execute a 48h post-deploy outcome check.
#
# TWO modes:
#   --schedule  Write a pending watch marker to docs/leadv2/watches/<task-id>.yaml
#               Called at Phase 8 close (background, fire-and-forget).
#   --sweep     Check all due pending watches, run the override outcome-watch.sh
#               (if present in .claude/leadv2-overrides/), and flip outcome_watch
#               in LEAD_V2_STATE.md history to stable|regression.
#               Called by leadv2-stale-sweeper.sh at every SessionStart.
#
# Usage:
#   # Schedule (Phase 8 close, Heavy tasks):
#   bash leadv2-outcome-watch.sh --schedule --task-id <task-id> [--delay-hours 48]
#
#   # Sweep (SessionStart, via stale-sweeper):
#   bash leadv2-outcome-watch.sh --sweep
#
# Exit codes:
#   0  success (schedule written, or sweep completed with no regressions found)
#   1  regression detected during sweep (triggers notification)
#   2  argument error
#
# Files:
#   docs/leadv2/watches/<task-id>.yaml    — pending watch record
#   docs/LEAD_V2_STATE.md                 — outcome_watch field updated in history

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LEADV2_PROJECT_ROOT="${LEADV2_PROJECT_ROOT:-${CLAUDE_PROJECT_DIR:-${PROJECT_ROOT:-$(git -C "$(dirname "$SCRIPT_DIR")" rev-parse --show-toplevel 2>/dev/null || pwd)}}}"

log()       { printf -- '[outcome-watch] %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
log_error() { log "ERROR: $*"; }

WATCHES_DIR="${LEADV2_PROJECT_ROOT}/docs/leadv2/watches"
STATE_MD="${LEADV2_PROJECT_ROOT}/docs/LEAD_V2_STATE.md"
OVERRIDES_DIR="${LEADV2_PROJECT_ROOT}/.claude/leadv2-overrides"

MODE=""
TASK_ID=""
DELAY_HOURS=48

while [[ $# -gt 0 ]]; do
  case "$1" in
    --schedule)    MODE="schedule"; shift ;;
    --sweep)       MODE="sweep"; shift ;;
    --task-id)     TASK_ID="$2"; shift 2 ;;
    --delay-hours) DELAY_HOURS="$2"; shift 2 ;;
    -h|--help)
      printf -- 'Usage: %s --schedule --task-id <id> [--delay-hours N]\n' "$(basename "$0")" >&2
      printf -- '       %s --sweep\n' "$(basename "$0")" >&2
      exit 0
      ;;
    *) log_error "unknown arg: $1"; exit 2 ;;
  esac
done

if [[ -z "$MODE" ]]; then
  log_error "mode required: --schedule or --sweep"
  exit 2
fi

# ── SCHEDULE mode ─────────────────────────────────────────────────────────────
if [[ "$MODE" == "schedule" ]]; then
  if [[ -z "$TASK_ID" ]]; then
    log_error "--task-id required for --schedule"
    exit 2
  fi

  mkdir -p "$WATCHES_DIR"
  due_at=$(python3 -c "
import datetime, sys
hours = int(sys.argv[1])
due = datetime.datetime.utcnow() + datetime.timedelta(hours=hours)
print(due.strftime('%Y-%m-%dT%H:%M:%SZ'))
" "$DELAY_HOURS")

  watch_file="${WATCHES_DIR}/${TASK_ID}.yaml"
  tmp_file="${watch_file}.tmp.$$"

  python3 - "$watch_file" "$tmp_file" "$TASK_ID" "$due_at" "$DELAY_HOURS" <<'PYEOF'
import sys, yaml, os, datetime

watch_file, tmp_file, task_id, due_at, delay_hours = sys.argv[1:]

# If watch already exists and is not pending, don't overwrite
if os.path.exists(watch_file):
    with open(watch_file) as f:
        existing = yaml.safe_load(f) or {}
    if existing.get("status") in ("stable", "regression"):
        print(f"[outcome-watch] watch for {task_id} already resolved ({existing['status']}) — skip", file=sys.stderr)
        sys.exit(0)

doc = {
    "task_id": task_id,
    "status": "pending",
    "scheduled_at": datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
    "due_at": due_at,
    "delay_hours": int(delay_hours),
    "result": None,
    "checked_at": None,
    "notes": None,
}
with open(tmp_file, "w") as f:
    yaml.dump(doc, f, default_flow_style=False, allow_unicode=True, sort_keys=False)
os.replace(tmp_file, watch_file)
print(f"[outcome-watch] scheduled watch for {task_id} due {due_at}", file=sys.stderr)
PYEOF

  log "watch scheduled: task=${TASK_ID} due=${due_at} (${DELAY_HOURS}h)"
  exit 0
fi

# ── SWEEP mode ────────────────────────────────────────────────────────────────
if [[ "$MODE" == "sweep" ]]; then
  if [[ ! -d "$WATCHES_DIR" ]]; then
    log "no watches dir — nothing to sweep"
    exit 0
  fi

  now_epoch=$(python3 -c "import time; print(int(time.time()))")
  had_regression=0

  while IFS= read -r -d '' watch_file; do
    task_id=$(basename "$watch_file" .yaml)

    # Parse status and due_at
    watch_data=$(python3 - "$watch_file" <<'PYEOF'
import sys, yaml, os, time
from datetime import datetime, timezone

f = sys.argv[1]
if not os.path.exists(f):
    print("MISSING")
    sys.exit(0)
with open(f) as fh:
    d = yaml.safe_load(fh) or {}

status = d.get("status", "pending")
due_at_str = d.get("due_at", "")

if status != "pending":
    print(f"SKIP:{status}")
    sys.exit(0)

# Parse due_at
try:
    ts_str = due_at_str.rstrip("Z")
    due_ts = datetime.fromisoformat(ts_str).replace(tzinfo=timezone.utc).timestamp()
    now_ts = time.time()
    if now_ts < due_ts:
        remaining = int(due_ts - now_ts)
        print(f"NOT_DUE:{remaining}")
    else:
        print("DUE")
except Exception as e:
    print(f"PARSE_ERROR:{e}")
PYEOF
    ) || watch_data="PARSE_ERROR:python_failed"

    case "$watch_data" in
      SKIP:*) log "task=${task_id} already resolved (${watch_data#SKIP:}) — skip"; continue ;;
      NOT_DUE:*) log "task=${task_id} not due yet (${watch_data#NOT_DUE:}s remaining) — skip"; continue ;;
      MISSING) log "task=${task_id} watch file missing — skip"; continue ;;
      PARSE_ERROR:*) log_error "task=${task_id} parse error: ${watch_data#PARSE_ERROR:}"; continue ;;
      DUE) ;;
      *) log_error "task=${task_id} unexpected watch_data=${watch_data}"; continue ;;
    esac

    log "task=${task_id} is due — running outcome check"

    # Run override outcome-watch.sh if present
    override_script="${OVERRIDES_DIR}/outcome-watch.sh"
    outcome_result="stable"
    outcome_notes=""

    if [[ -x "$override_script" ]]; then
      log "task=${task_id} running override: ${override_script}"
      if LEADV2_TASK_ID="$task_id" bash "$override_script" >/tmp/outcome-watch-out.$$.txt 2>&1; then
        outcome_result="stable"
        outcome_notes="override exit 0"
      else
        outcome_result="regression"
        outcome_notes="override exit non-zero: $(tail -5 /tmp/outcome-watch-out.$$.txt | tr '\n' ' ')"
        had_regression=1
      fi
      rm -f /tmp/outcome-watch-out.$$.txt
    else
      log "task=${task_id} no override outcome-watch.sh — marking stable (no VPS/service to check)"
      outcome_result="stable"
      outcome_notes="no override script — assumed stable"
    fi

    checked_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    # Update the watch file
    python3 - "$watch_file" "$outcome_result" "$outcome_notes" "$checked_at" <<'PYEOF'
import sys, yaml, os, tempfile

watch_file, result, notes, checked_at = sys.argv[1:]
with open(watch_file) as f:
    d = yaml.safe_load(f) or {}
d["status"] = result
d["result"] = result
d["checked_at"] = checked_at
d["notes"] = notes
dir_ = os.path.dirname(watch_file)
tmp_fd, tmp_path = tempfile.mkstemp(dir=dir_, suffix=".tmp")
with os.fdopen(tmp_fd, "w") as tf:
    yaml.dump(d, tf, default_flow_style=False, allow_unicode=True, sort_keys=False)
os.replace(tmp_path, watch_file)
PYEOF

    # Flip outcome_watch in LEAD_V2_STATE.md history for this task
    if [[ -f "$STATE_MD" ]]; then
      python3 - "$STATE_MD" "$task_id" "$outcome_result" <<'PYEOF'
import sys, re, os, tempfile

state_file, task_id, outcome_result = sys.argv[1:]

with open(state_file) as f:
    content = f.read()

# Strategy: find the history block for this task_id and replace outcome_watch: pending
# Pattern: within a block containing "task: <task_id>", replace "outcome_watch: pending"
# We do a targeted line-by-line scan to stay robust against YAML formatting variation.
lines = content.splitlines(keepends=True)
in_task_block = False
task_pattern = re.compile(r'^\s+task:\s+' + re.escape(task_id) + r'\s*$')
ow_pattern = re.compile(r'^(\s+outcome_watch:\s*)pending(\s*)$')
modified = False

for i, line in enumerate(lines):
    if task_pattern.match(line):
        in_task_block = True
    # A new top-level history entry starts with "  - task:" — reset block tracking
    elif re.match(r'^\s+-\s+task:', line) and not task_pattern.match(line):
        in_task_block = False
    if in_task_block and ow_pattern.match(line):
        lines[i] = ow_pattern.sub(r'\g<1>' + outcome_result + r'\2', line)
        modified = True
        break  # only update the first match in this task block

if modified:
    new_content = "".join(lines)
    dir_ = os.path.dirname(state_file) or "."
    tmp_fd, tmp_path = tempfile.mkstemp(dir=dir_, suffix=".tmp")
    with os.fdopen(tmp_fd, "w") as tf:
        tf.write(new_content)
    os.replace(tmp_path, state_file)
    print(f"[outcome-watch] flipped outcome_watch to {outcome_result} for {task_id} in STATE.md",
          file=sys.stderr)
else:
    print(f"[outcome-watch] WARNING: outcome_watch: pending not found in STATE.md for {task_id}",
          file=sys.stderr)
PYEOF
    fi

    log "task=${task_id} outcome=${outcome_result} notes='${outcome_notes}'"

    if [[ "$outcome_result" == "regression" ]]; then
      log_error "REGRESSION detected for task=${task_id} — review ${watch_file}"
    fi

  done < <(ls -1 "$WATCHES_DIR"/*.yaml 2>/dev/null | tr '\n' '\0' | xargs -0 -I{} printf '%s\0' {} 2>/dev/null || true)

  if [[ "$had_regression" -eq 1 ]]; then
    exit 1
  fi
  exit 0
fi
