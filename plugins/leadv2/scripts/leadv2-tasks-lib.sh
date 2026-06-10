#!/usr/bin/env bash
# leadv2-tasks-lib.sh — Bash library for docs/tasks.yaml operations.
# Source this file; do not execute directly.
#
# All write ops acquire /tmp/leadv2-tasks.lock (exclusive, 10s timeout).
# Read ops acquire shared lock.
#
# Usage: source .claude/scripts/leadv2-tasks-lib.sh

# ── Paths ──────────────────────────────────────────────────────────────────
if [ -n "${BASH_VERSION:-}" ]; then
  _TASKS_LIB_PATH="${BASH_SOURCE[0]}"
elif [ -n "${ZSH_VERSION:-}" ]; then
  _TASKS_LIB_PATH="${(%):-%x}"
else
  _TASKS_LIB_PATH="$0"
fi
_TASKS_LIB_DIR="$(cd "$(dirname "$_TASKS_LIB_PATH")" && pwd)"
_PROJECT_ROOT="${PROJECT_ROOT:-$(git -C "$_TASKS_LIB_DIR" rev-parse --show-toplevel)}"
_TASKS_FILE="${_PROJECT_ROOT}/docs/tasks.yaml"
_TASKS_LOCK="/tmp/leadv2-tasks.lock"

# Per-lane max_attempts defaults (used by add)
_TASKS_MAX_action=3
_TASKS_MAX_recovery=5
_TASKS_MAX_intelligence=1
_TASKS_MAX_human_needed=1

# ── Single Python dispatcher — all operations via one heredoc ─────────────
_tasks_dispatch() {
  python3 - "$_TASKS_FILE" "$_TASKS_LOCK" "$@" <<'DISPATCHER'
import sys, os, yaml, fcntl, time, datetime

tasks_file = sys.argv[1]
lock_path  = sys.argv[2]
op         = sys.argv[3]
args       = sys.argv[4:]

LANE_RANK     = {"recovery": 0, "action": 1, "intelligence": 2, "human-needed": 3}
PRIORITY_RANK = {"critical": 0, "high": 1, "medium": 2, "low": 3}
LANE_MAX      = {"action": 3, "recovery": 5, "intelligence": 1, "human-needed": 1}
LANE_TTL      = {"action": 90, "recovery": 60, "intelligence": 120, "human-needed": 60}
TERMINAL      = {"done", "poisoned", "rejected", "failed", "archived",
                 "closed", "completed", "admin-closed"}

def iso(dt): return dt.strftime("%Y-%m-%dT%H:%M:%SZ")
def now_iso(): return iso(datetime.datetime.utcnow())

def parse_dt(s):
    if not s: return datetime.datetime.min
    s = str(s).replace(" ", "T")
    if "+" in s: s = s.split("+")[0]
    if s.endswith("Z"): s = s[:-1]
    try: return datetime.datetime.strptime(s, "%Y-%m-%dT%H:%M:%S")
    except ValueError: return datetime.datetime.min

def acquire_lock(shared=False):
    fl = fcntl.LOCK_SH if shared else fcntl.LOCK_EX
    fd = open(lock_path, "w")
    deadline = time.time() + 10
    while True:
        try:
            fcntl.flock(fd, fl | fcntl.LOCK_NB); return fd
        except BlockingIOError:
            if time.time() > deadline:
                print("[tasks-lib] ERROR: lock timeout", file=sys.stderr); sys.exit(1)
            time.sleep(0.1)

def load_tasks():
    try:
        with open(tasks_file) as f: return yaml.safe_load(f) or []
    except FileNotFoundError: return []

def save_tasks(items):
    os.makedirs(os.path.dirname(tasks_file), exist_ok=True)
    tmp = tasks_file + ".tmp"
    with open(tmp, "w") as f:
        yaml.dump(items, f, default_flow_style=False, allow_unicode=True, sort_keys=False)
    os.replace(tmp, tasks_file)

def write_closed_sentinel(iid, outcome):
    # Uses a separate .tasks-sentinel- prefix to avoid collision with the
    # 13-field render-close YAML at docs/leadv2/closed/<id>.yaml.
    root = os.path.dirname(os.path.dirname(tasks_file))
    d    = os.path.join(root, "docs", "leadv2", "closed")
    os.makedirs(d, exist_ok=True)
    p = os.path.join(d, f".tasks-sentinel-{iid}.yaml")
    if not os.path.exists(p):
        tmp = p + ".tmp"
        with open(tmp, "w") as f:
            yaml.dump({"task_id": iid, "closed_at": now_iso(),
                       "outcome": "completed_success" if outcome == "success" else outcome,
                       "source": "tasks-lib"}, f, default_flow_style=False, sort_keys=True)
        os.replace(tmp, p)

def deps_done(item, by_id):
    """Return True if all depends_on items are in a terminal state.
    C1.5/D10: dep_id not found in by_id is treated as dep_missing (not satisfied).
    Returns False when any dep is missing or not terminal, preventing phantom claim.
    """
    for d in (item.get("context") or {}).get("depends_on") or []:
        dep = by_id.get(str(d))
        if dep is None:
            # dep_id not found => dep_missing; block claim (D10)
            item.setdefault("_dep_missing", []).append(str(d))
            return False
        if dep.get("status") not in TERMINAL:
            return False
    return True

def set_nested(obj, path, val):
    parts = path.split(".")
    for part in parts[:-1]: obj = obj.setdefault(part, {})
    if val in ("null", "~", ""): obj[parts[-1]] = None
    elif val.lower() == "true": obj[parts[-1]] = True
    elif val.lower() == "false": obj[parts[-1]] = False
    else:
        try: obj[parts[-1]] = int(val)
        except ValueError:
            try: obj[parts[-1]] = float(val)
            except ValueError: obj[parts[-1]] = val

# ── Dispatch ─────────────────────────────────────────────────────────────
if op == "top_n":
    top_n = int(args[0])
    fd = acquire_lock(shared=True)
    try:
        all_items = load_tasks()
        by_id = {str(it.get("id","")): it for it in all_items}
        candidates = []
        for it in all_items:
            lane = str(it.get("lane", ""))
            if lane == "human-needed": continue
            if str(it.get("status","")) != "pending": continue
            if (it.get("claim") or {}).get("by") is not None: continue
            if not deps_done(it, by_id):
                # C1.5/D10: surface dep_missing in dry-run top-N output
                missing = it.pop("_dep_missing", [])
                if missing:
                    print(f"[dep_missing] {it.get('id','')} blocked: dep(s) not found: {','.join(missing)}", file=sys.stderr)
                continue
            candidates.append((LANE_RANK.get(lane,99),
                               PRIORITY_RANK.get(str(it.get("priority","medium")),4),
                               parse_dt(it.get("created_at","")), str(it.get("id","")), lane, it))
        candidates.sort(key=lambda x: x[:4])
        for _, _, _, iid, lane, it in candidates[:top_n]:
            print(f"{lane}\t{it.get('priority','medium')}\t{iid}\t{it.get('title','')}")
    finally:
        fcntl.flock(fd, fcntl.LOCK_UN); fd.close()

elif op == "by_id":
    iid = args[0]; fd = acquire_lock(shared=True)
    try:
        for it in load_tasks():
            if str(it.get("id","")) == iid:
                print(yaml.dump([it], default_flow_style=False, allow_unicode=True, sort_keys=False), end="")
                sys.exit(0)
        sys.exit(1)
    finally:
        fcntl.flock(fd, fcntl.LOCK_UN); fd.close()

elif op == "list_status":
    target = args[0]; fd = acquire_lock(shared=True)
    try:
        for it in load_tasks():
            if str(it.get("status","")) == target:
                print(f"{it.get('lane','')}\t{it.get('id','')}")
    finally:
        fcntl.flock(fd, fcntl.LOCK_UN); fd.close()

elif op == "claim":
    iid, session = args[0], args[1]; fd = acquire_lock()
    try:
        items = load_tasks()
        for it in items:
            if str(it.get("id","")) != iid: continue
            claim = it.get("claim") or {}
            if claim.get("by") is not None:
                print(f"[tasks-lib] already claimed by {claim['by']}", file=sys.stderr); sys.exit(9)
            if str(it.get("status","")) != "pending":
                print(f"[tasks-lib] status={it.get('status')} not claimable", file=sys.stderr); sys.exit(1)
            lane = str(it.get("lane","action"))
            it["status"] = "in_progress"
            it["claim"]  = {"by": session, "lease_expires": iso(
                datetime.datetime.utcnow() + datetime.timedelta(minutes=LANE_TTL.get(lane,90)))}
            save_tasks(items); sys.exit(0)
        print(f"[tasks-lib] {iid} not found", file=sys.stderr); sys.exit(1)
    finally:
        fcntl.flock(fd, fcntl.LOCK_UN); fd.close()

elif op == "unclaim":
    # C1.4: release a collision-blocked task back to pending without incrementing attempts.
    # Atomically clears claim field and resets status to pending.
    iid = args[0]
    fd = acquire_lock()
    try:
        items = load_tasks()
        for it in items:
            if str(it.get("id","")) != iid: continue
            it["status"] = "pending"
            it["claim"]  = {"by": None, "lease_expires": None}
            it["last_error"] = None
            save_tasks(items); sys.exit(0)
        print(f"[tasks-lib] {iid} not found for unclaim", file=sys.stderr); sys.exit(1)
    finally:
        fcntl.flock(fd, fcntl.LOCK_UN); fd.close()

elif op == "release":
    iid, outcome, error_msg = args[0], args[1], args[2]
    fd = acquire_lock()
    try:
        items = load_tasks()
        now = datetime.datetime.utcnow()
        for it in items:
            if str(it.get("id","")) != iid: continue
            lane    = str(it.get("lane","action"))
            max_att = int(it.get("max_attempts", LANE_MAX.get(lane,3)))
            if outcome == "success":
                it.update({"status":"done","claim":{"by":None,"lease_expires":None},
                           "closed_at":iso(now),"last_error":None})
            elif outcome == "fail":
                att = int(it.get("attempts",0)) + 1
                it["attempts"] = att; it["claim"] = {"by":None,"lease_expires":None}
                if att >= max_att:
                    it.update({"status":"poisoned","reject_reason":error_msg or f"Max attempts ({max_att}) reached","closed_at":iso(now)})
                else:
                    it.update({"status":"pending","last_error":error_msg or "task failed","closed_at":None})
            elif outcome == "poison":
                it.update({"status":"poisoned","reject_reason":error_msg,
                           "claim":{"by":None,"lease_expires":None},"closed_at":iso(now)})
            else:
                print(f"[tasks-lib] unknown outcome {outcome}", file=sys.stderr); sys.exit(1)
            save_tasks(items)
            if outcome in ("success","poison"): write_closed_sentinel(iid, outcome)
            sys.exit(0)
        print(f"[tasks-lib] {iid} not found", file=sys.stderr); sys.exit(3)
    finally:
        fcntl.flock(fd, fcntl.LOCK_UN); fd.close()

elif op == "add":
    # args: iid lane priority title origin note max_att [files_hint_json] [depends_on_json] [conflicts_with_json]
    iid, lane, priority, title, origin, note, max_att = (
        args[0], args[1], args[2], args[3], args[4], args[5], int(args[6]))
    import json as _json
    files_hint     = _json.loads(args[7]) if len(args) > 7 and args[7] else []
    depends_on     = _json.loads(args[8]) if len(args) > 8 and args[8] else []
    conflicts_with = _json.loads(args[9]) if len(args) > 9 and args[9] else []
    fd = acquire_lock()
    try:
        items = load_tasks()
        for it in items:
            if str(it.get("id","")) == iid:
                print(f"[tasks-lib] {iid} already exists", file=sys.stderr); sys.exit(9)
        items.append({"id":iid,"lane":lane,"priority":priority,"status":"pending","title":title,
                      "created_at":now_iso(),"closed_at":None,"origin":origin or None,
                      "claim":{"by":None,"lease_expires":None},"attempts":0,"max_attempts":max_att,
                      "last_error":None,"reject_reason":None,"summary_one_line":None,
                      "context":{
                          # files: legacy list of file paths (not globs) — kept for backward compat
                          "files":[],
                          # files_hint: list of repo-relative glob patterns for collision detection (C1.1/D14)
                          "files_hint": files_hint or [],
                          # depends_on: list of task IDs that must be in terminal state before this task claims (completion dependency)
                          "depends_on": depends_on or [],
                          # conflicts_with: list of task IDs that must NOT be active simultaneously (active-session mutex)
                          "conflicts_with": conflicts_with or [],
                          "note":note or None
                      },"notes":None})
        save_tasks(items)
    finally:
        fcntl.flock(fd, fcntl.LOCK_UN); fd.close()

elif op == "update":
    iid, key_path, value = args[0], args[1], args[2]; fd = acquire_lock()
    try:
        items = load_tasks()
        for it in items:
            if str(it.get("id","")) == iid:
                set_nested(it, key_path, value); save_tasks(items); sys.exit(0)
        print(f"[tasks-lib] {iid} not found", file=sys.stderr); sys.exit(1)
    finally:
        fcntl.flock(fd, fcntl.LOCK_UN); fd.close()

elif op == "archive":
    older_days, archive_dir = int(args[0]), args[1]
    cutoff = datetime.datetime.utcnow() - datetime.timedelta(days=older_days)
    fd = acquire_lock()
    try:
        items = load_tasks(); keep, by_month = [], {}
        for it in items:
            if str(it.get("status","")) not in TERMINAL: keep.append(it); continue
            closed = parse_dt(it.get("closed_at"))
            if closed is None or closed >= cutoff: keep.append(it); continue
            by_month.setdefault(closed.strftime("%Y-%m"), []).append(it)
        count = sum(len(v) for v in by_month.values())
        if count == 0: print("[tasks-lib] nothing to archive", file=sys.stderr); sys.exit(0)
        os.makedirs(archive_dir, exist_ok=True)
        for mk, archived in by_month.items():
            af = os.path.join(archive_dir, f"tasks-archive-{mk}.yaml")
            existing = (yaml.safe_load(open(af).read()) if os.path.exists(af) else []) or []
            tmp = af + ".tmp"
            with open(tmp,"w") as f:
                yaml.dump(existing + archived, f, default_flow_style=False, allow_unicode=True, sort_keys=False)
            os.replace(tmp, af)
        save_tasks(keep)
        print(f"[tasks-lib] archived {count}; {len(keep)} remain", file=sys.stderr)
    finally:
        fcntl.flock(fd, fcntl.LOCK_UN); fd.close()

elif op == "next_for_lane":
    lane = args[0]; fd = acquire_lock(shared=True)
    try:
        all_items = load_tasks()
        by_id = {str(it.get("id","")): it for it in all_items}
        candidates = []
        for it in all_items:
            if str(it.get("lane","")) != lane: continue
            if str(it.get("status","")) != "pending": continue
            if (it.get("claim") or {}).get("by") is not None: continue
            if not deps_done(it, by_id): continue
            candidates.append((PRIORITY_RANK.get(str(it.get("priority","medium")),4),
                               parse_dt(it.get("created_at","")), str(it.get("id",""))))
        candidates.sort()
        if not candidates: sys.exit(1)
        print(candidates[0][2])
    finally:
        fcntl.flock(fd, fcntl.LOCK_UN); fd.close()

else:
    print(f"[tasks-lib] unknown op: {op}", file=sys.stderr); sys.exit(1)
DISPATCHER
}

# ── Public API ────────────────────────────────────────────────────────────

leadv2_tasks_top_n() {
  local n="${1:?leadv2_tasks_top_n requires N}"
  _tasks_dispatch top_n "$n"
}

leadv2_tasks_by_id() {
  local id="${1:?leadv2_tasks_by_id requires ID}"
  _tasks_dispatch by_id "$id"
}

leadv2_tasks_list_status() {
  local status="${1:?leadv2_tasks_list_status requires STATUS}"
  _tasks_dispatch list_status "$status"
}

leadv2_tasks_unclaim() {
  # C1.4: Atomically release a collision-blocked task back to pending.
  # Does not increment attempt counter -- task is eligible for re-claim next cycle.
  local item_id="${1:?leadv2_tasks_unclaim requires ID}"
  _tasks_dispatch unclaim "$item_id"
}

leadv2_tasks_claim() {
  local item_id="${1:?leadv2_tasks_claim requires ID}"
  local session=""
  shift
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --by) session="$2"; shift 2 ;;
      *) echo "[tasks-lib] unknown arg: $1" >&2; return 1 ;;
    esac
  done
  [[ -n "$session" ]] || { echo "[tasks-lib] --by SESSION required" >&2; return 1; }
  _tasks_dispatch claim "$item_id" "$session"
}

leadv2_tasks_release() {
  local item_id="${1:?leadv2_tasks_release requires ID}"
  local outcome="" error_msg=""
  shift
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --outcome) outcome="$2"; shift 2 ;;
      --error)   error_msg="$2"; shift 2 ;;
      *) echo "[tasks-lib] unknown arg: $1" >&2; return 1 ;;
    esac
  done
  [[ -n "$outcome" ]] || { echo "[tasks-lib] --outcome required" >&2; return 1; }
  _tasks_dispatch release "$item_id" "$outcome" "${error_msg:-}"
}

leadv2_tasks_add() {
  local item_id="${1:?leadv2_tasks_add requires ID}"
  local lane="${2:?leadv2_tasks_add requires LANE}"
  local priority="${3:?leadv2_tasks_add requires PRIORITY}"
  # C1.1: new optional fields -- files_hint (JSON array of glob patterns),
  # depends_on (JSON array of task IDs), conflicts_with (JSON array of task IDs).
  # Absent = empty list (backward-compat).
  local title="" origin="" note="" files_hint="" depends_on="" conflicts_with=""
  shift 3
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --title)          title="$2";          shift 2 ;;
      --origin)         origin="$2";         shift 2 ;;
      --note)           note="$2";           shift 2 ;;
      --files-hint)     files_hint="$2";     shift 2 ;;
      --depends-on)     depends_on="$2";     shift 2 ;;
      --conflicts-with) conflicts_with="$2"; shift 2 ;;
      *) echo "[tasks-lib] unknown arg: $1" >&2; return 1 ;;
    esac
  done
  [[ -n "$title" ]] || { echo "[tasks-lib] --title required" >&2; return 1; }
  local max_att
  case "$lane" in
    action)        max_att=3 ;;
    recovery)      max_att=5 ;;
    intelligence)  max_att=1 ;;
    human-needed)  max_att=1 ;;
    *)             max_att=3 ;;
  esac
  _tasks_dispatch add "$item_id" "$lane" "$priority" "$title" "${origin:-}" "${note:-}" "$max_att"     "${files_hint:-}" "${depends_on:-}" "${conflicts_with:-}"
}

leadv2_tasks_update() {
  local item_id="${1:?leadv2_tasks_update requires ID}"
  local key="" value=""
  shift
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --key)   key="$2";   shift 2 ;;
      --value) value="$2"; shift 2 ;;
      *) echo "[tasks-lib] unknown arg: $1" >&2; return 1 ;;
    esac
  done
  [[ -n "$key" ]] || { echo "[tasks-lib] --key required" >&2; return 1; }
  _tasks_dispatch update "$item_id" "$key" "${value:-}"
}

leadv2_tasks_archive() {
  local days=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --older-than-days) days="$2"; shift 2 ;;
      *) echo "[tasks-lib] unknown arg: $1" >&2; return 1 ;;
    esac
  done
  [[ -n "$days" ]] || { echo "[tasks-lib] --older-than-days required" >&2; return 1; }
  # Use LEADV2_QUEUE_ARCHIVE_DIR if set (via _lv2_load_paths), else default.
  local archive_dir="${LEADV2_QUEUE_ARCHIVE_DIR:-${_PROJECT_ROOT}/docs/agents/product-owner/queue/_archive}"
  _tasks_dispatch archive "$days" "$archive_dir"
}

leadv2_tasks_render() {
  bash "${_TASKS_LIB_DIR}/leadv2-tasks-render.sh" "$@"
}

# Internal helper used by queue-claim.sh --lane mode
leadv2_tasks_next_for_lane() {
  local lane="${1:?leadv2_tasks_next_for_lane requires LANE}"
  _tasks_dispatch next_for_lane "$lane"
}
