#!/usr/bin/env bash
# scripts/leadv2-bus.sh — LEAD-BUS-01 cross-session event bus.
#
# Append-only JSONL at docs/leadv2/bus.jsonl. One line = one event. All
# writes go through a python3 fcntl.flock(LOCK_EX) critical section — proven
# safe for 20 concurrent writers on darwin (BSD flock is a real advisory
# lock on APFS/HFS+, unlike NFS where it degrades to a no-op). See
# tests/leadv2/test-bus.sh for the 20-writer stress proof.
#
# Usage:
#   leadv2-bus.sh publish <task-id> <type> <json-payload>
#     types: claim | files | phase | finding | merged | closed
#   leadv2-bus.sh read --since <offset|ISO|session-id> [--task <id>]
#     - value is all-digits      -> stateless: lines from that 0-based line offset
#     - value looks like ISO8601 -> stateless: lines with ts > value
#     - anything else            -> stateful session id; offset persisted at
#                                    docs/leadv2/.bus-offsets/<session-id>,
#                                    advanced on every call (second call with
#                                    no new events prints nothing)
#     --task <id> filters printed lines to that task_id only
#   leadv2-bus.sh conflicts <task-id>
#     compares this task's latest `files` event against every other LIVE
#     task's latest `files` event (a task is live unless its most recent
#     event type is `closed`/`merged`). Prints one line per conflicting task.
#     Exit 1 if any conflict found, exit 0 otherwise.
#
# Env overrides (used by tests to sandbox):
#   PROJECT_ROOT   - repo root (default: derived from script location)
#   LEADV2_DIR     - dir holding bus.jsonl / .bus.lock / .bus-offsets
#                    (default: the LEAD-CONTROL-PLANE-01 control-plane root,
#                    resolved via leadv2-state-path.sh — OUTSIDE any git
#                    worktree, identical from every /leadv2 session. Never
#                    hardcode docs/leadv2 here — that was the LEAD-ANCHOR-01
#                    bug: each worktree got its own private bus/lock.)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
LEADV2_DIR="${LEADV2_DIR:-$("${SCRIPT_DIR}/leadv2-state-path.sh")}"
BUS_FILE="${LEADV2_DIR}/bus.jsonl"
BUS_LOCK="${LEADV2_DIR}/.bus.lock"
OFFSETS_DIR="${LEADV2_DIR}/.bus-offsets"

mkdir -p "$LEADV2_DIR" "$OFFSETS_DIR"

usage() {
  printf -- 'Usage:\n' >&2
  printf -- '  leadv2-bus.sh publish <task-id> <type> <json-payload>\n' >&2
  printf -- '  leadv2-bus.sh read --since <offset|ISO|session-id> [--task <id>]\n' >&2
  printf -- '  leadv2-bus.sh conflicts <task-id>\n' >&2
  exit 1
}

[[ $# -ge 1 ]] || usage
CMD="$1"; shift

case "$CMD" in
  publish)
    [[ $# -eq 3 ]] || usage
    TASK_ID="$1"; TYPE="$2"; PAYLOAD="$3"
    python3 - "$BUS_FILE" "$BUS_LOCK" "$TASK_ID" "$TYPE" "$PAYLOAD" "$$" <<'PYEOF'
import fcntl, json, os, sys, time

bus_file, bus_lock, task_id, ev_type, payload_raw, pid = sys.argv[1:7]

try:
    payload = json.loads(payload_raw)
except Exception as e:
    sys.stderr.write(f"[bus] invalid JSON payload: {e}\n")
    sys.exit(1)

line = json.dumps({
    "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "task_id": task_id,
    "type": ev_type,
    "pid": int(pid),
    "payload": payload,
}, sort_keys=True)

lockf = open(bus_lock, "a+")
try:
    fcntl.flock(lockf, fcntl.LOCK_EX)
    with open(bus_file, "a", encoding="utf-8") as f:
        f.write(line + "\n")
        f.flush()
        os.fsync(f.fileno())
finally:
    fcntl.flock(lockf, fcntl.LOCK_UN)
    lockf.close()
PYEOF
    ;;

  read)
    SINCE=""
    TASK_FILTER=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --since) SINCE="$2"; shift 2 ;;
        --task)  TASK_FILTER="$2"; shift 2 ;;
        *) usage ;;
      esac
    done
    [[ -n "$SINCE" ]] || usage
    python3 - "$BUS_FILE" "$BUS_LOCK" "$OFFSETS_DIR" "$SINCE" "$TASK_FILTER" <<'PYEOF'
import fcntl, json, os, re, sys

bus_file, bus_lock, offsets_dir, since, task_filter = sys.argv[1:6]

def read_lines():
    if not os.path.exists(bus_file):
        return []
    with open(bus_file, encoding="utf-8") as f:
        return [l for l in f.read().splitlines() if l.strip()]

lockf = open(bus_lock, "a+")
fcntl.flock(lockf, fcntl.LOCK_SH)
try:
    lines = read_lines()
finally:
    fcntl.flock(lockf, fcntl.LOCK_UN)
    lockf.close()

def matches_task(line):
    if not task_filter:
        return True
    try:
        return json.loads(line).get("task_id") == task_filter
    except Exception:
        return False

if since.isdigit():
    start = int(since)
    out = [l for l in lines[start:] if matches_task(l)]
elif re.match(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}", since):
    out = []
    for l in lines:
        try:
            ev = json.loads(l)
        except Exception:
            continue
        if ev.get("ts", "") > since and matches_task(l):
            out.append(l)
else:
    # stateful session-id mode
    offset_path = os.path.join(offsets_dir, since)
    offset_lock_path = offset_path + ".lock"
    olockf = open(offset_lock_path, "a+")
    try:
        fcntl.flock(olockf, fcntl.LOCK_EX)
        try:
            with open(offset_path, encoding="utf-8") as f:
                start = int(f.read().strip() or "0")
        except (FileNotFoundError, ValueError):
            start = 0
        out = [l for l in lines[start:] if matches_task(l)]
        tmp = offset_path + f".tmp.{os.getpid()}"
        with open(tmp, "w", encoding="utf-8") as f:
            f.write(str(len(lines)))
        os.replace(tmp, offset_path)
    finally:
        fcntl.flock(olockf, fcntl.LOCK_UN)
        olockf.close()

for l in out:
    print(l)
PYEOF
    ;;

  conflicts)
    [[ $# -eq 1 ]] || usage
    TASK_ID="$1"
    python3 - "$BUS_FILE" "$BUS_LOCK" "$TASK_ID" <<'PYEOF'
import fcntl, fnmatch, json, os, sys

bus_file, bus_lock, task_id = sys.argv[1:4]

lockf = open(bus_lock, "a+")
fcntl.flock(lockf, fcntl.LOCK_SH)
try:
    lines = []
    if os.path.exists(bus_file):
        with open(bus_file, encoding="utf-8") as f:
            lines = [l for l in f.read().splitlines() if l.strip()]
finally:
    fcntl.flock(lockf, fcntl.LOCK_UN)
    lockf.close()

latest_files = {}   # task_id -> list[str]
latest_type = {}     # task_id -> last event type seen (in file order)
for l in lines:
    try:
        ev = json.loads(l)
    except Exception:
        continue
    tid = ev.get("task_id")
    if not tid:
        continue
    latest_type[tid] = ev.get("type")
    if ev.get("type") == "files":
        payload = ev.get("payload") or {}
        files = payload.get("files") if isinstance(payload, dict) else None
        if isinstance(files, list):
            latest_files[tid] = [str(x) for x in files]

if task_id not in latest_files:
    sys.stderr.write(f"[bus conflicts] no 'files' event found for {task_id}\n")
    sys.exit(1)

mine = latest_files[task_id]
found_conflict = False

def overlap(a_list, b_list):
    shared = []
    for a in a_list:
        for b in b_list:
            if a == b or fnmatch.fnmatch(a, b) or fnmatch.fnmatch(b, a):
                shared.append(a if a == b else f"{a}~{b}")
    return shared

for other_id, other_files in latest_files.items():
    if other_id == task_id:
        continue
    if latest_type.get(other_id) in ("closed", "merged"):
        continue  # dead session — not a live conflict
    shared = overlap(mine, other_files)
    if shared:
        found_conflict = True
        print(f"CONFLICT with {other_id}: {', '.join(shared)}")

sys.exit(1 if found_conflict else 0)
PYEOF
    ;;

  *)
    usage
    ;;
esac
