#!/usr/bin/env bash
# leadv2-next-mission.sh — print the next pending+unclaimed mission ID + path.
# Multi-session safe: under flock on docs/leadv2/.campaign-queue.lock.
#
# Usage:
#   leadv2-next-mission.sh                    # prints "<id>\t<mission_file>"
#   leadv2-next-mission.sh --json             # full mission record as JSON
#   leadv2-next-mission.sh --claim            # additionally claims it (sets in_progress + caller's session)
#
# Exit codes:
#   0 — mission found, printed (and claimed if --claim)
#   2 — no eligible pending mission
#   3 — mission found but mission_file is null
#   5 — claim race lost to live session

set -euo pipefail

QUEUE="docs/leadv2/campaign-queue.yaml"
LOCK_PATH="docs/leadv2/.campaign-queue.lock"
[[ -f "$LOCK_PATH" ]] || : > "$LOCK_PATH"
JSON="false"
CLAIM="false"
for arg in "$@"; do
    case "$arg" in
        --json)  JSON="true" ;;
        --claim) CLAIM="true" ;;
    esac
done

[[ -f "$QUEUE" ]] || { echo "ERROR: $QUEUE not found" >&2; exit 1; }

LEADV2_SESSION_ID="${LEADV2_SESSION_ID:-${LEADV2_TASK_ID:-unknown}-$$}" \
LOCK_PATH="$LOCK_PATH" \
python3 <<PY
import yaml, json, sys, os, datetime, tempfile, fcntl, time
from pathlib import Path

lock_fd = open(os.environ["LOCK_PATH"], "w")
deadline = time.time() + 30
while True:
    try:
        fcntl.flock(lock_fd.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        break
    except OSError:
        if time.time() > deadline:
            print(f"ERROR: timed out waiting for lock", file=sys.stderr)
            sys.exit(4)
        time.sleep(0.1)

p = Path("$QUEUE")
data = yaml.safe_load(p.read_text())

done = {m["id"] for m in data.get("missions", []) if m.get("status") == "completed"}

def is_dead(m):
    pid = m.get("claim_pid")
    if not pid:
        return True
    try:
        os.kill(int(pid), 0)
        return False
    except (OSError, ValueError):
        return True

eligible = None
for m in data.get("missions", []):
    if m.get("status") not in ("pending", "in_progress"):
        continue
    deps = m.get("depends_on") or []
    if not all(d in done for d in deps):
        continue
    # If in_progress and the claimer is alive — skip (someone else is working).
    if m.get("status") == "in_progress" and m.get("claimed_by") and not is_dead(m):
        continue
    eligible = m
    break

if not eligible:
    sys.exit(2)

mid = eligible["id"]
mf = eligible.get("mission_file") or ""

if "$CLAIM" == "true":
    eligible["status"] = "in_progress"
    eligible["claimed_by"] = os.environ.get("LEADV2_SESSION_ID", "unknown")
    # Use parent shell PID (lead session), not ephemeral python helper PID.
    eligible["claim_pid"] = int(os.environ.get("LEADV2_LEAD_PID", os.getppid()))
    eligible["claimed_at"] = datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")
    fd, tmp = tempfile.mkstemp(dir=p.parent, prefix=".campaign-queue.", suffix=".tmp")
    with os.fdopen(fd, "w") as f:
        yaml.safe_dump(data, f, sort_keys=False, default_flow_style=False, allow_unicode=True)
    os.replace(tmp, p)

if "$JSON" == "true":
    print(json.dumps(eligible, ensure_ascii=False, default=str))
else:
    print(f"{mid}\t{mf}")
sys.exit(0 if mf else 3)
PY
