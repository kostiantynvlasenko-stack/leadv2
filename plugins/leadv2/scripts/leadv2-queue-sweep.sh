#!/usr/bin/env bash
set -euo pipefail
# leadv2-queue-sweep.sh — Sweep zombie leases + archive stale poisoned items.
# Now delegates zombie-lease reset to leadv2-tasks-lib.sh for tasks.yaml items.
# Legacy lane-yaml sweep code preserved as dead code below.
#
# Usage: leadv2-queue-sweep.sh [--queue-dir <path>] [--poison-age-days <N>] [--dry-run]
#
# Safe to run at daemon start or via cron.
# SHELL=/bin/bash when used in cron.

PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
QUEUE_DIR="${PROJECT_ROOT}/docs/agents/product-owner/queue"

# Source tasks lib
# shellcheck source=leadv2-tasks-lib.sh
source "$(dirname "$0")/leadv2-tasks-lib.sh"

POISON_AGE_DAYS=7
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --queue-dir)       QUEUE_DIR="$2";       shift 2 ;;
    --poison-age-days) POISON_AGE_DAYS="$2"; shift 2 ;;
    --dry-run)         DRY_RUN=1;            shift ;;
    -h|--help)
      echo "Usage: leadv2-queue-sweep.sh [--queue-dir <path>] [--poison-age-days <N>] [--dry-run]" >&2
      exit 0
      ;;
    *) echo "[queue-sweep] unknown arg: $1" >&2; exit 1 ;;
  esac
done

log() { echo "[leadv2-queue-sweep] $(date '+%Y-%m-%dT%H:%M:%SZ') $*" >&2; }

if [[ ! -d "$QUEUE_DIR" ]]; then
  log "queue directory not found: $QUEUE_DIR — nothing to sweep"
  exit 0
fi

# ── Dead-PID sidecar scan (H2: crash protection) ──────────────────────────
# Read each .claims/<task_id>.claim sidecar; if the PID is dead, release the
# matching item from its lane yaml and remove the sidecar.
# This runs before the zombie-lease sweep so that crash-released items get their
# lease properly cleared in the same tick.
CLAIMS_DIR="${PROJECT_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/docs/agents/product-owner/.claims"
if [[ -d "$CLAIMS_DIR" ]]; then
  log "scanning dead-PID sidecars in $CLAIMS_DIR"
  for _claim_file in "$CLAIMS_DIR"/*.claim; do
    [[ -f "$_claim_file" ]] || continue
    _task_id="$(basename "$_claim_file" .claim)"
    _pid="$(grep '^pid=' "$_claim_file" 2>/dev/null | head -1 | cut -d= -f2 || true)"
    if [[ -z "$_pid" ]]; then
      log "WARN: sidecar $_claim_file has no pid= line — removing stale sidecar"
      [[ "$DRY_RUN" -eq 0 ]] && rm -f "$_claim_file"
      continue
    fi
    if kill -0 "$_pid" 2>/dev/null; then
      log "sidecar $_task_id: PID $_pid alive — skipping"
      continue
    fi
    log "sidecar $_task_id: PID $_pid dead — releasing via tasks.yaml lib"
    if [[ "$DRY_RUN" -eq 0 ]]; then
      # Find which task in tasks.yaml has claim.by == _task_id (the sidecar task_id IS the claim session id)
      # We use list_status in_progress then match by claim.by field
      _matched_id=$(python3 - "${PROJECT_ROOT}/docs/tasks.yaml" "$_task_id" "$(dirname "$0")" <<'MATCH_PY' 2>/dev/null || true
import sys
tasks_file, claim_session, scripts_dir = sys.argv[1:4]
sys.path.insert(0, scripts_dir)
try:
    from leadv2_tasks_yaml_common import load_tasks_items
    items = load_tasks_items(tasks_file)
except FileNotFoundError:
    sys.exit(0)
for it in items:
    claim = it.get("claim") or {}
    if str(claim.get("by","")) == claim_session:
        print(it.get("id",""))
        sys.exit(0)
MATCH_PY
      )
      if [[ -n "$_matched_id" ]]; then
        leadv2_tasks_release "$_matched_id" --outcome fail --error "crash-recovered: dead pid $_pid" 2>/dev/null || true
        log "dead-pid: released $_matched_id (was claimed by pid $_pid / session $_task_id)"
      else
        log "dead-pid: no tasks.yaml entry claimed by session $_task_id — stale sidecar"
      fi
      rm -f "$_claim_file"
      log "sidecar removed: $_claim_file"
    else
      log "[dry-run] would release task claimed by session $_task_id (pid $_pid) and remove $_claim_file"
    fi
  done
fi

# ── tasks.yaml zombie sweep — delegates to leadv2-tasks-lib.sh ──────────
if [[ -f "${PROJECT_ROOT}/docs/tasks.yaml" ]]; then
  log "sweeping zombie leases in tasks.yaml"
  _zombie_count=0
  while IFS=$'\t' read -r _lane _item_id; do
    [[ -z "$_item_id" ]] && continue
    # Check if lease is expired via Python (tasks.yaml has the lease data)
    _expired=$(python3 -c "
import yaml, datetime, sys
tasks_file = '${PROJECT_ROOT}/docs/tasks.yaml'
item_id = '$_item_id'
now = datetime.datetime.now(datetime.timezone.utc)
try:
    items = yaml.safe_load(open(tasks_file)) or []
except Exception:
    sys.exit(0)
for it in items:
    if str(it.get('id','')) == item_id:
        claim = it.get('claim') or {}
        ls = claim.get('lease_expires')
        if ls:
            s = str(ls).replace(' ','T')
            if '+' in s: s = s.split('+')[0]
            if s.endswith('Z'): s = s[:-1]
            try:
                dt = datetime.datetime.strptime(s, '%Y-%m-%dT%H:%M:%S')
                if now >= dt:
                    print('yes')
            except ValueError:
                pass
        break
" 2>/dev/null || true)
    if [[ "$_expired" == "yes" ]]; then
      log "zombie lease expired: $_item_id (lane=$_lane)"
      if [[ "$DRY_RUN" -eq 0 ]]; then
        leadv2_tasks_update "$_item_id" --key "claim.by" --value "null" || true
        leadv2_tasks_update "$_item_id" --key "claim.lease_expires" --value "null" || true
        leadv2_tasks_update "$_item_id" --key "status" --value "pending" || true
      fi
      _zombie_count=$(( _zombie_count + 1 ))
    fi
  done < <(leadv2_tasks_list_status "in_progress" 2>/dev/null || true)
  log "tasks.yaml sweep complete: reset ${_zombie_count} zombie(s)"
fi

# ── Archive stale tasks via lib ───────────────────────────────────────────
if [[ -f "${PROJECT_ROOT}/docs/tasks.yaml" ]] && [[ "$DRY_RUN" -eq 0 ]]; then
  leadv2_tasks_archive --older-than-days "$POISON_AGE_DAYS" || true
fi

exit 0
