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
#     leadv2_ask_async / leadv2-reply.sh). Worktree-local — only visible when
#     this script's PROJECT_ROOT is that same worktree.
#   <control-plane>/questions/<qid>.yaml (leadv2-state-path.sh questions) —
#     the LEAD-ANCHOR-01 cross-worktree question store, written by
#     scripts/leadv2-ask.sh, answered by scripts/leadv2-answer.sh. TRUE
#     control-plane (outside any worktree) — this is what makes fanned-out
#     sessions (each in their own `git worktree add` checkout) visible to the
#     supervising lead. This script does not write to either store — read-only.
#   docs/handoff/<task_id>/phase8-passed.flag        — close signal
#
# Writes:
#   docs/leadv2/.supervise-last.json                 — snapshot state (for
#     --since delta mode and for "closed since last snapshot" detection)
#
# Usage:
#   leadv2-supervise.sh [--json] [--since <ISO>]
#
# Exit codes: 0 = reconciled snapshot rendered (table may legitimately be
# empty). Non-zero = fail-closed (B1, SUPERVISE-V2-01): unresolvable project
# root, missing/malformed active.yaml, or an unwritable snapshot path all
# exit non-zero with a typed JSON error ({"error": "root_error"|"registry_
# error"|"state_write_error", "message": ...} in --json mode, `[supervise]
# <kind>: <message>` on stderr otherwise). Only a registry that PARSED
# CLEANLY may report `table: []` — a missing/malformed registry is never
# silently treated as "no sessions".
#
# lean: minutes-in-phase uses last_pulse_at (freshness) falling back to
# started_at (session age) — active.yaml has no per-phase-entry timestamp.
# upgrade when leadv2-active-registry.sh adds phase_started_at.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── B1 fail-closed arg parse (BEFORE root resolution — a root error must
# know whether to render as JSON or plain stderr) ──────────────────────────
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

# ── B1 fail-closed root resolution (SUPERVISE-V2-01 D-b/item-2) ────────────
# Order: LEADV2_PROJECT_ROOT -> CLAUDE_PROJECT_DIR -> `git -C "$PWD" rev-parse
# --show-toplevel`. NEVER a script-dir fallback (that let a wrong/empty root
# silently resolve to this script's OWN parent dir and report a false-clean
# empty registry) and NEVER a bare ambient `$PROJECT_ROOT`/`$(pwd)` fallback
# (an unrelated/garbage PROJECT_ROOT env var must not be trusted silently).
PROJECT_ROOT=""
if [[ -n "${LEADV2_PROJECT_ROOT:-}" ]]; then
  PROJECT_ROOT="$LEADV2_PROJECT_ROOT"
elif [[ -n "${CLAUDE_PROJECT_DIR:-}" ]]; then
  PROJECT_ROOT="$CLAUDE_PROJECT_DIR"
elif _lv2_git_top="$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null)"; then
  PROJECT_ROOT="$_lv2_git_top"
fi

if [[ -z "$PROJECT_ROOT" ]]; then
  _lv2_err_msg="root_error: could not resolve project root — set LEADV2_PROJECT_ROOT or CLAUDE_PROJECT_DIR, or run from inside a git worktree (cwd=${PWD})"
  if [[ "$JSON_MODE" -eq 1 ]]; then
    printf -- '{"error":"root_error","message":%s}\n' "$(printf '%s' "$_lv2_err_msg" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))')"
  else
    printf -- '[supervise] %s\n' "$_lv2_err_msg" >&2
  fi
  exit 1
fi

# LEAD-CONTROL-PLANE-01: active.yaml lives in the control plane (outside any
# worktree) — resolved via leadv2-state-path.sh, never hardcoded here.
ACTIVE_YAML="$(PROJECT_ROOT="$PROJECT_ROOT" "${SCRIPT_DIR}/leadv2-state-path.sh" active.yaml)"
HANDOFF_DIR="${PROJECT_ROOT}/docs/handoff"
SNAPSHOT="$(PROJECT_ROOT="$PROJECT_ROOT" "${SCRIPT_DIR}/leadv2-state-path.sh" .supervise-last.json)"
SUPERVISE_SENTINEL="$(PROJECT_ROOT="$PROJECT_ROOT" "${SCRIPT_DIR}/leadv2-state-path.sh" .supervise-active)"

# SUPERVISE-GUARD-01 (restored, SUPERVISE-V2-01 fix-1 C1): (re)write the
# supervise-mode sentinel -- {"pid","started_at"} -- consumed by
# hooks/leadv2-supervise-fanout-guard.sh (PreToolUse:Agent) to block
# in-session WORKER subagent spawns while supervise mode is active; the lead
# must dispatch new work via scripts/leadv2-fanout.sh instead. Idempotent: a
# live sentinel keeps its original started_at; a missing/dead one is
# (re)written with the durable claude-process pid (see
# leadv2-active-registry.sh:_lv2_durable_pid). Cleared on Stop by
# hooks/leadv2-supervise-sentinel-cleanup.sh, and self-heals (deleted) by the
# guard itself the next time it sees a dead pid. Deleted by 799dc99's B1
# root-resolution refactor and never re-added -- guard was silently inert
# (lying-green: hook installed, reads a file nobody wrote) until this fix.
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

# LEAD-ANCHOR-01: true control-plane questions dir — shared across every
# worktree of this repo, unlike HANDOFF_DIR above.
CP_QUESTIONS_DIR="$(PROJECT_ROOT="$PROJECT_ROOT" "${SCRIPT_DIR}/leadv2-state-path.sh" questions)"
# SUPERVISOR-RETRO-01 §5: consume the `closed` bus event published by
# scripts/leadv2-finish.sh — a second, independent signal alongside the
# phase8-passed.flag diff above (a task can close via leadv2-finish.sh from
# a HOST outside this worktree, where the flag file may not be visible yet).
LEADV2_DIR_RESOLVED="$(PROJECT_ROOT="$PROJECT_ROOT" "${SCRIPT_DIR}/leadv2-state-path.sh" 2>/dev/null || true)"
BUS_JSONL="${LEADV2_DIR_RESOLVED:+${LEADV2_DIR_RESOLVED}/bus.jsonl}"
BUS_OFFSET_FILE="${LEADV2_DIR_RESOLVED:+${LEADV2_DIR_RESOLVED}/.bus-offsets/supervise-closed-consumer}"

# SUPERVISOR-RETRO-01 item 3: run the phase reconciliation backfill from the
# supervisor heartbeat (this script IS the repeated /leadv2 heartbeat poll —
# founder-facing Monitor loops call it on a cadence). The Write|Edit hook
# handles the common case live; this reconciles any task whose phase drifted
# (missed hook invocation, hook timeout, task registered before the hook
# existed). Best-effort and non-fatal — this script's contract is "exit 0
# always" (a read-only status probe) — but errors are surfaced on stderr,
# never swallowed to /dev/null, so a broken backfill is visible in logs.
PHASE_BACKFILL_SH="${PROJECT_ROOT}/.claude/scripts/leadv2-phase-backfill.sh"
if [[ -f "$PHASE_BACKFILL_SH" ]]; then
  if ! BACKFILL_OUT="$(LEADV2_PROJECT_ROOT="$PROJECT_ROOT" bash "$PHASE_BACKFILL_SH" 2>&1)"; then
    printf -- '[supervise] WARN: phase-backfill reconciliation failed:\n%s\n' "$BACKFILL_OUT" >&2
  fi
fi

# Informational only: retain valid JSON for --json consumers, while the human
# snapshot gets one best-effort provider-split line.
if [[ "$JSON_MODE" -eq 0 && -z "$SINCE" ]]; then
  ROLLUP_SH="${SCRIPT_DIR}/leadv2-provider-rollup.sh"
  if [[ -x "$ROLLUP_SH" ]]; then
    "$ROLLUP_SH" || printf -- 'provider-rollup: unavailable\n'
  fi
fi

python3 - "$ACTIVE_YAML" "$HANDOFF_DIR" "$SNAPSHOT" "$JSON_MODE" "$SINCE" "$CP_QUESTIONS_DIR" "${BUS_JSONL:-}" "${BUS_OFFSET_FILE:-}" <<'PY'
import sys, os, json, glob, datetime

active_yaml, handoff_dir, snapshot_path, json_mode, since, cp_questions_dir, bus_jsonl, bus_offset_file = sys.argv[1:9]
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

def emit_fatal(kind, message):
    """B1 fail-closed: registry_error / state_write_error. Never a successful
    empty table — only a registry that PARSED CLEANLY may return table: []."""
    if json_mode:
        print(json.dumps({"error": kind, "message": message}, indent=2))
    else:
        print(f"[supervise] {kind}: {message}", file=sys.stderr)
    sys.exit(1)

# ── Load active.yaml — fail closed on missing/malformed registry ───────────
# Only a file that exists AND parses to a dict with a `sessions` list is a
# "successfully reconciled" registry (individual malformed rows are dropped
# with a warning, per-row — that's reconciliation, not a registry defect).
warnings = []
sessions = []
if not os.path.isfile(active_yaml):
    emit_fatal("registry_error", f"active.yaml not found at {active_yaml} (never initialized — run leadv2-active-registry.sh to create it)")
try:
    import yaml
    with open(active_yaml, encoding="utf-8") as fh:
        data = yaml.safe_load(fh) or {}
except Exception as e:
    emit_fatal("registry_error", f"active.yaml parse error ({e.__class__.__name__}: {e}) at {active_yaml}")

if not isinstance(data, dict):
    emit_fatal("registry_error", f"active.yaml root is not a mapping ({type(data).__name__}) at {active_yaml}")

raw_sessions = data.get("sessions")
if raw_sessions is None:
    raw_sessions = []
if not isinstance(raw_sessions, list):
    emit_fatal("registry_error", f"active.yaml: sessions is not a list ({type(raw_sessions).__name__}) at {active_yaml}")

for s in raw_sessions:
    if not isinstance(s, dict) or not s.get("task_id"):
        warnings.append("active.yaml: dropped malformed session entry")
        continue
    sessions.append(s)

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

# ── `closed` bus-event consumer (SUPERVISOR-RETRO-01 §5) ────────────────────
# Reads new lines since the last call (stateful offset file — no flock: this
# is a periodic read-only status probe, not a mutation path; worst case on a
# torn concurrent read is a `closed` line reported one cycle late, never
# lost, since the offset only advances past lines successfully parsed).
# lean: no flock on the offset file — upgrade when >1 supervisor process
# reads bus.jsonl concurrently (today: one supervising lead per repo).
bus_closed_ids = []
if bus_jsonl and os.path.isfile(bus_jsonl):
    start = 0
    if bus_offset_file and os.path.isfile(bus_offset_file):
        try:
            start = int(open(bus_offset_file, encoding="utf-8").read().strip() or "0")
        except Exception:
            start = 0
    try:
        with open(bus_jsonl, encoding="utf-8") as fh:
            lines = fh.read().splitlines()
    except Exception:
        lines = []
    for line in lines[start:]:
        if not line.strip():
            continue
        try:
            ev = json.loads(line)
        except Exception:
            continue
        if ev.get("type") == "closed" and ev.get("task_id"):
            bus_closed_ids.append(ev["task_id"])
    if bus_offset_file:
        try:
            os.makedirs(os.path.dirname(bus_offset_file), exist_ok=True)
            tmp = bus_offset_file + f".tmp.{os.getpid()}"
            with open(tmp, "w", encoding="utf-8") as fh:
                fh.write(str(len(lines)))
            os.replace(tmp, bus_offset_file)
        except Exception as e:
            warnings.append(f"could not persist bus offset: {e}")

for tid in bus_closed_ids:
    if tid not in closed_now:
        closed_now.append(tid)
    # Ensure the snapshot reflects closed so the flag-diff loop above doesn't
    # re-report it next cycle once/if the flag file also becomes visible.
    entry = dict(new_snapshot_tasks.get(tid, prev_tasks.get(tid, {})))
    entry["has_flag"] = True
    entry["closed_via_bus"] = True
    new_snapshot_tasks[tid] = entry

# ── Control-plane questions (LEAD-ANCHOR-01) ────────────────────────────────
# Read via leadv2-ask.sh's <qid>.yaml schema: task_id, question, options[],
# asked_at, status, answer. TRUE control plane — visible from every worktree,
# unlike the per-task questions-async dir below.
cp_pending = []
if cp_questions_dir and os.path.isdir(cp_questions_dir):
    for qf in sorted(glob.glob(os.path.join(cp_questions_dir, "*.yaml"))):
        qid = os.path.basename(qf)
        if qid.endswith(".yaml"):
            qid = qid[: -len(".yaml")]
        try:
            import yaml
            with open(qf, encoding="utf-8") as fh:
                qd = yaml.safe_load(fh) or {}
        except Exception as e:
            # M2 fix (SUPERVISE-V2-01 fix-1): a malformed/unreadable
            # control-plane question file used to vanish silently -- a
            # blocked child could disappear from requires_founder with no
            # warning. Loud-fail philosophy (same as the active.yaml/
            # snapshot warnings above): record it, never drop it quietly.
            warnings.append(f"control-plane question {qf} unreadable/malformed ({e.__class__.__name__}: {e}) — skipped")
            continue
        if not isinstance(qd, dict) or qd.get("status") != "pending":
            continue
        question_text = qd.get("question", "")
        raw_options = qd.get("options") or []
        opt_labels = [
            o.get("label", "") if isinstance(o, dict) else str(o)
            for o in raw_options
        ]
        cp_pending.append({
            "qid": qid,
            "task_id": qd.get("task_id", "?"),
            "question": question_text,
            "summary_for_lead": qd.get("summary_for_lead") or question_text[:60],
            "options": opt_labels,
            # D-a dual-read tagging (SUPERVISE-V2-01 item 4): control-plane
            # store has no worktree-local sibling file — legacy_path is null.
            "store": "control-plane",
            "legacy_path": None,
        })

cp_by_task = {}
for q in cp_pending:
    cp_by_task.setdefault(q["task_id"], []).append(q)

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
                             "summary_for_lead": summary, "options": options,
                             # D-a dual-read tagging: this item came from the
                             # legacy worktree-local handoff store — the
                             # answer dispatcher needs legacy_path to wake
                             # the exact old poller (leadv2-reply.sh), never
                             # leadv2-answer.sh (that store is control-plane
                             # only). No new writer may create these files.
                             "store": "legacy-handoff", "legacy_path": pf})
    open_qs.extend(cp_by_task.get(tid, []))
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

    # LEAD-ANCHOR-01: "where" tells the founder which host to look at —
    # tmux window / terminal window / headless. Older active.yaml rows
    # (pre-dating this field) fall back on daemon_mode; a windowed-launch row
    # with neither field present defaults to "terminal" (the prior sole
    # windowed backend before tmux was added).
    where = s.get("where") or ("headless" if s.get("daemon_mode") else "terminal")

    # M3 fix (SUPERVISE-V2-01 fix-1): leadv2-active-registry.sh:register op
    # comment claims "reader-side infers protocol_version: 1 ... see
    # leadv2-supervise.sh" -- that inference did not actually exist anywhere
    # in this file. Implement it: a row registered before item 3 (D-d
    # registry-honesty fields) simply lacks the key -- absence means V1.
    protocol_version = s.get("protocol_version", 1)

    table.append({
        "task_id": tid, "phase": phase,
        "minutes_in_phase": minutes if minutes is not None else "?",
        "status": status, "waiting": is_waiting, "where": where,
        "protocol_version": protocol_version,
    })

table = table[:CAP_ROWS]

# Dangling control-plane questions — task_id not (or not yet) in active.yaml
# (e.g. registry lag). Still surface them; never silently drop a pending
# founder question just because the session table hasn't caught up.
for q in cp_pending:
    if q["task_id"] not in current:
        waiting_items.append(q)

# ── Delta / event-key bookkeeping ───────────────────────────────────────────
current_events = set()
for q in waiting_items:
    current_events.add(f"waiting:{q['task_id']}:{q['qid']}")
for st in stuck_items:
    current_events.add(f"stuck:{st['task_id']}:{'|'.join(st['reasons'])}")
for tid in closed_now:
    current_events.add(f"closed:{tid}")

new_events = current_events - prev_reported if delta_mode else current_events

# ── Persist snapshot — unwritable state is fatal (B1), not a warning ───────
# A snapshot write failure means the delta cursor / closed-event dedupe is
# silently broken for every future --since call; that must fail loud now,
# not degrade into repeated false "nothing changed" on a later poll.
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
    emit_fatal("state_write_error", f"could not write snapshot to {snapshot_path}: {e.__class__.__name__}: {e}")

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
        # DEFECT-2 (LEAD-ANCHOR-01): explicit top-level aliases so the
        # Monitor loop / skill contract can key off "questions"/"waiting"
        # by name instead of reaching into requires_founder[].
        "questions": out_waiting,
        "waiting": bool(out_waiting),
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

print(f"{'TASK-ID':<28} {'phase':<12} {'min':>4} {'status':<8} {'waiting?':<9} {'where'}")
for row in table:
    print(f"{row['task_id']:<28} {row['phase']:<12} {str(row['minutes_in_phase']):>4} "
          f"{row['status']:<8} {'yes' if row['waiting'] else 'no':<9} {row['where']}")

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
