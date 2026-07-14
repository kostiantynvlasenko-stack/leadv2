#!/usr/bin/env bash
# scripts/leadv2-merge-queue.sh — LEAD-BUS-01 FIFO merge serialization.
#
# Event-sourced ledger at docs/leadv2/merge-queue.jsonl, all mutations under
# a python3 fcntl.flock(LOCK_EX) critical section on docs/leadv2/.merge.lock
# (same locking primitive proven on darwin by scripts/leadv2-bus.sh /
# tests/leadv2/test-bus.sh). Current holder + waiting order are DERIVED by
# replaying the ledger — no separate mutable state file to fall out of sync.
#
# Usage:
#   leadv2-merge-queue.sh enqueue <task-id> <branch>
#   leadv2-merge-queue.sh acquire <task-id>     # blocks until it's this
#                                                 # task's turn; exit 2 on
#                                                 # 30-min timeout (circuit
#                                                 # breaker for Phase 6)
#   leadv2-merge-queue.sh release <task-id>
#   leadv2-merge-queue.sh status
#
# Dead-holder reclaim: if the current holder's pid is not alive AND it has
# held the lock for > LEADV2_MERGE_STALE_SEC (default 600s = 10min), the
# next `acquire` poll reclaims it (emits a `reclaimed` ledger event AND a
# `finding` event on the bus via leadv2-bus.sh) and the queue proceeds.
#
# Env overrides (tests sandbox / speed up polling):
#   PROJECT_ROOT              - repo root
#   LEADV2_DIR                - dir holding merge-queue.jsonl / .merge.lock
#                                (default: LEAD-CONTROL-PLANE-01 control-plane
#                                root, resolved via leadv2-state-path.sh —
#                                OUTSIDE any git worktree. Never hardcode
#                                docs/leadv2 here: each worktree used to get
#                                its own private lock, admitting every
#                                acquirer instead of serializing them.)
#   LEADV2_MERGE_POLL_SEC     - poll interval while blocked (default 0.5)
#   LEADV2_MERGE_TIMEOUT_SEC  - acquire timeout (default 1800 = 30min)
#   LEADV2_MERGE_STALE_SEC    - dead-holder reclaim threshold (default 600)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
LEADV2_DIR="${LEADV2_DIR:-$("${SCRIPT_DIR}/leadv2-state-path.sh")}"
QUEUE_FILE="${LEADV2_DIR}/merge-queue.jsonl"
QUEUE_LOCK="${LEADV2_DIR}/.merge.lock"
BUS_SH="${SCRIPT_DIR}/leadv2-bus.sh"

POLL_SEC="${LEADV2_MERGE_POLL_SEC:-0.5}"
TIMEOUT_SEC="${LEADV2_MERGE_TIMEOUT_SEC:-1800}"
STALE_SEC="${LEADV2_MERGE_STALE_SEC:-600}"
# The pid recorded as "holder" MUST be the long-lived caller (the Phase 6
# script that wraps acquire..release around its work), not this short-lived
# subprocess ($$ here dies the instant acquire returns). $PPID is that
# caller's real pid when this script is exec'd directly in the foreground
# (the normal case); override via LEADV2_MERGE_OWNER_PID if the real caller
# is further up the process tree (e.g. wrapped in a helper function/subshell).
OWNER_PID="${LEADV2_MERGE_OWNER_PID:-$PPID}"

mkdir -p "$LEADV2_DIR"

usage() {
  printf -- 'Usage:\n' >&2
  printf -- '  leadv2-merge-queue.sh enqueue <task-id> <branch>\n' >&2
  printf -- '  leadv2-merge-queue.sh acquire <task-id>\n' >&2
  printf -- '  leadv2-merge-queue.sh release <task-id>\n' >&2
  printf -- '  leadv2-merge-queue.sh status\n' >&2
  exit 1
}

# One transaction: replay ledger under flock, let the python snippet decide
# what (if anything) to append, then unlock. `$1` selects the operation.
_txn() {
  python3 - "$QUEUE_FILE" "$QUEUE_LOCK" "$STALE_SEC" "$@" <<'PYEOF'
import calendar, fcntl, json, os, sys, time

queue_file, queue_lock, stale_sec = sys.argv[1], sys.argv[2], float(sys.argv[3])
op = sys.argv[4]
args = sys.argv[5:]

def now_iso():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())

def read_events():
    if not os.path.exists(queue_file):
        return []
    out = []
    with open(queue_file, encoding="utf-8") as f:
        for l in f:
            l = l.strip()
            if not l:
                continue
            try:
                out.append(json.loads(l))
            except Exception:
                continue
    return out

def append_event(ev):
    with open(queue_file, "a", encoding="utf-8") as f:
        f.write(json.dumps(ev, sort_keys=True) + "\n")
        f.flush()
        os.fsync(f.fileno())

def replay(events):
    queue = []          # waiting task_ids, FIFO order
    holder = None        # task_id currently holding, or None
    holder_ev = None
    for ev in events:
        t = ev.get("type")
        tid = ev.get("task_id")
        if t == "enqueued":
            if tid != holder and tid not in queue:
                queue.append(tid)
        elif t == "acquired":
            holder = tid
            holder_ev = ev
            if tid in queue:
                queue.remove(tid)
        elif t in ("released", "reclaimed", "timeout"):
            if holder == tid:
                holder = None
                holder_ev = None
            if tid in queue:
                queue.remove(tid)
    return queue, holder, holder_ev

def pid_alive(pid):
    try:
        os.kill(int(pid), 0)
        return True
    except (OSError, ValueError):
        return False

lockf = open(queue_lock, "a+")
fcntl.flock(lockf, fcntl.LOCK_EX)
try:
    events = read_events()
    queue, holder, holder_ev = replay(events)

    if op == "enqueue":
        task_id, branch, caller_pid = args[0], args[1], args[2]
        if task_id != holder and task_id not in queue:
            append_event({
                "ts": now_iso(), "type": "enqueued",
                "task_id": task_id, "branch": branch, "pid": int(caller_pid),
            })
        print("OK")

    elif op == "try_acquire":
        # Reclaim a dead+stale holder first, if any.
        reclaimed = False
        if holder is not None and holder_ev is not None:
            holder_pid = holder_ev.get("pid")
            holder_ts = holder_ev.get("ts", "")
            try:
                held_since = calendar.timegm(time.strptime(holder_ts, "%Y-%m-%dT%H:%M:%SZ"))
                age = time.time() - held_since
            except Exception:
                age = 0
            if not pid_alive(holder_pid) and age > stale_sec:
                append_event({
                    "ts": now_iso(), "type": "reclaimed",
                    "task_id": holder, "reason": "dead-holder-stale",
                })
                reclaimed = True
                events = read_events()
                queue, holder, holder_ev = replay(events)

        task_id, caller_pid = args[0], args[1]
        if holder is None and queue and queue[0] == task_id:
            append_event({
                "ts": now_iso(), "type": "acquired",
                "task_id": task_id, "pid": int(caller_pid),
            })
            print("ACQUIRED")
        else:
            print("RECLAIMED" if reclaimed else "WAIT")

    elif op == "release":
        task_id = args[0]
        if holder != task_id:
            sys.stderr.write(f"[merge-queue] {task_id} is not the current holder (holder={holder})\n")
            sys.exit(1)
        append_event({"ts": now_iso(), "type": "released", "task_id": task_id})
        print("OK")

    elif op == "timeout":
        task_id = args[0]
        append_event({"ts": now_iso(), "type": "timeout", "task_id": task_id})
        print("OK")

    elif op == "status":
        print(json.dumps({"holder": holder, "queue": queue}, sort_keys=True))

finally:
    fcntl.flock(lockf, fcntl.LOCK_UN)
    lockf.close()
PYEOF
}

[[ $# -ge 1 ]] || usage
CMD="$1"; shift

case "$CMD" in
  enqueue)
    [[ $# -eq 2 ]] || usage
    _txn enqueue "$1" "$2" "$OWNER_PID"
    ;;

  acquire)
    [[ $# -eq 1 ]] || usage
    TASK_ID="$1"
    _txn enqueue "$TASK_ID" "unknown" "$OWNER_PID" > /dev/null  # idempotent auto-enqueue
    SECONDS=0  # bash builtin: integer elapsed-seconds timer, reset here
    while true; do
      RESULT="$(_txn try_acquire "$TASK_ID" "$OWNER_PID")"
      if [[ "$RESULT" == "ACQUIRED" ]]; then
        exit 0
      fi
      if [[ "$RESULT" == "RECLAIMED" ]]; then
        # A stale holder was freed this poll — publish a bus finding so other
        # sessions see it, then re-poll immediately without sleeping.
        if [[ -x "$BUS_SH" ]]; then
          "$BUS_SH" publish "$TASK_ID" finding \
            '{"note":"merge-queue reclaimed a dead holder lock"}' 2>/dev/null || true
        fi
        continue
      fi
      if (( SECONDS > TIMEOUT_SEC )); then
        _txn timeout "$TASK_ID" "$OWNER_PID" > /dev/null
        printf -- '[merge-queue] acquire timeout after %ss for %s\n' "$TIMEOUT_SEC" "$TASK_ID" >&2
        exit 2
      fi
      sleep "$POLL_SEC"
    done
    ;;

  release)
    [[ $# -eq 1 ]] || usage
    _txn release "$1"
    ;;

  status)
    _txn status
    ;;

  *)
    usage
    ;;
esac
