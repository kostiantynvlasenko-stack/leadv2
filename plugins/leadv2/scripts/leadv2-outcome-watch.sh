#!/usr/bin/env bash
# leadv2-outcome-watch.sh — schedule or execute a post-deploy outcome check.
#
# TWO modes:
#   --schedule  Write a pending watch marker to docs/leadv2/watches/<task-id>.yaml
#               Called at Phase 8 close (background, fire-and-forget).
#               Accepts --deploy-class <Standard|Heavy|Light> to load delays from
#               plugins/leadv2/config/soak-class-delays.yaml (D22/C2.1).
#   --sweep     Check all due pending watches, run the override outcome-watch.sh
#               (if present in .claude/leadv2-overrides/), and flip outcome_watch
#               in LEAD_V2_STATE.md history to stable|regression|inconclusive.
#               Called by leadv2-stale-sweeper.sh at every SessionStart.
#
# Usage:
#   # Schedule (Phase 8 close, Heavy tasks):
#   bash leadv2-outcome-watch.sh --schedule --task-id <task-id> [--delay-hours 48]
#   bash leadv2-outcome-watch.sh --schedule --task-id <task-id> --deploy-class Standard
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

# Canonical soak config (D22): resolved relative to plugin canonical path.
# Falls back to LEADV2_PROJECT_ROOT if CLAUDE_PLUGIN_ROOT is not set.
_SOAK_CONFIG_CANDIDATES=(
  "${CLAUDE_PLUGIN_ROOT:-}/config/soak-class-delays.yaml"
  "${SCRIPT_DIR}/../config/soak-class-delays.yaml"
  "${LEADV2_PROJECT_ROOT}/.claude/plugins/cache/leadv2-local/leadv2/0.1.0/config/soak-class-delays.yaml"
)
SOAK_CLASS_DELAYS_YAML=""
for _c in "${_SOAK_CONFIG_CANDIDATES[@]}"; do
  if [[ -f "$_c" ]]; then
    SOAK_CLASS_DELAYS_YAML="$_c"
    break
  fi
done

MODE=""
TASK_ID=""
DELAY_HOURS=48
DEPLOY_CLASS=""
AUTO_ROLLBACK=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --schedule)       MODE="schedule"; shift ;;
    --sweep)          MODE="sweep"; shift ;;
    --task-id)        TASK_ID="$2"; shift 2 ;;
    --delay-hours)    DELAY_HOURS="$2"; shift 2 ;;
    --deploy-class)   DEPLOY_CLASS="$2"; shift 2 ;;
    --auto-rollback)  AUTO_ROLLBACK=true; shift ;;
    -h|--help)
      printf -- 'Usage: %s --schedule --task-id <id> [--deploy-class Standard|Heavy|Light] [--delay-hours N]\n' "$(basename "$0")" >&2
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

  MIN_HOURS_BEFORE_CHECK=0

  # C2.1: if --deploy-class given, load delays from soak-class-delays.yaml (D22)
  if [[ -n "$DEPLOY_CLASS" ]]; then
    if [[ -z "$SOAK_CLASS_DELAYS_YAML" ]]; then
      log_error "soak-class-delays.yaml not found — cannot resolve --deploy-class ${DEPLOY_CLASS}"
      exit 1
    fi
    # Read delay_hours and min_hours_before_check from YAML
    _class_config=$(python3 - "$SOAK_CLASS_DELAYS_YAML" "$DEPLOY_CLASS" <<'PYEOF'
import sys, yaml
config_file, deploy_class = sys.argv[1], sys.argv[2]
with open(config_file) as f:
    cfg = yaml.safe_load(f) or {}
cls = cfg.get(deploy_class)
if cls is None:
    print(f"ERROR: class '{deploy_class}' not found in soak-class-delays.yaml", file=sys.stderr)
    sys.exit(1)
if cls.get("skip"):
    print("SKIP")
    sys.exit(0)
delay = int(cls.get("delay_hours", 48))
min_h = int(cls.get("min_hours_before_check", delay))
print(f"{delay}:{min_h}")
PYEOF
    ) || { log_error "Failed to read soak config for class=${DEPLOY_CLASS}"; exit 1; }

    if [[ "$_class_config" == "SKIP" ]]; then
      log "class=${DEPLOY_CLASS} has skip=true — no watch scheduled for task=${TASK_ID}"
      exit 0
    fi
    DELAY_HOURS="${_class_config%%:*}"
    MIN_HOURS_BEFORE_CHECK="${_class_config##*:}"
    log "class=${DEPLOY_CLASS} delay_hours=${DELAY_HOURS} min_hours_before_check=${MIN_HOURS_BEFORE_CHECK}"
  fi

  mkdir -p "$WATCHES_DIR"
  due_at=$(python3 -c "
import datetime, sys
hours = int(sys.argv[1])
due = datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(hours=hours)
print(due.strftime('%Y-%m-%dT%H:%M:%SZ'))
" "$DELAY_HOURS")

  watch_file="${WATCHES_DIR}/${TASK_ID}.yaml"
  tmp_file="${watch_file}.tmp.$$"

  python3 - "$watch_file" "$tmp_file" "$TASK_ID" "$due_at" "$DELAY_HOURS" \
      "$DEPLOY_CLASS" "$MIN_HOURS_BEFORE_CHECK" "$AUTO_ROLLBACK" <<'PYEOF'
import sys, yaml, os, datetime

watch_file, tmp_file, task_id, due_at, delay_hours, deploy_class, min_hours, auto_rollback = sys.argv[1:]

# If watch already exists and is not pending, don't overwrite
if os.path.exists(watch_file):
    with open(watch_file) as f:
        existing = yaml.safe_load(f) or {}
    if existing.get("status") in ("stable", "regression", "inconclusive", "rolled_back"):
        print(f"[outcome-watch] watch for {task_id} already resolved ({existing['status']}) — skip", file=sys.stderr)
        sys.exit(0)

doc = {
    "task_id": task_id,
    "status": "pending",
    "scheduled_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "due_at": due_at,
    "delay_hours": int(delay_hours),
    "min_hours_before_check": int(min_hours) if min_hours else 0,
    "deploy_class": deploy_class if deploy_class else None,
    "auto_rollback": auto_rollback.lower() == "true",
    "result": None,
    "checked_at": None,
    "notes": None,
}
with open(tmp_file, "w") as f:
    yaml.dump(doc, f, default_flow_style=False, allow_unicode=True, sort_keys=False)
os.replace(tmp_file, watch_file)
print(f"[outcome-watch] scheduled watch for {task_id} due {due_at} class={deploy_class or 'unset'}", file=sys.stderr)
PYEOF

  log "watch scheduled: task=${TASK_ID} due=${due_at} (${DELAY_HOURS}h) class=${DEPLOY_CLASS:-unset}"
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

    # D18 (C2.4): check context.yaml exists before proceeding
    context_yaml="${LEADV2_PROJECT_ROOT}/docs/handoff/${task_id}/context.yaml"
    if [[ ! -f "$context_yaml" ]]; then
      log "task=${task_id} context.yaml missing — skip with context_missing"
      continue
    fi

    # D22 (C2.4): enforce min_hours_before_check from watch YAML
    watch_min_hours=$(python3 - "$watch_file" <<'PYEOF'
import sys, yaml, os
f = sys.argv[1]
if not os.path.exists(f):
    print(0)
    sys.exit(0)
with open(f) as fh:
    d = yaml.safe_load(fh) or {}
print(int(d.get("min_hours_before_check") or 0))
PYEOF
    ) || watch_min_hours=0

    if [[ "$watch_min_hours" -gt 0 ]]; then
      elapsed_ok=$(python3 - "$watch_file" "$watch_min_hours" <<'PYEOF'
import sys, yaml, os, time
from datetime import datetime, timezone
f, min_h = sys.argv[1], int(sys.argv[2])
if not os.path.exists(f):
    print("ok")
    sys.exit(0)
with open(f) as fh:
    d = yaml.safe_load(fh) or {}
sched = d.get("scheduled_at", "")
if not sched:
    print("ok")
    sys.exit(0)
try:
    ts = datetime.fromisoformat(sched.rstrip("Z")).replace(tzinfo=timezone.utc).timestamp()
    elapsed_h = (time.time() - ts) / 3600
    print("ok" if elapsed_h >= min_h else f"too_early:{elapsed_h:.1f}h_of_{min_h}h")
except Exception:
    print("ok")
PYEOF
      ) || elapsed_ok="ok"

      if [[ "$elapsed_ok" != "ok" ]]; then
        log "task=${task_id} min_hours_before_check not met (${elapsed_ok}) — skip"
        continue
      fi
    fi

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
      # C2.6/D15: no override script for Standard/Heavy task → inconclusive (not stable)
      # Check deploy_class from watch YAML to decide stable vs inconclusive
      watch_deploy_class=$(python3 - "$watch_file" <<'PYEOF'
import sys, yaml, os
f = sys.argv[1]
if not os.path.exists(f):
    print("")
    sys.exit(0)
with open(f) as fh:
    d = yaml.safe_load(fh) or {}
print(d.get("deploy_class") or "")
PYEOF
      ) || watch_deploy_class=""

      if [[ "$watch_deploy_class" == "Standard" || "$watch_deploy_class" == "Heavy" ]]; then
        log "task=${task_id} class=${watch_deploy_class} no override outcome-watch.sh — marking inconclusive (D15)"
        outcome_result="inconclusive"
        outcome_notes="no override script for class=${watch_deploy_class} — inconclusive"
      else
        log "task=${task_id} no override outcome-watch.sh — marking stable (no VPS/service to check)"
        outcome_result="stable"
        outcome_notes="no override script — assumed stable"
      fi
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

    if [[ "$outcome_result" == "inconclusive" ]]; then
      # C2.6/D15: inconclusive — no scorecard patch, no regression signal
      log "task=${task_id} outcome=inconclusive — skipping scorecard patch (D15)"
    elif [[ "$outcome_result" == "regression" ]]; then
      log_error "REGRESSION detected for task=${task_id} — review ${watch_file}"

      # C2.4/D12: soak-rollback dispatch or human-needed lane
      _watch_deploy_class_rb=$(python3 - "$watch_file" <<'RB_PYEOF'
import sys, yaml, os
f = sys.argv[1]
if not os.path.exists(f):
    print("")
    sys.exit(0)
with open(f) as fh:
    d = yaml.safe_load(fh) or {}
print(d.get("deploy_class") or "")
RB_PYEOF
      ) || _watch_deploy_class_rb=""

      _watch_auto_rollback=$(python3 - "$watch_file" <<'RB_PYEOF'
import sys, yaml, os
f = sys.argv[1]
if not os.path.exists(f):
    print("false")
    sys.exit(0)
with open(f) as fh:
    d = yaml.safe_load(fh) or {}
print("true" if d.get("auto_rollback") else "false")
RB_PYEOF
      ) || _watch_auto_rollback="false"

      _rollback_executed=false
      if [[ "$_watch_auto_rollback" == "true" ]]; then
        if [[ "$_watch_deploy_class_rb" == "Standard" ]] && [[ "${LEADV2_SOAK_AUTOROLLBACK_STANDARD:-0}" != "1" ]]; then
          # D12: Standard auto-rollback requires explicit opt-in; open human-needed lane instead
          log "task=${task_id} Standard regression — LEADV2_SOAK_AUTOROLLBACK_STANDARD not set; opening human-needed lane"
          _open_human_needed_lane=true
        else
          # Heavy (or Standard with opt-in): call soak-rollback wrapper
          SOAK_ROLLBACK_SCRIPT=""
          if [[ -n "${CLAUDE_PLUGIN_ROOT:-}" && -f "${CLAUDE_PLUGIN_ROOT}/scripts/leadv2-soak-rollback.sh" ]]; then
            SOAK_ROLLBACK_SCRIPT="${CLAUDE_PLUGIN_ROOT}/scripts/leadv2-soak-rollback.sh"
          elif [[ -f "${SCRIPT_DIR}/leadv2-soak-rollback.sh" ]]; then
            SOAK_ROLLBACK_SCRIPT="${SCRIPT_DIR}/leadv2-soak-rollback.sh"
          fi
          if [[ -n "$SOAK_ROLLBACK_SCRIPT" ]]; then
            log "task=${task_id} executing soak-rollback: ${SOAK_ROLLBACK_SCRIPT}"
            if LEADV2_TASK_ID="$task_id" LEADV2_PROJECT_ROOT="$LEADV2_PROJECT_ROOT"                 bash "$SOAK_ROLLBACK_SCRIPT" 2>&1 | while IFS= read -r line; do log "$line"; done; then
              _rollback_executed=true
              # Mark watch as rolled_back (terminal)
              python3 - "$watch_file" <<'RB2_PYEOF'
import sys, yaml, os, tempfile
f = sys.argv[1]
if not os.path.exists(f):
    sys.exit(0)
with open(f) as fh:
    d = yaml.safe_load(fh) or {}
d["status"] = "rolled_back"
dir_ = os.path.dirname(f)
tmp_fd, tmp_path = tempfile.mkstemp(dir=dir_, suffix=".tmp")
with os.fdopen(tmp_fd, "w") as tf:
    yaml.dump(d, tf, default_flow_style=False, allow_unicode=True, sort_keys=False)
os.replace(tmp_path, f)
RB2_PYEOF
              log "task=${task_id} watch marked rolled_back (terminal)"
            else
              log_error "task=${task_id} soak-rollback failed — manual intervention required"
              _open_human_needed_lane=true
            fi
          else
            log_error "task=${task_id} leadv2-soak-rollback.sh not found — opening human-needed lane"
            _open_human_needed_lane=true
          fi
        fi
      else
        # auto_rollback=false: always open human-needed lane on regression
        _open_human_needed_lane=true
      fi

      # Open human-needed lane entry if rollback was not executed
      if [[ "${_open_human_needed_lane:-false}" == "true" && "$_rollback_executed" == "false" ]]; then
        log "task=${task_id} opening human-needed lane entry (needs_human)"
        # Add needs_human task to tasks queue via tasks-lib if available
        _TASKS_LIB=""
        if [[ -n "${CLAUDE_PLUGIN_ROOT:-}" && -f "${CLAUDE_PLUGIN_ROOT}/scripts/leadv2-tasks-lib.sh" ]]; then
          _TASKS_LIB="${CLAUDE_PLUGIN_ROOT}/scripts/leadv2-tasks-lib.sh"
        elif [[ -f "${SCRIPT_DIR}/leadv2-tasks-lib.sh" ]]; then
          _TASKS_LIB="${SCRIPT_DIR}/leadv2-tasks-lib.sh"
        fi
        if [[ -n "$_TASKS_LIB" ]]; then
          LEADV2_PROJECT_ROOT="$LEADV2_PROJECT_ROOT"             bash "$_TASKS_LIB" add               --id "SOAK-REGRESSION-${task_id}"               --status needs_human               --class Standard               --brief "Soak regression detected for ${task_id} — manual rollback or review required"           2>/dev/null           && log "task=${task_id} needs_human entry added to queue"           || log "WARN: tasks-lib add failed for needs_human entry (non-blocking)"
        else
          log "WARN: leadv2-tasks-lib.sh not found — human-needed lane entry not added"
        fi
      fi

      # Emit scorecard patch record for post_deploy_regression backfill.
      # C2.6/D15: patch is skipped for inconclusive (handled above).
      SCORECARD_WRITE_SCRIPT=""
      # Resolve via plugin canonical path if CLAUDE_PLUGIN_ROOT is set
      if [[ -n "${CLAUDE_PLUGIN_ROOT:-}" && -f "${CLAUDE_PLUGIN_ROOT}/scripts/leadv2-scorecard-write.sh" ]]; then
        SCORECARD_WRITE_SCRIPT="${CLAUDE_PLUGIN_ROOT}/scripts/leadv2-scorecard-write.sh"
      elif [[ -f "${LEADV2_PROJECT_ROOT}/.claude/scripts/leadv2-scorecard-write.sh" ]]; then
        SCORECARD_WRITE_SCRIPT="${LEADV2_PROJECT_ROOT}/.claude/scripts/leadv2-scorecard-write.sh"
      fi

      if [[ -n "$SCORECARD_WRITE_SCRIPT" ]]; then
        LEADV2_PROJECT_ROOT="$LEADV2_PROJECT_ROOT" \
          bash "$SCORECARD_WRITE_SCRIPT" \
            --task-id "$task_id" \
            --patch \
            --post-deploy-regression 1 \
        && log "scorecard patch record emitted: task=${task_id} post_deploy_regression=1" \
        || log "WARN: scorecard patch failed for task=${task_id} (non-blocking)"
      else
        log "WARN: leadv2-scorecard-write.sh not found — skipping patch record for task=${task_id}"
      fi
    fi

  done < <(ls -1 "$WATCHES_DIR"/*.yaml 2>/dev/null | tr '\n' '\0' | xargs -0 -I{} printf '%s\0' {} 2>/dev/null || true)

  if [[ "$had_regression" -eq 1 ]]; then
    exit 1
  fi
  exit 0
fi
