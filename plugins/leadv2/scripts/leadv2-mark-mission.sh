#!/usr/bin/env bash
# leadv2-mark-mission.sh — update a mission's fields in the campaign queue.
# Multi-session safe: all mutations under flock on docs/leadv2/.task-queue.lock
#
# Usage:
#   leadv2-mark-mission.sh <mission-id> --status STATE [--deliverable PATH] [--review STATE] [--findings PATH] [--mission-file PATH] [--notes TEXT] [--claim] [--release]
#
# --claim    sets status=in_progress + claimed_by={session_id} + claimed_at=now + claim_pid=$$
# --release  removes claim_* fields (used when status flips back to pending or to completed)

set -euo pipefail

QUEUE="${LEADV2_TASK_QUEUE:-docs/leadv2/tasks.yaml}"
LOCK_PATH="docs/leadv2/.task-queue.lock"
mkdir -p "$(dirname "$LOCK_PATH")"
[[ -f "$LOCK_PATH" ]] || : > "$LOCK_PATH"
[[ -f "$QUEUE" ]] || { echo "ERROR: $QUEUE not found" >&2; exit 1; }

MISSION_ID="${1:-}"
[[ -z "$MISSION_ID" ]] && { echo "Usage: $0 <mission-id> [--status STATE] [--deliverable PATH] [--review STATE] [--findings PATH] [--mission-file PATH] [--notes TEXT] [--claim] [--release]" >&2; exit 2; }
shift

STATUS=""
DELIVERABLE=""
REVIEW=""
FINDINGS=""
MISSION_FILE=""
NOTES=""
CLAIM="false"
RELEASE="false"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --status)        STATUS="$2"; shift 2 ;;
        --deliverable)   DELIVERABLE="$2"; shift 2 ;;
        --review)        REVIEW="$2"; shift 2 ;;
        --findings)      FINDINGS="$2"; shift 2 ;;
        --mission-file)  MISSION_FILE="$2"; shift 2 ;;
        --notes)         NOTES="$2"; shift 2 ;;
        --claim)         CLAIM="true"; shift ;;
        --release)       RELEASE="true"; shift ;;
        *)               echo "ERROR: unknown flag $1" >&2; exit 2 ;;
    esac
done

LEADV2_TASK_ID="${LEADV2_TASK_ID:-unknown}" \
LEADV2_SESSION_ID="${LEADV2_SESSION_ID:-${LEADV2_TASK_ID}-$$}" \
LOCK_PATH="$LOCK_PATH" \
python3 <<PY
import yaml, tempfile, os, sys, datetime, fcntl, time
from pathlib import Path

# Python-level exclusive lock (portable across macOS + Linux)
lock_fd = open(os.environ["LOCK_PATH"], "w")
deadline = time.time() + 30
while True:
    try:
        fcntl.flock(lock_fd.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        break
    except OSError:
        if time.time() > deadline:
            print(f"ERROR: timed out waiting for {os.environ['LOCK_PATH']}", file=sys.stderr)
            sys.exit(4)
        time.sleep(0.1)

p = Path("$QUEUE")
data = yaml.safe_load(p.read_text())
target = None
for m in data.get("missions", []):
    if m["id"] == "$MISSION_ID":
        target = m
        break
if not target:
    print("ERROR: mission $MISSION_ID not found in queue", file=sys.stderr)
    sys.exit(2)

if "$STATUS":
    target["status"] = "$STATUS"
if "$DELIVERABLE":
    target["deliverable"] = "$DELIVERABLE"
if "$REVIEW":
    target["review_status"] = "$REVIEW"
if "$FINDINGS":
    target["review_findings"] = "$FINDINGS"
if "$MISSION_FILE":
    target["mission_file"] = "$MISSION_FILE"
if "$NOTES":
    target["notes"] = "$NOTES"

if "$CLAIM" == "true":
    existing = target.get("claimed_by")
    if existing and existing != os.environ.get("LEADV2_SESSION_ID", ""):
        existing_pid = target.get("claim_pid")
        alive = False
        if existing_pid:
            try:
                os.kill(int(existing_pid), 0)
                alive = True
            except (OSError, ValueError):
                alive = False
        if alive:
            print(f"ERROR: mission $MISSION_ID claimed by {existing} (pid {existing_pid}, alive)", file=sys.stderr)
            sys.exit(5)
    target["status"] = "in_progress"
    target["claimed_by"] = os.environ.get("LEADV2_SESSION_ID", "unknown")
    target["claim_pid"] = int(os.environ.get("LEADV2_LEAD_PID", os.getpid()))
    target["claimed_at"] = datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None).strftime("%Y-%m-%dT%H:%M:%SZ")

if "$RELEASE" == "true":
    for k in ("claimed_by", "claim_pid", "claimed_at"):
        target.pop(k, None)

fd, tmp = tempfile.mkstemp(dir=p.parent, prefix=".queue.", suffix=".tmp")
try:
    with os.fdopen(fd, "w") as f:
        yaml.safe_dump(data, f, sort_keys=False, default_flow_style=False, allow_unicode=True)
    os.replace(tmp, p)
except Exception:
    try: os.unlink(tmp)
    except: pass
    raise
print(f"updated $MISSION_ID")
PY
