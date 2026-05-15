#!/usr/bin/env bash
set -euo pipefail
# leadv2-queue-migrate.sh — OBSOLETE: superseded by leadv2-tasks-render.sh
#
# This script migrated legacy QUEUE.md → 4-lane queue/ directory (already done).
# That migration step is now complete. The current migration path is:
#   leadv2-tasks-render.sh — merges 4 lane yamls → docs/tasks.yaml
#
# This file is kept for git history only.

echo "obsolete: superseded by leadv2-tasks-render.sh" >&2
exit 0

# ── DEAD CODE: original QUEUE.md → lane-yaml migration ───────────────────
if false; then
# leadv2-queue-migrate.sh — Migrate legacy QUEUE.md flat list to 4-lane queue/ directory.
#
# Usage: leadv2-queue-migrate.sh [--queue-file <path>] [--queue-dir <path>] [--dry-run]
#
# Reads QUEUE.md checkboxes, classifies items into lanes:
#   RECOVERY-*          → recovery.yaml
#   blocked-on-human    → human-needed.yaml
#   all others          → action.yaml (default)
# Items marked [x] (done) are skipped entirely.
# Keeps original QUEUE.md; creates legacy redirect comment.

PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"

QUEUE_FILE="${PROJECT_ROOT}/docs/agents/product-owner/QUEUE.md"
QUEUE_DIR="${PROJECT_ROOT}/docs/agents/product-owner/queue"
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --queue-file) QUEUE_FILE="$2"; shift 2 ;;
    --queue-dir)  QUEUE_DIR="$2"; shift 2 ;;
    --dry-run)    DRY_RUN=1; shift ;;
    -h|--help)
      echo "Usage: leadv2-queue-migrate.sh [--queue-file <path>] [--queue-dir <path>] [--dry-run]" >&2
      exit 0
      ;;
    *) echo "[migrate] unknown arg: $1" >&2; exit 1 ;;
  esac
done

log() { echo "[leadv2-queue-migrate] $(date '+%Y-%m-%dT%H:%M:%SZ') $*" >&2; }

if [[ ! -f "$QUEUE_FILE" ]]; then
  log "ERROR: QUEUE.md not found at $QUEUE_FILE"
  exit 1
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  log "DRY RUN — no files will be written"
fi

python3 - "$QUEUE_FILE" "$QUEUE_DIR" "$DRY_RUN" <<'PY'
import sys
import os
import re
import yaml
import datetime

queue_file = sys.argv[1]
queue_dir  = sys.argv[2]
dry_run    = sys.argv[3] == "1"

LANES = ["action", "intelligence", "recovery", "human-needed"]
buckets: dict[str, list[dict]] = {lane: [] for lane in LANES}

def classify(line: str) -> str:
    text = line.lower()
    tid  = (re.search(r'(RECOVERY-[A-Z0-9-]+)', line, re.IGNORECASE) or None)
    if tid or "recovery-" in text:
        return "recovery"
    if "blocked-on-human" in text:
        return "human-needed"
    return "action"

def extract_id(line: str) -> str:
    m = re.search(r'([A-Z]+-\d+)', line)
    return m.group(1) if m else ""

def strip_checkbox(line: str) -> str:
    return re.sub(r'^-\s*\[[ x?]\]\s*(\[.*?\]\s*)?', '', line).strip()

now_iso = datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")

with open(queue_file) as f:
    lines = f.readlines()

for line in lines:
    line = line.rstrip("\n")
    # Only pending items — skip done [x]
    if not re.match(r'^-\s*\[ \]', line):
        continue

    lane   = classify(line)
    raw_id = extract_id(line)
    title  = strip_checkbox(line)

    if not raw_id:
        raw_id = "PO-MIGRATED-" + str(len(buckets[lane]) + 1)

    status = "blocked" if lane == "human-needed" else "pending"
    reject = None
    if lane == "human-needed":
        # Try to find a reason after the last dash in the title
        m = re.search(r'blocked-on-human[^—]*?—?\s*(.*)', title, re.IGNORECASE)
        reject = m.group(1).strip() if m and m.group(1).strip() else "Waiting for founder input"

    item = {
        "id":         raw_id,
        "title":      title,
        "created_at": now_iso,
        "lane":       lane,
        "priority":   "medium",
        "origin":     "po",
        "status":     status,
        "claim": {
            "by":           None,
            "lease_expires": None,
        },
        "attempts":      0,
        "max_attempts":  3,
        "last_error":    None,
        "reject_reason": reject,
        "context": {
            "files":      [],
            "depends_on": [],
        },
    }
    buckets[lane].append(item)

if dry_run:
    for lane, items in buckets.items():
        print(f"[dry-run] {lane}.yaml: {len(items)} item(s)")
        for it in items:
            print(f"  - {it['id']}: {it['title'][:70]}")
    sys.exit(0)

os.makedirs(queue_dir, exist_ok=True)
os.makedirs(os.path.join(queue_dir, "_archive"), exist_ok=True)

for lane, items in buckets.items():
    lane_file = os.path.join(queue_dir, f"{lane}.yaml")
    # Merge with existing items (skip ids already present)
    existing: list[dict] = []
    if os.path.exists(lane_file):
        with open(lane_file) as f:
            existing = yaml.safe_load(f) or []
    existing_ids = {str(it.get("id", "")) for it in existing}
    new_items = [it for it in items if it["id"] not in existing_ids]
    merged = existing + new_items

    tmp = lane_file + ".tmp"
    with open(tmp, "w") as f:
        yaml.dump(merged, f, default_flow_style=False, allow_unicode=True, sort_keys=False)
    os.replace(tmp, lane_file)
    print(f"[migrate] {lane}.yaml: {len(existing)} existing + {len(new_items)} new = {len(merged)} total")

print("[migrate] done")
PY

fi
# end DEAD CODE original migrate
