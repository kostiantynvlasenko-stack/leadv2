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
# Resolution order: explicit override → CLAUDE_PROJECT_DIR (v2.1.144+) → PROJECT_ROOT → git toplevel → cwd
LEADV2_PROJECT_ROOT="${LEADV2_PROJECT_ROOT:-${CLAUDE_PROJECT_DIR:-${PROJECT_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}}}"

# Source registry for mark_stale op
# shellcheck source=leadv2-active-registry.sh
source "$SCRIPT_DIR/leadv2-active-registry.sh"

log() { printf -- '[sweeper] %s\n' "$*" >&2; }

# ── Determine interactive mode ─────────────────────────────────────────────
INTERACTIVE=true
if [[ "${1:-}" == "--non-interactive" ]] || [[ ! -t 0 ]]; then
  INTERACTIVE=false
fi

_lv2_dir="${LEADV2_LEADV2_DIR:-${LEADV2_PROJECT_ROOT}/docs/leadv2}"
YAML_FILE="${_lv2_dir}/active.yaml"
SPAWNED_DIR="${_lv2_dir}/spawned"
BUDGET_YAML="${_lv2_dir}/budget.yaml"
QUOTA_SCRIPT="${SCRIPT_DIR}/leadv2-quota-status.sh"
STALE_THRESHOLD_SEC=7200  # 2 hours

# ── 1 + 2: Load active.yaml, detect stale sessions ────────────────────────
stale_task_ids=()

# Fetch claude agents --json once per sweep (cached 30s in helper).
# Falls back gracefully on old CLI or missing binary (empty string).
# shellcheck source=leadv2-helpers.sh
source "$SCRIPT_DIR/leadv2-helpers.sh"
_CLAUDE_AGENTS_JSON="$(_leadv2_claude_agents_json 2>/dev/null || true)"

python3 - "$YAML_FILE" "$STALE_THRESHOLD_SEC" "$_CLAUDE_AGENTS_JSON" <<'PYEOF' > /tmp/leadv2-sweep-result.$$.json
import sys, os, json, time
from datetime import datetime, timezone

try:
    import yaml
except ImportError:
    print("[]")
    sys.exit(0)

yaml_file, threshold_str = sys.argv[1], sys.argv[2]
# sys.argv[3]: JSON string from `claude agents --json` (may be empty/absent)
agents_json_str = sys.argv[3] if len(sys.argv) > 3 else ""
threshold_sec = int(threshold_str)
now_ts = time.time()

# Parse live session IDs from `claude agents --json` output.
# Each entry is expected to have an "id" or "session_id" field.
# If parsing fails or output is empty, live_session_ids stays None (= unavailable).
live_session_ids = None  # None means: CLI unavailable, fall back to PID-only
if agents_json_str.strip():
    try:
        agents_data = json.loads(agents_json_str)
        if isinstance(agents_data, list):
            live_session_ids = set()
            for entry in agents_data:
                for key in ("id", "session_id", "sessionId"):
                    val = entry.get(key)
                    if val:
                        live_session_ids.add(str(val))
                        break
    except (json.JSONDecodeError, AttributeError):
        live_session_ids = None  # unavailable, fall back to PID-only

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
    session_id = s.get("session_id", "")
    last_pulse = s.get("last_pulse_at") or s.get("started_at") or ""
    already_stale = s.get("stale", False)

    if already_stale:
        continue

    # Check pid liveness (primary signal — always evaluated)
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

    # Supplementary: check if session_id appears in `claude agents --json` output.
    # Only used as ADDITIONAL evidence — both conditions (pid_dead AND not_in_agents)
    # must hold for this path to mark stale.  If claude agents JSON is unavailable,
    # fall back to legacy PID-only logic unchanged.
    if live_session_ids is not None:
        # High-confidence orphan: PID dead AND not in live agents list
        not_in_agents = (session_id not in live_session_ids)
        if pid_dead and not_in_agents and pulse_old:
            stale_results.append({
                "task_id": task_id,
                "pid": pid,
                "last_pulse_at": last_pulse,
                "orphan_reason": "pid_dead+not_in_agents",
            })
    else:
        # Fallback: legacy PID-only logic (claude agents unavailable)
        if pid_dead and pulse_old:
            stale_results.append({
                "task_id": task_id,
                "pid": pid,
                "last_pulse_at": last_pulse,
                "orphan_reason": "pid_dead_only",
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

# ── 5b: Orphan worktree detection ─────────────────────────────────────────
# A worktree exists on disk but its task_id is NOT in active.yaml. Two sub-cases:
#   (i)  branch is fully merged into main  → cleanup handled by GC at end of file
#   (ii) branch carries unmerged commits   → ambiguous state, surface to founder
# Catches the 2026-05-12..05-19 pattern where Phase 8 close ran but Phase 6 ff-merge
# never landed, so feature commits live only in the worktree branch.
orphan_count=0
orphan_unmerged=()
WORKTREES_DIR_S5b="${LEADV2_PROJECT_ROOT}/.claude/worktrees"
if [[ -d "$WORKTREES_DIR_S5b" ]]; then
  while IFS= read -r wt_line; do
    wt_path="${wt_line#worktree }"
    [[ "$wt_path" == "$LEADV2_PROJECT_ROOT" ]] && continue
    wt_name=$(basename "$wt_path")
    [[ "$wt_name" == .* ]] && continue
    # Is this task in active.yaml?
    in_active=$(python3 -c "
import sys, os
try:
    import yaml
except ImportError:
    print('yes'); sys.exit(0)
f = sys.argv[1]; name = sys.argv[2]
if not os.path.exists(f): print('no'); sys.exit(0)
with open(f) as fh: d = yaml.safe_load(fh) or {}
sessions = d.get('sessions') or []
print('yes' if any(s.get('task_id') == name for s in sessions) else 'no')
" "$YAML_FILE" "$wt_name" 2>/dev/null) || in_active=yes
    [[ "$in_active" == "yes" ]] && continue
    # Skip if branch already merged (handled by GC step at end)
    branch="worktree-${wt_name}"
    if git -C "$LEADV2_PROJECT_ROOT" branch --merged main 2>/dev/null \
        | grep -qE "^\*?[[:space:]]+${branch}$"; then
      continue
    fi
    # Unmerged commits exist
    orphan_count=$(( orphan_count + 1 ))
    last_oneline=$(git -C "$wt_path" log -1 --pretty='%h %s' 2>/dev/null || echo "?")
    orphan_unmerged+=("$wt_name :: $last_oneline")
  done < <(git -C "$LEADV2_PROJECT_ROOT" worktree list --porcelain 2>/dev/null | grep '^worktree ')
fi

if [[ "$orphan_count" -gt 0 ]]; then
  log "$orphan_count orphan worktree(s) with UNMERGED commits (not in active.yaml):"
  for entry in "${orphan_unmerged[@]+"${orphan_unmerged[@]}"}"; do
    log "  - $entry"
  done
  if [[ "$INTERACTIVE" == "true" ]]; then
    printf -- '[sweeper] action for each? [k=keep all / d=discard all / s=skip]: '
    read -r ow_answer
    case "${ow_answer:-s}" in
      d|discard)
        for entry in "${orphan_unmerged[@]+"${orphan_unmerged[@]}"}"; do
          wt_name="${entry%% ::*}"
          bash "${SCRIPT_DIR}/leadv2-worktree-cleanup.sh" --name "$wt_name" --force 2>/dev/null \
            && log "discarded orphan: $wt_name" \
            || log "discard failed: $wt_name (run manually)"
        done
        ;;
      k|keep) log "keeping orphan worktrees — manual review required" ;;
      *) log "skipped — orphans remain (will re-surface next startup)" ;;
    esac
  else
    log "non-interactive — orphans logged only; run /leadv2 with TTY to resolve"
  fi
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

# ── Graveyard scan (weekly — detects DORMANT skills with 0 signal-emission) ───
# Runs at most once per 7 days, tracked by a timestamp marker file.
# On run: re-tallies skill wiring status, writes skill-usage.log, and surfaces
# any skill that has status DORMANT (refs=0 dispatch=0 not in AUTO list).
# Non-blocking: any failure here is logged and skipped.
GRAVEYARD_MARKER="${_lv2_dir}/.graveyard-last-run"
TALLY_SCRIPT="${SCRIPT_DIR}/leadv2-skill-usage-tally.sh"
SKILL_USAGE_LOG="${_lv2_dir}/skill-usage.log"
GRAVEYARD_INTERVAL_DAYS=7

_graveyard_should_run() {
  # Returns 0 (true) if the scan hasn't run in the last GRAVEYARD_INTERVAL_DAYS
  if [[ ! -f "$GRAVEYARD_MARKER" ]]; then
    return 0  # never run — run now
  fi
  local last_run_epoch
  last_run_epoch=$(python3 -c "
import os, sys
try:
    print(int(os.path.getmtime(sys.argv[1])))
except Exception:
    print(0)
" "$GRAVEYARD_MARKER" 2>/dev/null || echo "0")
  local now_epoch
  now_epoch=$(date +%s)
  local elapsed_days=$(( (now_epoch - last_run_epoch) / 86400 ))
  [[ "$elapsed_days" -ge "$GRAVEYARD_INTERVAL_DAYS" ]]
}

if _graveyard_should_run; then
  if [[ -x "$TALLY_SCRIPT" ]]; then
    log "running graveyard scan (weekly)..."
    week_header="# week=$(date -u +%Y-W%V) ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    tally_output=""
    if tally_output=$(
      CLAUDE_PLUGIN_ROOT="${SCRIPT_DIR}/.." bash "$TALLY_SCRIPT" 2>/dev/null
    ); then
      # Prepend week header and write to skill-usage.log
      printf -- '%s\n%s\n' "$week_header" "$tally_output" > "$SKILL_USAGE_LOG"
      # Extract DORMANT skills and surface them
      dormant_skills=$(printf -- '%s\n' "$tally_output" | \
        awk '$2 == "DORMANT" { print $1 }' || true)
      if [[ -n "$dormant_skills" ]]; then
        dormant_count=$(printf -- '%s\n' "$dormant_skills" | wc -l | tr -d ' ')
        log "graveyard scan: ${dormant_count} DORMANT skill(s) with 0 signal-emission:"
        while IFS= read -r skill_name; do
          [[ -z "$skill_name" ]] && continue
          log "  DORMANT: ${skill_name}"
        done <<< "$dormant_skills"
        log "graveyard: review DORMANT skills — wire, inline, or delete per retro"
      else
        log "graveyard scan: no DORMANT skills found — all skills wired or active"
      fi
      # Update marker timestamp regardless of findings
      touch "$GRAVEYARD_MARKER"
      log "graveyard scan complete (next run in ${GRAVEYARD_INTERVAL_DAYS}d)"
    else
      log "graveyard scan: tally script failed — skipping (non-blocking)"
    fi
  else
    log "[skip] graveyard scan: leadv2-skill-usage-tally.sh not found or not executable"
  fi
else
  log "[skip] graveyard scan: last run < ${GRAVEYARD_INTERVAL_DAYS}d ago (marker: ${GRAVEYARD_MARKER})"
fi

# ── Outcome-watch sweep (due watches from past Heavy/Standard closes) ──────────
OUTCOME_WATCH_SCRIPT="${SCRIPT_DIR}/leadv2-outcome-watch.sh"
if [[ -x "$OUTCOME_WATCH_SCRIPT" ]]; then
  log "running outcome-watch sweep..."
  if ! bash "$OUTCOME_WATCH_SCRIPT" --sweep 2>&1 | while IFS= read -r line; do log "$line"; done; then
    log "outcome-watch sweep reported regression(s) — see docs/leadv2/watches/ for details"
  fi
else
  log "[skip] leadv2-outcome-watch.sh not found — skipping sweep"
fi

exit 0
