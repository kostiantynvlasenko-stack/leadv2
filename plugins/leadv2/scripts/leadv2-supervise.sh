#!/usr/bin/env bash
# leadv2-supervise.sh — one call = one snapshot of all child /leadv2 sessions.
#
# Task LEAD-SUPERVISE-01. See docs/handoff/LEAD-ANCHOR-01/mission-supervise.md.
#
# Reads (no network, files only):
#   docs/leadv2/active.yaml                         — live session registry
#     (schema per ~/.claude/leadv2-shared/scripts/leadv2-active-registry.sh:
#      session_id, task_id, worktree, branch, started_at, phase, class, pid,
#      pid_birth, last_pulse_at, stale, note)
#   docs/handoff/<task_id>/questions-async/*-pending.yaml (+ sibling
#     *-answered.yaml) — the EXISTING async question store (leadv2-helpers.sh
#     leadv2_ask_async / leadv2-reply.sh). This script does not write to it —
#     read-only.
#   docs/handoff/<task_id>/phase8-passed.flag        — close signal
#
# Writes:
#   docs/leadv2/.supervise-last.json                 — snapshot state (for
#     --since delta mode and for "closed since last snapshot" detection)
#
# Usage:
#   leadv2-supervise.sh [--json] [--since <ISO>]
#
# Exit codes: 0 = always (this is a read-only status probe; a broken/missing
# active.yaml is reported as a warning, never a hard failure).
#
# lean: minutes-in-phase uses last_pulse_at (freshness) falling back to
# started_at (session age) — active.yaml has no per-phase-entry timestamp.
# upgrade when leadv2-active-registry.sh adds phase_started_at.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${LEADV2_PROJECT_ROOT:-${CLAUDE_PROJECT_DIR:-${PROJECT_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}}}"

# LEAD-CONTROL-PLANE-01: active.yaml lives in the control plane (outside any
# worktree) — resolved via leadv2-state-path.sh, never hardcoded here.
ACTIVE_YAML="$(PROJECT_ROOT="$PROJECT_ROOT" "${SCRIPT_DIR}/leadv2-state-path.sh" active.yaml)"
HANDOFF_DIR="${PROJECT_ROOT}/docs/handoff"
SNAPSHOT="$(PROJECT_ROOT="$PROJECT_ROOT" "${SCRIPT_DIR}/leadv2-state-path.sh" .supervise-last.json)"
SUPERVISE_SENTINEL="$(PROJECT_ROOT="$PROJECT_ROOT" "${SCRIPT_DIR}/leadv2-state-path.sh" .supervise-active)"

# SUPERVISE-GUARD-01: (re)write the supervise-mode sentinel -- {"pid","started_at"}
# -- consumed by hooks/leadv2-supervise-fanout-guard.sh (PreToolUse:Agent) to block
# in-session WORKER subagent spawns while supervise mode is active; the lead must
# dispatch new work via scripts/leadv2-fanout.sh instead. Idempotent: a live
# sentinel keeps its original started_at; a missing/dead one is (re)written with
# the durable claude-process pid (see leadv2-active-registry.sh:_lv2_durable_pid).
# Cleared on Stop by hooks/leadv2-supervise-sentinel-cleanup.sh, and self-heals
# (deleted) by the guard itself the next time it sees a dead pid.
if [[ -f "${SCRIPT_DIR}/leadv2-active-registry.sh" ]]; then
  # shellcheck source=leadv2-active-registry.sh
  source "${SCRIPT_DIR}/leadv2-active-registry.sh"
  _SUP_PID="$(_lv2_durable_pid 2>/dev/null || echo "$PPID")"
  _SUP_TS="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  python3 - "$SUPERVISE_SENTINEL" "$_SUP_PID" "$_SUP_TS" <<'PYSENTINEL' 2>/dev/null || true
import sys, os, json, tempfile

path, pid_str, ts = sys.argv[1], sys.argv[2], sys.argv[3]

def pid_alive(pid_val):
    try:
        os.kill(int(pid_val), 0)
        return True
    except (TypeError, ValueError, ProcessLookupError, PermissionError):
        return False

existing_started_at = None
if os.path.isfile(path):
    try:
        with open(path, encoding="utf-8") as fh:
            d = json.load(fh) or {}
        if pid_alive(d.get("pid")):
            existing_started_at = d.get("started_at")
    except Exception:
        pass

out = {"pid": int(pid_str), "started_at": existing_started_at or ts}
dir_ = os.path.dirname(path)
os.makedirs(dir_, exist_ok=True)
fd, tmp = tempfile.mkstemp(dir=dir_, suffix=".tmp")
with os.fdopen(fd, "w", encoding="utf-8") as fh:
    json.dump(out, fh, indent=2)
os.replace(tmp, path)
PYSENTINEL
fi

JSON_MODE=0
SINCE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --json)  JSON_MODE=1; shift ;;
    --since) SINCE="${2:-}"; shift 2 ;;
    -h|--help)
      printf -- 'Usage: leadv2-supervise.sh [--json] [--since <ISO>]\n'
      exit 0
      ;;
    *)
      printf -- '[supervise] unknown arg: %s\n' "$1" >&2
      exit 1
      ;;
  esac
done

python3 - "$ACTIVE_YAML" "$HANDOFF_DIR" "$SNAPSHOT" "$JSON_MODE" "$SINCE" <<'PY'
import sys, os, json, glob, datetime

active_yaml, handoff_dir, snapshot_path, json_mode, since = sys.argv[1:6]
json_mode = json_mode == "1"
delta_mode = bool(since)

STUCK_MIN = 25
CAP_ROWS = 20

def now_iso():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

def parse_iso(s):
    if not s:
        return None
    try:
        s2 = s.rstrip("Z")
        dt = datetime.datetime.fromisoformat(s2)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=datetime.timezone.utc)
        return dt
    except Exception:
        return None

def pid_alive(pid_val):
    try:
        pid = int(pid_val)
        os.kill(pid, 0)
        return True
    except (TypeError, ValueError, ProcessLookupError, PermissionError):
        return False

# ── Load active.yaml (warn, never crash, on broken file) ───────────────────
warnings = []
sessions = []
try:
    import yaml
    with open(active_yaml, encoding="utf-8") as fh:
        data = yaml.safe_load(fh) or {}
    raw_sessions = data.get("sessions") if isinstance(data, dict) else None
    if raw_sessions is None:
        raw_sessions = []
    if not isinstance(raw_sessions, list):
        warnings.append(f"active.yaml: sessions is not a list ({type(raw_sessions).__name__}) — treating as empty")
        raw_sessions = []
    for s in raw_sessions:
        if not isinstance(s, dict) or not s.get("task_id"):
            warnings.append("active.yaml: dropped malformed session entry")
            continue
        sessions.append(s)
except FileNotFoundError:
    warnings.append(f"active.yaml not found at {active_yaml}")
except Exception as e:
    warnings.append(f"active.yaml parse error ({e.__class__.__name__}: {e}) — treating as no live sessions")

current = {s["task_id"]: s for s in sessions}  # last-write-wins on dup task_id

# ── Load previous snapshot ──────────────────────────────────────────────────
prev = {}
if os.path.isfile(snapshot_path):
    try:
        with open(snapshot_path, encoding="utf-8") as fh:
            prev = json.load(fh) or {}
    except Exception:
        warnings.append(f"{snapshot_path} unreadable — starting fresh snapshot")
        prev = {}
prev_tasks = prev.get("tasks", {}) if isinstance(prev, dict) else {}
prev_reported = set(prev.get("reported_events", []) if isinstance(prev, dict) else [])

now = datetime.datetime.now(datetime.timezone.utc)

# ── has_flag (closed) per known task_id ─────────────────────────────────────
def flag_path(tid):
    return os.path.join(handoff_dir, tid, "phase8-passed.flag")

known_ids = set(current) | set(prev_tasks)
closed_now = []
new_snapshot_tasks = {}

for tid in known_ids:
    has_flag = os.path.isfile(flag_path(tid))
    prev_flag = bool(prev_tasks.get(tid, {}).get("has_flag", False))
    if has_flag and not prev_flag:
        closed_now.append(tid)
    if tid in current:
        entry = dict(current[tid])
        entry["has_flag"] = has_flag
        new_snapshot_tasks[tid] = entry
    elif not has_flag:
        # still unresolved, vanished from active.yaml without a close flag —
        # keep tracking one more cycle so we don't lose a genuine close event
        entry = dict(prev_tasks.get(tid, {}))
        entry["has_flag"] = has_flag
        new_snapshot_tasks[tid] = entry
    # else: has_flag True and no longer in current — already reported (now or
    # earlier); drop from snapshot, nothing more to watch.

# ── Table + waiting + stuck (only for currently-live sessions) ─────────────
table = []
waiting_items = []
stuck_items = []

for tid, s in sorted(current.items()):
    phase = s.get("phase") or "?"
    status = "stale" if s.get("stale") else "active"
    started_at = parse_iso(s.get("started_at"))
    last_pulse = parse_iso(s.get("last_pulse_at"))
    ref_ts = last_pulse or started_at
    minutes = int((now - ref_ts).total_seconds() // 60) if ref_ts else None

    # waiting-for-answer: open questions-async pending files with no sibling answered
    qdir = os.path.join(handoff_dir, tid, "questions-async")
    open_qs = []
    if os.path.isdir(qdir):
        for pf in sorted(glob.glob(os.path.join(qdir, "*-pending.yaml"))):
            qid = os.path.basename(pf)[:-len("-pending.yaml")]
            answered = os.path.join(qdir, f"{qid}-answered.yaml")
            if os.path.isfile(answered):
                continue
            question = ""
            options = []
            summary = ""
            try:
                import yaml
                with open(pf, encoding="utf-8") as fh:
                    qd = yaml.safe_load(fh) or {}
                question = qd.get("question", "")
                summary = qd.get("summary_for_lead", "")
                options = [o.get("label", "") for o in (qd.get("options") or []) if isinstance(o, dict)]
            except Exception:
                pass
            open_qs.append({"qid": qid, "task_id": tid, "question": question,
                             "summary_for_lead": summary, "options": options})
    is_waiting = bool(open_qs)
    waiting_items.extend(open_qs)

    is_flagged_closed = new_snapshot_tasks.get(tid, {}).get("has_flag", False)
    reasons = []
    if not is_flagged_closed:
        if minutes is not None and minutes > STUCK_MIN:
            reasons.append(f">{STUCK_MIN}m in phase '{phase}'")
        pid = s.get("pid")
        if pid is not None and not pid_alive(pid):
            reasons.append("pid dead")
        if s.get("stale"):
            reasons.append("marked stale")
    if reasons:
        stuck_items.append({"task_id": tid, "reasons": reasons})

    table.append({
        "task_id": tid, "phase": phase,
        "minutes_in_phase": minutes if minutes is not None else "?",
        "status": status, "waiting": is_waiting,
    })

table = table[:CAP_ROWS]

# ── Delta / event-key bookkeeping ───────────────────────────────────────────
current_events = set()
for q in waiting_items:
    current_events.add(f"waiting:{q['task_id']}:{q['qid']}")
for st in stuck_items:
    current_events.add(f"stuck:{st['task_id']}:{'|'.join(st['reasons'])}")
for tid in closed_now:
    current_events.add(f"closed:{tid}")

new_events = current_events - prev_reported if delta_mode else current_events

# ── Persist snapshot ─────────────────────────────────────────────────────────
try:
    os.makedirs(os.path.dirname(snapshot_path), exist_ok=True)
    tmp = snapshot_path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump({
            "rendered_at": now_iso(),
            "tasks": new_snapshot_tasks,
            "reported_events": sorted(current_events),
        }, fh, indent=2)
    os.replace(tmp, snapshot_path)
except Exception as e:
    warnings.append(f"could not write snapshot: {e}")

# ── Filter output items to only the ones whose event_key is in new_events ──
def event_key_waiting(q):
    return f"waiting:{q['task_id']}:{q['qid']}"

def event_key_stuck(st):
    return f"stuck:{st['task_id']}:{'|'.join(st['reasons'])}"

out_waiting = [q for q in waiting_items if event_key_waiting(q) in new_events] if delta_mode else waiting_items
out_stuck = [st for st in stuck_items if event_key_stuck(st) in new_events] if delta_mode else stuck_items
out_closed = [tid for tid in closed_now if f"closed:{tid}" in new_events] if delta_mode else closed_now

# ── Render ────────────────────────────────────────────────────────────────
if json_mode:
    result = {
        "warnings": warnings,
        "delta_mode": delta_mode,
        "table": [] if (delta_mode and not new_events) else table,
        "requires_founder": out_waiting,
        "stuck": out_stuck,
        "closed_since_last": out_closed,
    }
    print(json.dumps(result, indent=2))
    sys.exit(0)

for w in warnings:
    print(f"WARN: {w}", file=sys.stderr)

if delta_mode:
    if not new_events:
        # silence — no new event since last snapshot; not an error
        sys.exit(0)
    if out_waiting:
        print("=== TREBUET TEBYA (open questions) ===")
        for q in out_waiting:
            opts = ", ".join(q["options"]) if q["options"] else "?"
            print(f"  [{q['qid']}] {q['task_id']}: {q['question']} (options: {opts})")
    if out_stuck:
        print("=== ZASTRYALO ===")
        for st in out_stuck:
            print(f"  {st['task_id']}: {'; '.join(st['reasons'])}")
    if out_closed:
        print("=== ZAKRYTO ===")
        for tid in out_closed:
            print(f"  {tid}")
    sys.exit(0)

if not current:
    print("net zhivykh sessiy (no live sessions)")
    sys.exit(0)

print(f"{'TASK-ID':<28} {'phase':<12} {'min':>4} {'status':<8} {'waiting?'}")
for row in table:
    print(f"{row['task_id']:<28} {row['phase']:<12} {str(row['minutes_in_phase']):>4} "
          f"{row['status']:<8} {'yes' if row['waiting'] else 'no'}")

if waiting_items:
    print("\n=== TREBUET TEBYA (open questions) ===")
    for q in waiting_items:
        opts = ", ".join(q["options"]) if q["options"] else "?"
        print(f"  [{q['qid']}] {q['task_id']}: {q['question']} (options: {opts})")

if stuck_items:
    print("\n=== ZASTRYALO ===")
    for st in stuck_items:
        print(f"  {st['task_id']}: {'; '.join(st['reasons'])}")

if closed_now:
    print("\n=== ZAKRYTO s proshlogo snimka ===")
    for tid in closed_now:
        print(f"  {tid}")
PY
