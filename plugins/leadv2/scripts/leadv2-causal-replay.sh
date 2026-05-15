#!/usr/bin/env bash
# leadv2-causal-replay.sh — Counterfactual replay: what would have changed if <cause-task> diff was skipped?
#
# Usage:
#   leadv2-causal-replay.sh --against-task <effect-task-id> --cause-task <cause-task-id>
#
# Algorithm (approximate — noted explicitly in output):
#   1. Read cause-task diff from docs/handoff/<cause-id>/diff.md
#   2. Identify lines introduced by that diff ("+"-prefixed lines, normalized)
#   3. Find all tasks in the 7 days after cause-task deploy that touched the same files/lines
#   4. For each such downstream task: was its outcome (failure_class) non-"none"?
#      If yes → tag as "possibly-impacted" (counterfactual: skipping cause diff may have changed outcome)
#   5. Write report to stdout + docs/handoff/<effect-task>/causal-replay.md
#
# NOTE: This is an approximate heuristic. File+line overlap is a necessary but
# not sufficient condition for causal influence. Treat results as hypothesis,
# not proof. Review manually before acting.
#
# Exit codes:
#   0 = replay complete
#   1 = missing required inputs
#   2 = usage error

set -euo pipefail

PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
HANDOFF_DIR="${PROJECT_ROOT}/docs/handoff"
LEAD_STATE="${PROJECT_ROOT}/docs/LEAD_V2_STATE.md"
HISTORY_FILE="${PROJECT_ROOT}/docs/ops/LEAD_HISTORY.md"

# ── Logging ────────────────────────────────────────────────────────────────────
log()       { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }
log_warn()  { log "WARN: $*"; }
log_error() { log "ERROR: $*"; }

# ── Argument parsing ───────────────────────────────────────────────────────────
AGAINST_TASK=""
CAUSE_TASK=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --against-task)
      [[ -z "${2:-}" ]] && { log_error "--against-task requires a value"; exit 2; }
      AGAINST_TASK="$2"; shift 2 ;;
    --cause-task)
      [[ -z "${2:-}" ]] && { log_error "--cause-task requires a value"; exit 2; }
      CAUSE_TASK="$2"; shift 2 ;;
    -h|--help)
      grep '^#' "$0" | head -30 | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *)
      log_error "Unknown argument: $1"; exit 2 ;;
  esac
done

if [[ -z "$AGAINST_TASK" || -z "$CAUSE_TASK" ]]; then
  log_error "Both --against-task and --cause-task are required"
  exit 2
fi

log "Counterfactual replay: effect=$AGAINST_TASK cause=$CAUSE_TASK"

CAUSE_HANDOFF="${HANDOFF_DIR}/${CAUSE_TASK}"
EFFECT_HANDOFF="${HANDOFF_DIR}/${AGAINST_TASK}"
CAUSE_DIFF="${CAUSE_HANDOFF}/diff.md"

if [[ ! -f "$CAUSE_DIFF" ]]; then
  log_error "Cause task diff not found: $CAUSE_DIFF"
  exit 1
fi

# ── Extract files touched by cause diff ────────────────────────────────────────
mapfile -t CAUSE_FILES < <(grep -oP '^[+]{3} b/\K[^\s]+' "$CAUSE_DIFF" 2>/dev/null | sort -u || true)

if [[ ${#CAUSE_FILES[@]} -eq 0 ]]; then
  log_warn "No files found in cause diff — cannot perform replay"
  exit 1
fi

log "Cause diff touches ${#CAUSE_FILES[@]} files: ${CAUSE_FILES[*]}"

# ── Find cause-task deploy timestamp ──────────────────────────────────────────
CAUSE_DEPLOY_TS=""
CAUSE_CTX="${CAUSE_HANDOFF}/context.yaml"
if [[ -f "$CAUSE_CTX" ]]; then
  CAUSE_DEPLOY_TS=$(python3 - "$CAUSE_CTX" <<'PY'
import sys, yaml
with open(sys.argv[1]) as fh:
    ctx = yaml.safe_load(fh) or {}
dg = ctx.get("deploy_gate") or {}
print(dg.get("deployed_at") or dg.get("commit_ts") or "")
PY
  )
fi

if [[ -z "$CAUSE_DEPLOY_TS" ]]; then
  log_warn "Could not determine cause deploy timestamp — using 7-day lookback from today"
  CAUSE_DEPLOY_TS=$(date -u -v-7d '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
    || date -u --date='7 days ago' '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
    || date -u '+%Y-%m-%dT%H:%M:%SZ')
fi

log "Cause deploy timestamp: $CAUSE_DEPLOY_TS"

# ── Find downstream tasks (commits within 7 days of cause deploy) ─────────────
# Collect commits on the same files within +7 days of cause deploy
DOWNSTREAM_TASKS=()
for file in "${CAUSE_FILES[@]}"; do
  git -C "$PROJECT_ROOT" ls-files --error-unmatch "$file" &>/dev/null 2>&1 || continue
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    subject="${line#* }"
    if [[ "$subject" =~ ([A-Z]+-[0-9]+) ]]; then
      tid="${BASH_REMATCH[1]}"
      [[ "$tid" == "$CAUSE_TASK" || "$tid" == "$AGAINST_TASK" ]] && continue
      DOWNSTREAM_TASKS+=("$tid")
    fi
  done < <(git -C "$PROJECT_ROOT" log \
    --after="$CAUSE_DEPLOY_TS" \
    --before="$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --oneline \
    --follow \
    -- "$file" 2>/dev/null || true)
done

# Deduplicate
mapfile -t DOWNSTREAM_TASKS < <(printf '%s\n' "${DOWNSTREAM_TASKS[@]}" | sort -u)

log "Found ${#DOWNSTREAM_TASKS[@]} downstream task(s) touching same files"

# ── Check outcomes of downstream tasks ────────────────────────────────────────
# Read LEAD_V2_STATE + LEAD_HISTORY for outcome info
python3 - "$LEAD_STATE" "$HISTORY_FILE" "$CAUSE_TASK" "$AGAINST_TASK" \
  "${DOWNSTREAM_TASKS[@]+"${DOWNSTREAM_TASKS[@]}"}" <<'PY'
import sys, yaml, os

lead_state_path = sys.argv[1]
history_path    = sys.argv[2]
cause_task      = sys.argv[3]
against_task    = sys.argv[4]
downstream      = sys.argv[5:]  # may be empty

def load_history_entries(*paths):
    entries = []
    for p in paths:
        if not os.path.exists(p):
            continue
        try:
            data = yaml.safe_load(open(p)) or {}
            if isinstance(data, dict):
                entries.extend(data.get("history") or [])
        except Exception:
            pass
    return entries

entries = load_history_entries(lead_state_path, history_path)
entry_by_task = {e.get("task"): e for e in entries if e.get("task")}

possibly_impacted = []
for tid in downstream:
    entry = entry_by_task.get(tid)
    if not entry:
        possibly_impacted.append({
            "task_id": tid,
            "outcome": "unknown",
            "failure_class": "unknown",
            "window": "7d",
            "reason": "no history entry found",
        })
        continue
    sig = entry.get("reflect", {}).get("signature") or {}
    fc  = sig.get("failure_class", "none")
    out = sig.get("outcome", "unknown")
    # Non-success outcome OR non-none failure → possibly impacted
    if fc != "none" or out not in ("success", "unknown"):
        possibly_impacted.append({
            "task_id": tid,
            "outcome": out,
            "failure_class": fc,
            "window": "7d",
            "reason": f"failure_class={fc}, outcome={out}",
        })

print("\n=== COUNTERFACTUAL REPLAY REPORT ===")
print(f"Cause task:  {cause_task}")
print(f"Effect task: {against_task}")
print(f"NOTE: This is an APPROXIMATE heuristic. File+line overlap is necessary")
print(f"      but not sufficient for causal influence. Review manually.")
print()

if not downstream:
    print("No downstream tasks found touching the same files within 7d of cause deploy.")
else:
    print(f"Downstream tasks touching same files ({len(downstream)} total):")
    for tid in downstream:
        entry = entry_by_task.get(tid)
        if entry:
            sig = (entry.get("reflect") or {}).get("signature") or {}
            print(f"  {tid}  outcome={sig.get('outcome','?')}  failure={sig.get('failure_class','?')}")
        else:
            print(f"  {tid}  (no history entry)")
    print()

if possibly_impacted:
    print(f"Possibly impacted tasks (outcome non-success or failure_class non-none): {len(possibly_impacted)}")
    for pi in possibly_impacted:
        print(f"  {pi['task_id']}  [{pi['failure_class']}]  outcome={pi['outcome']}")
        print(f"    Counterfactual: if {cause_task} diff was absent, this task MAY have had different outcome")
else:
    print("No downstream tasks had non-success outcomes. Skipping cause diff may have had no observable effect.")

print()
print("24h window tasks:  (requires timestamp filtering — approximate via git log date range above)")
print("48h window tasks:  (same)")
print("168h window tasks: (same — full 7d is the lookup window)")
PY

# ── Write report to handoff dir ───────────────────────────────────────────────
REPORT_OUT="${EFFECT_HANDOFF}/causal-replay.md"
{
  printf '# Causal Replay — %s ← %s\n\n' "$AGAINST_TASK" "$CAUSE_TASK"
  printf 'Generated: %s\n\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  printf '> NOTE: Approximate heuristic. File+line overlap is necessary but not sufficient for causal influence.\n\n'
  printf '## Cause diff files\n\n'
  for f in "${CAUSE_FILES[@]}"; do
    printf -- '- %s\n' "$f"
  done
  printf '\n## Downstream task analysis\n\n'
  printf 'See stdout output above for full report.\n'
  printf '\nDownstream task IDs checked: %s\n' "${DOWNSTREAM_TASKS[*]:-none}"
} > "$REPORT_OUT"

log "Report written: $REPORT_OUT"
exit 0
