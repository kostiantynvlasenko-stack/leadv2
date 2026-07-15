#!/usr/bin/env bash
# leadv2-fanout.sh — dispatch N independent /leadv2 sessions, each in its own
# terminal window (macOS) or headless background process, each in its own
# git worktree (worktree isolation is handled by Phase 0 of the spawned
# /leadv2 session itself — this script only SELECTS tasks and LAUNCHES
# sessions; it never creates worktrees).
#
# Usage:
#   leadv2-fanout.sh [--n N] [--filter STR] [--tasks ID1,ID2,ID3]
#                     [--dry-run] [--windowed] [--model NAME] [--force]
#
# Background (headless) is the DEFAULT launch mode (FIX-FANOUT-LAUNCH-V2-01).
# --headless is kept as a no-op back-compat flag; use --windowed to opt into
# the tmux/Terminal windowed path instead. Every child launch passes
# `claude --model NAME ...` (default NAME=sonnet) — that CLI flag is the only
# thing that changes a child session's own model; LEADV2_MAIN_MODEL is also
# exported for the plugin's subagent routing but does NOT change the child's
# session model by itself.
#
# Task LEAD-FANOUT-01. See docs/handoff/LEAD-ANCHOR-01/mission-fanout.md.
#
# Env overrides (test hook):
#   LEADV2_PROJECT_ROOT / CLAUDE_PROJECT_DIR / PROJECT_ROOT — repo root
#   LEADV2_FANOUT_CLAUDE_BIN — override the `claude` binary (tests stub this)
#
# Exit codes: 0 = ran (dry-run or real). 1 = hard failure (broken active.yaml,
# unsupported platform, bad args). Fail-CLOSED: any doubt about session
# accounting refuses to launch rather than risk two leads in one worktree.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${LEADV2_PROJECT_ROOT:-${CLAUDE_PROJECT_DIR:-${PROJECT_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}}}"

# LEAD-CONTROL-PLANE-01: source the repo-vendored copy (kept current by
# leadv2-plugin-sync.sh, patched locally for this task) rather than the
# shared-tree original — the vendored copy resolves active.yaml through
# scripts/leadv2-state-path.sh (control-plane root), the shared original
# still hardcodes docs/leadv2/active.yaml.
_REGISTRY_SH="${PROJECT_ROOT}/.claude/scripts/leadv2-active-registry.sh"
[[ -f "$_REGISTRY_SH" ]] || _REGISTRY_SH="${HOME}/.claude/leadv2-shared/scripts/leadv2-active-registry.sh"
# shellcheck source=/dev/null
source "$_REGISTRY_SH"

log() { printf -- '[fanout] %s\n' "$*" >&2; }
log_error() { log "ERROR: $*"; }

TASKS_YAML="${PROJECT_ROOT}/docs/tasks.yaml"
ACTIVE_YAML="$(_leadv2_yaml_file)"

# ── Arg parsing ─────────────────────────────────────────────────────────────
N=3
FILTER=""
EXPLICIT_TASKS=""
DRY_RUN=false
HEADLESS=true       # FIX-FANOUT-LAUNCH-V2-01 bug 2: background is now the default
FORCE=false
MODEL="sonnet"      # FIX-FANOUT-LAUNCH-V2-01 bug 1: default model for fanout children

while [[ $# -gt 0 ]]; do
  case "$1" in
    --n)        N="$2";              shift 2 ;;
    --filter)   FILTER="$2";         shift 2 ;;
    --tasks)    EXPLICIT_TASKS="$2"; shift 2 ;;
    --dry-run)  DRY_RUN=true;        shift   ;;
    --headless) HEADLESS=true;       shift   ;;  # back-compat no-op: background is already default
    --windowed) HEADLESS=false;      shift   ;;  # opt-in to tmux/Terminal windowed launch
    --model)    MODEL="$2";          shift 2 ;;
    --force)    FORCE=true;          shift   ;;
    -h|--help)
      printf -- 'Usage: leadv2-fanout.sh [--n N] [--filter STR] [--tasks ID1,ID2] [--dry-run] [--windowed] [--model NAME] [--force]\n'
      printf -- '  --windowed: launch each child in its own tmux window / Terminal tab instead\n'
      printf -- '              of headless background (background is the default).\n'
      printf -- '  --model NAME: model each child session runs on (default: sonnet). Passed as\n'
      printf -- '                `claude --model NAME ...` — the CLI flag is the only thing that\n'
      printf -- '                actually changes a child session'"'"'s model; LEADV2_MAIN_MODEL is\n'
      printf -- '                exported too for the plugin'"'"'s subagent routing but does NOT\n'
      printf -- '                change the child'"'"'s own session model.\n'
      printf -- '  --force: bypass active.yaml meta caps (hard_limit/standard_max/light_max/\n'
      printf -- '           heavy_strategic_solo). Never bypasses the same-task-already-active\n'
      printf -- '           check — that is the worktree-collision safety net, not a policy cap.\n'
      exit 0
      ;;
    *) log_error "unknown arg: $1"; exit 1 ;;
  esac
done

if ! [[ "$N" =~ ^[0-9]+$ ]]; then
  log_error "--n must be a non-negative integer, got '$N'"
  exit 1
fi

# ── Fail-CLOSED: active.yaml must exist and parse cleanly ─────────────────
if [[ ! -f "$ACTIVE_YAML" ]]; then
  log_error "active.yaml not found at $ACTIVE_YAML — refusing to fan out (fail-closed)"
  exit 1
fi
if ! python3 -c "import yaml,sys; yaml.safe_load(open(sys.argv[1]))" "$ACTIVE_YAML" >/dev/null 2>&1; then
  log_error "active.yaml at $ACTIVE_YAML is not valid YAML — refusing to fan out (fail-closed). Fix or restore it before retrying."
  exit 1
fi
if [[ ! -f "$TASKS_YAML" ]]; then
  log_error "tasks.yaml not found at $TASKS_YAML — refusing to fan out"
  exit 1
fi

# ── Selection + limit simulation (single python3 pass) ─────────────────────
# Caps are read from active.yaml meta ONLY, at runtime, every invocation —
# no overrides file, no script-side constant. Fix for LEAD-FANOUT-01 defect 1
# (2026-07-14): an earlier version also consulted
# .claude/leadv2-overrides/active-limits.yaml with overrides-wins precedence
# (mirroring leadv2-active-registry.sh::leadv2_active_check_limits). That file
# still had stale hard_limit:3/standard_max:2 committed, so it silently beat
# the founder's live meta:20/20/20 edit — a self-inflicted, unrequested
# feature (the mission never asked for overrides support). Removed outright;
# active.yaml meta is now the single source of truth for fanout's caps.
# self-spawn.sh::_task_class convention (context.class or class, default
# Standard) is mirrored for class. class is currently always Standard on the
# live tasks.yaml (no context/class column in the generated schema) —
# heavy_strategic_solo logic still runs so it activates the moment a Heavy
# task lands in tasks.yaml.
# lean: no depends_on / conflicts_with cross-check here — Phase 0 of the
# spawned session already enforces collision-check + lock; upgrade when
# fanout needs to pre-filter conflicting file footprints before launch.
# --force bypasses the CONFIGURED ceiling (hard_limit/standard_max/light_max/
# heavy_strategic_solo, all read live from active.yaml meta) — it does NOT
# bypass the same-task-already-active exclusion, which is the actual
# worktree-collision safety net this task exists to protect.
set +e
PLAN_TSV="$(python3 - "$TASKS_YAML" "$ACTIVE_YAML" "$N" "$FILTER" "$EXPLICIT_TASKS" "$FORCE" <<'PYEOF'
import sys, yaml

tasks_yaml, active_yaml, n_str, filt, explicit_csv, force_str = sys.argv[1:7]
n = int(n_str)
filt = filt.lower()
explicit_ids = [t for t in explicit_csv.split(",") if t] if explicit_csv else []
force = force_str.lower() == "true"

with open(active_yaml, encoding="utf-8") as fh:
    active = yaml.safe_load(fh) or {}
meta = active.get("meta") or {}
sessions = [s for s in (active.get("sessions") or []) if not s.get("stale")]
active_task_ids = {str(s.get("task_id")) for s in sessions}

# active.yaml meta is the ONLY source for caps — read fresh every run, no
# overrides file, no hardcoded ceiling. Fallback defaults below only apply
# when a key is truly absent from meta (fresh/incomplete active.yaml).
hard_limit           = int(meta.get("hard_limit", 20))
heavy_strategic_solo = bool(meta.get("heavy_strategic_solo", True))
light_max            = int(meta.get("light_max", 3))
standard_max         = int(meta.get("standard_max", 2))

total_active    = len(sessions)
light_count     = sum(1 for s in sessions if str(s.get("class", "")).lower() == "light")
standard_count  = sum(1 for s in sessions if str(s.get("class", "")).lower() in ("standard", "standard-light"))
heavy_active    = any(str(s.get("class", "")).lower() in ("heavy", "strategic") for s in sessions)

try:
    with open(tasks_yaml, encoding="utf-8") as fh:
        doc = yaml.safe_load(fh) or {}
except Exception as e:
    print(f"[fanout] ERROR: tasks.yaml failed to parse: {e}", file=sys.stderr)
    sys.exit(1)
tasks = doc.get("tasks") if isinstance(doc, dict) else doc
tasks = tasks or []

def task_class(t):
    return (t.get("context") or {}).get("class") or t.get("class") or "Standard"

# Fix for LEAD-FANOUT-01 defect 2 (2026-07-14): tasks.yaml has NO literal
# `title` column (verified: 0/211 rows on the live generated schema). Every
# row DOES carry `intent` (a human-written one-liner, e.g.
# "BACKLOG-TRUTH-01: no live backlog -- ..."), which is the closest thing to
# a title this schema has. Use it, truncated for display; if a task has
# neither `title` nor `intent`, say so explicitly per-row instead of
# silently printing the bare hash.
NO_TITLE_COLUMN = not any("title" in t for t in tasks)

def task_title(t):
    raw = t.get("title") or t.get("intent")
    if not raw:
        return "(no title/intent field on this task)"
    raw = " ".join(str(raw).split())  # collapse newlines/tabs/extra spaces
    return raw if len(raw) <= 80 else raw[:77] + "..."

by_id = {str(t.get("id")): t for t in tasks}

rows = []  # (decision, task_id, label, cls, priority, reason)

if explicit_ids:
    ordered = []
    for tid in explicit_ids:
        t = by_id.get(tid)
        if t is None:
            rows.append(("skip", tid, tid, "?", "", "not found in tasks.yaml"))
            continue
        ordered.append(t)
else:
    candidates = [
        t for t in tasks
        if str(t.get("status", "")) == "queued" and str(t.get("id")) not in active_task_ids
    ]
    if filt:
        candidates = [
            t for t in candidates
            if filt in str(t.get("id", "")).lower()
            or filt in str(t.get("group_key", "")).lower()
            or filt in str(t.get("intent", "")).lower()
        ]
    candidates.sort(
        key=lambda t: (-int(t.get("priority", 0) or 0),
                       -int(t.get("group_priority", 0) or 0),
                       str(t.get("id", "")))
    )
    ordered = candidates[:n]

heavy_claimed_this_run = False

for t in ordered:
    tid = str(t.get("id"))
    label = task_title(t)
    cls = task_class(t)
    cls_l = cls.lower()
    pri = t.get("priority", "")

    # Unconditional, never bypassed by --force: this IS the worktree-collision
    # safety net (two leads claiming the same task_id == two leads in the
    # same worktree, the exact failure this task exists to prevent).
    if tid in active_task_ids:
        rows.append(("skip", tid, label, cls, pri, "already in active.yaml (session running)"))
        continue

    if explicit_ids and str(t.get("status", "")) != "queued":
        rows.append(("skip", tid, label, cls, pri, f"not queued (status={t.get('status')})"))
        continue

    violation = None
    if total_active >= hard_limit:
        violation = f"hard_limit reached ({total_active}/{hard_limit})"
    elif cls_l in ("heavy", "strategic"):
        if heavy_strategic_solo and (total_active > 0 or heavy_active or heavy_claimed_this_run):
            violation = "heavy_strategic_solo: another session already active/claimed — heavy must run alone"
    elif heavy_active or heavy_claimed_this_run:
        violation = "heavy/strategic session active — solo rule blocks others"
    elif cls_l == "light" and light_count >= light_max:
        violation = f"light cap reached ({light_count}/{light_max})"
    elif cls_l in ("standard", "standard-light") and standard_count >= standard_max:
        violation = f"standard cap reached ({standard_count}/{standard_max})"

    if violation and not force:
        rows.append(("skip", tid, label, cls, pri, violation))
        continue

    reason = "selected" if not violation else f"FORCE OVERRIDE — would have hit: {violation}"
    rows.append(("launch", tid, label, cls, pri, reason))
    total_active += 1
    if cls_l in ("heavy", "strategic"):
        heavy_claimed_this_run = True
        heavy_active = True
    elif cls_l == "light":
        light_count += 1
    else:
        standard_count += 1

print(f"__NO_TITLE_COLUMN__\t{NO_TITLE_COLUMN}")
for r in rows:
    print("\t".join(str(x).replace("\t", " ").replace("\n", " ") for x in r))
PYEOF
)"
PY_RC=$?
if [[ $PY_RC -ne 0 ]]; then
  log_error "selection failed (rc=$PY_RC) — refusing to fan out"
  exit 1
fi

LAUNCH_COUNT=0
SKIP_COUNT=0
FORCED_ANY=false
NO_TITLE_COLUMN=false
declare -a LAUNCH_IDS=() LAUNCH_CLASSES=() LAUNCH_LABELS=()
declare -a REPORT_LINES=()

while IFS=$'\t' read -r f1 f2 f3 f4 f5 f6; do
  [[ -z "$f1" ]] && continue
  if [[ "$f1" == "__NO_TITLE_COLUMN__" ]]; then
    [[ "$f2" == "True" ]] && NO_TITLE_COLUMN=true
    continue
  fi
  decision="$f1" tid="$f2" label="$f3" cls="$f4" pri="$f5" reason="$f6"
  if [[ "$decision" == "launch" ]]; then
    LAUNCH_COUNT=$((LAUNCH_COUNT + 1))
    LAUNCH_IDS+=("$tid")
    LAUNCH_CLASSES+=("$cls")
    LAUNCH_LABELS+=("$label")
    REPORT_LINES+=("- LAUNCH \`${label}\` (\`${tid}\`) — class=${cls}, priority=${pri} — ${reason}")
    [[ "$reason" == *"FORCE OVERRIDE"* ]] && FORCED_ANY=true
  else
    SKIP_COUNT=$((SKIP_COUNT + 1))
    REPORT_LINES+=("- skip \`${label}\` (\`${tid}\`, class=${cls}) — ${reason}")
  fi
done <<< "$PLAN_TSV"

log "plan: ${LAUNCH_COUNT} to launch, ${SKIP_COUNT} skipped"
for line in "${REPORT_LINES[@]:-}"; do
  [[ -n "$line" ]] && log "$line"
done

if [[ "$LAUNCH_COUNT" -eq 0 ]]; then
  log "nothing to launch — see reasons above"
fi

# ── Report artifact ─────────────────────────────────────────────────────────
TS_ISO="$(date -u +"%Y%m%dT%H%M%SZ")"
REPORT_FILE="${PROJECT_ROOT}/docs/leadv2/fanout-${TS_ISO}.md"
mkdir -p "${PROJECT_ROOT}/docs/leadv2"

{
  printf -- '# fanout %s\n\n' "$TS_ISO"
  printf -- 'mode: %s%s\n\n' \
    "$([[ "$DRY_RUN" == "true" ]] && echo "DRY-RUN — nothing launched" || echo "LIVE")" \
    "$([[ "$FORCE" == "true" ]] && echo " (--force)" || echo "")"
  if [[ "$FORCED_ANY" == "true" ]]; then
    printf -- '## ⚠️ FORCE OVERRIDE ACTIVE ⚠️\n\n'
    printf -- 'At least one launch below exceeded the CONFIGURED ceiling in\n'
    printf -- 'docs/leadv2/active.yaml meta (hard_limit / standard_max / light_max /\n'
    printf -- 'heavy_strategic_solo). --force bypassed the policy cap — it never bypasses\n'
    printf -- 'the same-task-already-active exclusion. Lines tagged "FORCE OVERRIDE" below\n'
    printf -- 'name exactly which cap was exceeded and by how much.\n\n'
  fi
  if [[ "$NO_TITLE_COLUMN" == "true" ]]; then
    printf -- '## Task labels\n\n'
    printf -- 'docs/tasks.yaml has no `title` column. The label shown before each id below\n'
    printf -- 'is the `intent` field (truncated to 80 chars) — the closest thing this schema\n'
    printf -- 'has to a human title. Rows with neither `title` nor `intent` show that\n'
    printf -- 'explicitly instead of a bare hash.\n\n'
  fi
  printf -- '## Plan\n\n'
  for line in "${REPORT_LINES[@]:-}"; do
    [[ -n "$line" ]] && printf -- '%s\n' "$line"
  done
  printf -- '\n## Merge serialization (not this script'"'"'s job)\n\n'
  printf -- 'Fanning out %d session(s) means up to %d parallel /leadv2 leads may reach\n' "$LAUNCH_COUNT" "$LAUNCH_COUNT"
  printf -- '`main` around the same time. This script does NOT assume exclusive main\n'
  printf -- 'access and does NOT do any merge/rebase coordination itself — merges are\n'
  printf -- 'serialized by a separate mechanism (docs/leadv2/merge-queue.jsonl, owned by\n'
  printf -- 'another agent). If that queue is not live yet, do not fan out into `main`\n'
  printf -- 'writes without a human watching.\n'
  printf -- '\n## Quota warning\n\n'
  printf -- '%d slot(s) requested to launch this run. Flat subscription, but each parallel\n' "$LAUNCH_COUNT"
  printf -- '/leadv2 Opus lead still burns real weekly quota — do not fan out more than you\n'
  printf -- 'are prepared to actively watch. hard_limit=%s.\n' "$(python3 -c "import yaml; print((yaml.safe_load(open('${ACTIVE_YAML}')) or {}).get('meta',{}).get('hard_limit','?'))" 2>/dev/null || echo "?")"
} > "$REPORT_FILE"

log "report written: $REPORT_FILE"

if [[ "$DRY_RUN" == "true" ]]; then
  log "--dry-run: exiting without launching anything"
  exit 0
fi

if [[ "$LAUNCH_COUNT" -eq 0 ]]; then
  exit 0
fi

CLAUDE_BIN="${LEADV2_FANOUT_CLAUDE_BIN:-claude}"

# _fanout_register_session — atomic write-temp+rename under flock on the
# SAME lockfile leadv2-active-registry.sh uses, so up to N fanout launches
# (and any concurrently-running gate1 self-registrations) serialize safely.
# Writes the exact field set the supervisor/session-bus need: task_id,
# worktree, branch, pid, window_title, started_at — plus the existing schema
# fields (class/phase/daemon_mode/etc.) so old readers keep working.
# Reimplemented locally (not by editing leadv2-active-registry.sh, which is
# out of this task's file scope) because its register() op has no
# window_title parameter slot.
_fanout_register_session() {
  local tid="$1" cls="$2" pid_val="$3" window_title="$4" daemon_mode="$5"
  local branch ts_now yaml_file lockfile session_id
  branch="$(git -C "$PROJECT_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || printf -- 'unknown')"
  ts_now="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  yaml_file="$(_leadv2_yaml_file)"
  lockfile="$(_leadv2_yaml_lockfile)"
  session_id="f-$(date -u +%Y%m%dT%H%M%SZ)-${pid_val}-$$"

  python3 - "$lockfile" "$yaml_file" "$session_id" "$tid" "$PROJECT_ROOT" \
    "$branch" "$ts_now" "$cls" "$pid_val" "$window_title" "$daemon_mode" \
    "docs/leadv2/tasks/${tid}/pulse.md" <<'PYEOF' \
    || log "WARN: could not register ${tid} in active.yaml — session is running unregistered"
import sys, os, fcntl, tempfile, yaml

(lockfile, yaml_path, session_id, task_id, worktree, branch, started_at,
 cls, pid_str, window_title, daemon_mode_str, pulse_log) = sys.argv[1:13]

pid_val = None if pid_str in ("null", "", "None") else int(pid_str)
daemon_mode = daemon_mode_str.lower() in ("1", "true", "yes")

def pid_alive(p):
    try:
        os.kill(int(p), 0); return True
    except (TypeError, ValueError, ProcessLookupError, PermissionError):
        return False

os.makedirs(os.path.dirname(lockfile), exist_ok=True)
fd = open(lockfile, "a+")
try:
    fcntl.flock(fd, fcntl.LOCK_EX)
    os.makedirs(os.path.dirname(yaml_path), exist_ok=True)
    if os.path.exists(yaml_path):
        with open(yaml_path, encoding="utf-8") as fh:
            data = yaml.safe_load(fh) or {}
    else:
        data = {"meta": {"schema_version": 2, "hard_limit": 20,
                          "heavy_strategic_solo": True, "light_max": 3,
                          "standard_max": 2, "rendered_at": ""},
                "sessions": []}
    data.setdefault("meta", {})
    sessions = data.setdefault("sessions", [])

    existing = next((s for s in sessions if s.get("task_id") == task_id), None)
    if existing and pid_alive(existing.get("pid")):
        print(f"[fanout] {task_id} already has a live registered session — not overwriting", file=sys.stderr)
        sys.exit(0)
    if existing:
        sessions.remove(existing)

    sessions.append({
        "session_id": session_id, "task_id": task_id, "worktree": worktree,
        "branch": branch, "started_at": started_at, "phase": "spawning",
        "class": cls, "pulse_log": pulse_log, "pid": pid_val,
        "pid_birth": None, "parent_session_id": None,
        "daemon_mode": daemon_mode, "last_pulse_at": started_at,
        "stale": False, "window_title": window_title,
        "note": f"window_title={window_title}",
    })

    d = os.path.dirname(yaml_path)
    tfd, tpath = tempfile.mkstemp(dir=d, suffix=".tmp")
    try:
        with os.fdopen(tfd, "w", encoding="utf-8") as tf:
            yaml.dump(data, tf, default_flow_style=False, sort_keys=False)
        os.replace(tpath, yaml_path)
    except Exception:
        os.unlink(tpath)
        raise
finally:
    fcntl.flock(fd, fcntl.LOCK_UN)
    fd.close()
PYEOF
}

launch_headless() {
  local tid="$1" cls="$2"
  local task_dir="${PROJECT_ROOT}/docs/handoff/${tid}"
  mkdir -p "$task_dir"
  local logf="${task_dir}/fanout.log"
  local pid

  # exec inside the subshell so $! (of the outer &) IS the detached-process
  # pid, not an extra unexeced subshell layer — matches
  # leadv2-session-spawner.sh's own setsid-nohup convention as closely as bash
  # allows with an explicit cd. macOS has no setsid (FIX-FANOUT-MACOS-LAUNCH-01):
  # fall back to a plain backgrounded nohup + disown, which still detaches
  # from the controlling terminal and keeps stdin/stdout/stderr identical on
  # both branches.
  # FIX-FANOUT-MODEL-ROUTING-01 / FIX-FANOUT-LAUNCH-V2-01 bug 1: fanout
  # children run their lead on $MODEL (default sonnet), not the repo's normal
  # /leadv2 default (Opus) — the supervising (non-fanout) lead keeps Opus
  # judgment; children are cheaper, parallel workers. LEADV2_MAIN_MODEL alone
  # does NOT change the child claude session's own model — only the
  # `--model` CLI flag does that; LEADV2_MAIN_MODEL is exported in addition
  # because the plugin reads it for subagent routing inside the session. Both
  # the export and the CLI flag are scoped to the launched subshell/process
  # only — they never touch the parent fanout invoker's environment, so a
  # normal (non-fanout) /leadv2 session started separately is unaffected and
  # still defaults to Opus.
  # FIX-FANOUT-LAUNCH-V2-01 bug 2: `-p` is a single headless turn that exits
  # once it returns — without LEADV2_DAEMON=1 the child dies after one turn
  # instead of driving the full /leadv2 pipeline to completion.
  # LEADV2_DAEMON=1 pairs with the pipeline's own /goal self-drive loop
  # (read inside the running session, same convention already used by the
  # tmux windowed path below) to keep re-invoking itself until the task is
  # actually done, not just after the first response.
  if command -v setsid >/dev/null 2>&1; then
    ( cd "$PROJECT_ROOT" && export LEADV2_DAEMON=1 LEADV2_ASYNC_QUESTIONS=1 LEADV2_MAIN_MODEL="$MODEL" && exec setsid nohup "$CLAUDE_BIN" --model "$MODEL" -p "/leadv2 ${tid}" </dev/null >>"$logf" 2>&1 ) &
  else
    ( cd "$PROJECT_ROOT" && export LEADV2_DAEMON=1 LEADV2_ASYNC_QUESTIONS=1 LEADV2_MAIN_MODEL="$MODEL" && exec nohup "$CLAUDE_BIN" --model "$MODEL" -p "/leadv2 ${tid}" </dev/null >>"$logf" 2>&1 ) &
    disown
  fi
  pid=$!
  log "headless launch: task=${tid} pid=${pid} model=${MODEL} log=${logf}"

  _fanout_register_session "$tid" "$cls" "$pid" "leadv2: ${tid}" "true"
}

# _applescript_escape — escape a string for interpolation inside an
# AppleScript double-quoted string literal. Order matters: backslashes first,
# then quotes, else the quote-escaping backslashes get double-escaped.
_applescript_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "$s"
}

launch_windowed() {
  local tid="$1" cls="$2"
  local title="leadv2: ${tid}"

  # Preferred path (FIX-FANOUT-MACOS-LAUNCH-01): tmux is tty-preserving and
  # has no AppleScript-string-escaping hazard. Use the current tmux session
  # if we're already inside one, else the dedicated "leadv2" session if it
  # exists. Only fall back to osascript when neither is available.
  local tmux_target=""
  if command -v tmux >/dev/null 2>&1; then
    if [[ -n "${TMUX:-}" ]]; then
      tmux_target="$(tmux display-message -p '#S' 2>/dev/null || true)"
    elif tmux has-session -t leadv2 2>/dev/null; then
      tmux_target="leadv2"
    fi
  fi

  if [[ -n "$tmux_target" ]]; then
    local window_name="leadv2-${tid}"
    local tmux_cmd
    # FIX-FANOUT-MODEL-ROUTING-01 / FIX-FANOUT-LAUNCH-V2-01 bug 1: fanout
    # children lead on $MODEL (see launch_headless comment above), passed via
    # --model — scoped to this tmux window's shell only.
    printf -v tmux_cmd \
      'export LEADV2_DAEMON=1 LEADV2_ASYNC_QUESTIONS=1 LEADV2_MAIN_MODEL=%q LEADV2_PROJECT_ROOT=%q CLAUDE_PROJECT_DIR=%q LEADV2_TASK_ID=%q; cd %q && exec %q --model %q %q' \
      "$MODEL" "$PROJECT_ROOT" "$PROJECT_ROOT" "$tid" "$PROJECT_ROOT" "$CLAUDE_BIN" "$MODEL" "/leadv2 ${tid}"
    # Do NOT pipe claude stdout (`| tee`) — breaks the interactive TTY and
    # hangs claude. Logging, if ever needed, goes through `tmux pipe-pane`.
    # FIX-FANOUT-LAUNCH-V2-01 bug 4: never target/hardcode a window index.
    # `-t "${tmux_target}:"` (trailing colon, session only, no index) lets
    # tmux assign the next free index itself, and `-P -F '#{window_id}'`
    # captures the actual unique window id tmux created for THIS window so
    # send-keys always targets a window that exists — a name-based target
    # (`session:window_name`) can silently diverge if tmux disambiguates a
    # duplicate window name, which is what produced "create window failed:
    # index 1 in use" followed by "can't find window".
    local window_id
    window_id="$(tmux new-window -P -F '#{window_id}' -t "${tmux_target}:" -n "$window_name" -c "$PROJECT_ROOT")"
    tmux send-keys -t "$window_id" "$tmux_cmd" C-m
    log "tmux launch: task=${tid} session=${tmux_target} window=${window_name} window_id=${window_id} model=${MODEL}"

    _fanout_register_session "$tid" "$cls" "null" "$title" "false"
    return 0
  fi

  if [[ "$(uname -s)" != "Darwin" ]]; then
    log_error "windowed launch requires macOS (osascript) or a running tmux session. Use --headless on this platform."
    exit 1
  fi
  if ! command -v osascript >/dev/null 2>&1; then
    log_error "osascript not found — cannot open terminal windows. Use --headless."
    exit 1
  fi

  local cmd
  # FIX-FANOUT-LAUNCH-V2-01 bug 3: this fallback used to export ONLY
  # LEADV2_MAIN_MODEL — children stalled on interactive AskUserQuestion
  # (LEADV2_ASYNC_QUESTIONS missing) and silently ran on Opus (--model
  # missing, LEADV2_MAIN_MODEL alone does not change the session model).
  # Export the SAME full set as the tmux path above and pass --model, scoped
  # to this Terminal/iTerm2 shell only.
  printf -v cmd \
    'export LEADV2_DAEMON=1 LEADV2_ASYNC_QUESTIONS=1 LEADV2_MAIN_MODEL=%q LEADV2_PROJECT_ROOT=%q CLAUDE_PROJECT_DIR=%q LEADV2_TASK_ID=%q && cd %q && %q --model %q %q' \
    "$MODEL" "$PROJECT_ROOT" "$PROJECT_ROOT" "$tid" "$PROJECT_ROOT" "$CLAUDE_BIN" "$MODEL" "/leadv2 ${tid}"
  # Escape for the AppleScript string-literal context (Bug 2,
  # FIX-FANOUT-MACOS-LAUNCH-01): shell %q backslash-escaping is not valid
  # inside an AppleScript "..." literal and previously errored with -2741.
  local as_cmd as_title
  as_cmd="$(_applescript_escape "$cmd")"
  as_title="$(_applescript_escape "$title")"

  if pgrep -x iTerm2 >/dev/null 2>&1; then
    osascript <<OSA
tell application "iTerm2"
  set newWindow to (create window with default profile)
  tell current session of newWindow
    set name to "${as_title}"
    write text "${as_cmd}"
  end tell
end tell
OSA
  else
    osascript <<OSA
tell application "Terminal"
  set newTab to do script "${as_cmd}"
  set custom title of front window to "${as_title}"
  activate
end tell
OSA
  fi
  log "windowed launch: task=${tid} title='${title}'"

  # lean: pid unknown — osascript hands the shell command to Terminal/iTerm2
  # asynchronously and doesn't hand back the spawned `claude` process pid
  # without a much heavier AppleScript round-trip. Registered pid=null here;
  # Phase 0's own gate1 registration (durable-pid walk) fills it in shortly
  # after the session starts. upgrade when a reliable pid handback is needed.
  _fanout_register_session "$tid" "$cls" "null" "$title" "false"
}

for i in "${!LAUNCH_IDS[@]}"; do
  tid="${LAUNCH_IDS[$i]}"
  cls="${LAUNCH_CLASSES[$i]}"
  if [[ "$HEADLESS" == "true" ]]; then
    launch_headless "$tid" "$cls"
  else
    launch_windowed "$tid" "$cls"
  fi
done

exit 0
