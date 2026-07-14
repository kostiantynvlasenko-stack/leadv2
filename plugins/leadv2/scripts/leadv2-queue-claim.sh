#!/usr/bin/env bash
set -euo pipefail
# leadv2-queue-claim.sh — Atomically claim the first claimable item from a lane.
#
# Usage:
#   Single-lane:   leadv2-queue-claim.sh --lane <lane> --by <claimer-id> [--ttl-min <minutes>]
#   Multi-lane:    leadv2-queue-claim.sh --by <claimer-id> [--ttl-min <minutes>]
#                  (iterates recovery → action → intelligence; prints <lane>:<id> on success)
#   Dry-run top-N: leadv2-queue-claim.sh --dry-run --top-n <N>
#                  (prints <lane>\t<priority>\t<id>\t<title> for top N candidates)
#
# Per-lane TTL defaults (minutes) when --ttl-min not passed:
#   recovery=60, action=90, intelligence=120
#
# Exit 0 — item claimed (or results printed for dry-run).
# Exit 1 — no claimable items in lane / error.
# Exit 2 — nothing claimable across all lanes (multi-lane mode).

PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
QUEUE_DIR="${PROJECT_ROOT}/docs/agents/product-owner/queue"

# Source tasks lib — all queue operations now delegate to tasks.yaml
# shellcheck source=leadv2-tasks-lib.sh
source "$(dirname "$0")/leadv2-tasks-lib.sh"

LANE=""
CLAIMER=""
TTL_MIN=""
DRY_RUN=0
TOP_N=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --lane)     LANE="$2";    shift 2 ;;
    --by)       CLAIMER="$2"; shift 2 ;;
    --ttl-min)  TTL_MIN="$2"; shift 2 ;; # kept for backward compat; lib uses per-lane defaults
    --dry-run)  DRY_RUN=1;    shift   ;;
    --top-n)    TOP_N="$2";   shift 2 ;;
    -h|--help)
      printf -- 'Usage: leadv2-queue-claim.sh [--lane <lane>] --by <claimer-id> [--ttl-min <minutes>]\n' >&2
      printf -- '       leadv2-queue-claim.sh --dry-run --top-n <N>\n' >&2
      exit 0
      ;;
    *) printf -- '[queue-claim] unknown arg: %s\n' "$1" >&2; exit 1 ;;
  esac
done
# TTL_MIN kept for backward compat (callers may pass --ttl-min); lib uses per-lane defaults
: "${TTL_MIN:-}"

# ── Per-lane TTL defaults ──────────────────────────────────────────────────
_lane_ttl() {
  local lane="$1"
  case "$lane" in
    recovery)     printf -- '60'  ;;
    action)       printf -- '90'  ;;
    intelligence) printf -- '120' ;;
    *)
      printf -- '[claim] WARN: unknown lane '"'"'%s'"'"', using default TTL=90min\n' "$lane" >&2
      printf -- '90'
      ;;
  esac
}

MULTI_LANE_ORDER=("recovery" "action" "intelligence")

# ── Dry-run top-N mode — delegates to leadv2-tasks-lib.sh ──────────────────
if [[ "$DRY_RUN" -eq 1 ]]; then
  if [[ -z "$TOP_N" ]]; then
    printf -- '[queue-claim] --dry-run requires --top-n <N>\n' >&2
    exit 1
  fi
  leadv2_tasks_top_n "$TOP_N"
  exit 0
fi

# ── DEAD CODE BELOW — preserved for git history only ───────────────────────
# Original lane-yaml-direct dry-run implementation replaced by lib call above.
if false; then
  python3 - "$TOP_N" "${QUEUE_DIR}" "${MULTI_LANE_ORDER[*]}" <<'PY'
import sys
import os
import yaml
import datetime

top_n       = int(sys.argv[1])
queue_dir   = sys.argv[2]
lane_order  = sys.argv[3].split()

now = datetime.datetime.now(datetime.timezone.utc)
PRIORITY_ORDER = {"critical": 0, "high": 1, "medium": 2, "low": 3}

def parse_dt(s: str) -> datetime.datetime:
    s = str(s).replace(" ", "T")
    if "+" in s: s = s.split("+")[0]
    if s.endswith("Z"): s = s[:-1]
    try:
        return datetime.datetime.strptime(s, "%Y-%m-%dT%H:%M:%S")
    except ValueError:
        return datetime.datetime.min

def lease_expired(item: dict) -> bool:
    claim = item.get("claim") or {}
    ls = claim.get("lease_expires")
    if ls is None:
        return False
    return now >= parse_dt(ls)

def all_deps_done(item: dict, all_items_by_id: dict) -> bool:
    deps = (item.get("context") or {}).get("depends_on") or []
    for dep_id in deps:
        dep = all_items_by_id.get(str(dep_id))
        if dep is None:
            return False  # unknown dep = not done
        if dep.get("status") not in ("done", "completed", "closed"):
            return False
    return True

# Load all items across all lanes
all_items_by_id: dict[str, dict] = {}
lane_items: list[tuple[int, str, dict]] = []  # (lane_rank, lane_name, item)

for lane_rank, lane_name in enumerate(lane_order):
    lane_file = os.path.join(queue_dir, f"{lane_name}.yaml")
    if not os.path.isfile(lane_file):
        continue
    with open(lane_file) as f:
        items = yaml.safe_load(f) or []
    for it in items:
        all_items_by_id[str(it.get("id", ""))] = it
    for it in items:
        lane_items.append((lane_rank, lane_name, it))

# Filter claimable
candidates: list[tuple[int, int, datetime.datetime, str, str, dict]] = []
for lane_rank, lane_name, it in lane_items:
    st = it.get("status", "")
    claim = it.get("claim") or {}
    # Skip already-finished items before any other logic
    if st in ("done", "completed", "closed"):
        continue
    is_pending = (st == "pending")
    is_stale   = (st in ("in_progress", "in-progress") and lease_expired(it))
    if not (is_pending or is_stale):
        continue
    if not all_deps_done(it, all_items_by_id):
        continue
    pri_rank = PRIORITY_ORDER.get(str(it.get("priority", "medium")), 4)
    created  = parse_dt(it.get("created_at", ""))
    candidates.append((lane_rank, pri_rank, created, str(it.get("id", "")), lane_name, it))

candidates.sort(key=lambda x: (x[0], x[1], x[2], x[3]))

for _, pri_rank, _, item_id, lane_name, it in candidates[:top_n]:
    pri = it.get("priority", "medium")
    title = str(it.get("title", ""))
    print(f"{lane_name}\t{pri}\t{item_id}\t{title}")
PY
  exit 0
fi

# ── Single or multi-lane claim mode — delegates to leadv2-tasks-lib.sh ────
if [[ -z "$CLAIMER" ]]; then
  printf -- '[queue-claim] ERROR: --by is required\n' >&2
  exit 1
fi

if [[ -n "$LANE" ]]; then
  # Single-lane mode: find next claimable item in the given lane, then claim it
  next_id=$(leadv2_tasks_next_for_lane "$LANE") || {
    printf -- '[queue-claim] no claimable items in lane %s\n' "$LANE" >&2
    exit 1
  }
  leadv2_tasks_claim "$next_id" --by "$CLAIMER"
  # Output single-lane claimed item as YAML (format matches original)
  leadv2_tasks_by_id "$next_id"
  exit 0
fi
