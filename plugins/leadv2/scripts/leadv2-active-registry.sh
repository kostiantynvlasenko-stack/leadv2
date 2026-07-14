#!/usr/bin/env bash
# leadv2-active-registry.sh — CRUD operations on docs/leadv2/active.yaml
# Source this file; do not exec directly.
#
# Functions:
#   leadv2_active_register <task_id> <class> <worktree> <branch> <daemon_mode>
#   leadv2_active_unregister <task_id>
#   leadv2_active_update_phase <task_id> <phase>
#   leadv2_active_update_pulse <task_id>
#   leadv2_active_render_index
#   leadv2_active_list
#   leadv2_active_check_limits <class>
#
# All YAML writes use Python flock + atomic temp-file (same pattern as
# _leadv2_active_py_lock in leadv2-helpers.sh).
#
# Exit codes for leadv2_active_check_limits:
#   0 — OK
#   1 — hard_limit_reached
#   2 — heavy_conflict
#   3 — budget_refused

set -euo pipefail

# ── Paths ──────────────────────────────────────────────────────────────────
# Resolution order: explicit override → CLAUDE_PROJECT_DIR (v2.1.144+) → PROJECT_ROOT → cwd
LEADV2_PROJECT_ROOT="${LEADV2_PROJECT_ROOT:-${CLAUDE_PROJECT_DIR:-${PROJECT_ROOT:-$(pwd)}}}"

# LEAD-CONTROL-PLANE-01: active.yaml is a cross-worktree registry — every
# /leadv2 session runs in its own `git worktree add` checkout, so a
# repo-relative docs/leadv2/active.yaml gave each session a PRIVATE copy
# (registry saw only itself). Resolved via scripts/leadv2-state-path.sh,
# which uses `git rev-parse --git-common-dir` — identical from every
# worktree of the same repo.
_leadv2_state_path_sh() {
  printf -- '%s/scripts/leadv2-state-path.sh' "${LEADV2_PROJECT_ROOT}"
}

_leadv2_yaml_file() {
  local resolver
  resolver="$(_leadv2_state_path_sh)"
  if [[ -x "$resolver" ]]; then
    PROJECT_ROOT="${LEADV2_PROJECT_ROOT}" "$resolver" active.yaml
  else
    printf -- '%s/docs/leadv2/active.yaml' "${LEADV2_PROJECT_ROOT}"
  fi
}

_leadv2_yaml_lockfile() {
  local resolver
  resolver="$(_leadv2_state_path_sh)"
  if [[ -x "$resolver" ]]; then
    PROJECT_ROOT="${LEADV2_PROJECT_ROOT}" "$resolver" active.yaml.lock
  else
    printf -- '%s/docs/leadv2/active.yaml.lock' "${LEADV2_PROJECT_ROOT}"
  fi
}

_leadv2_state_md() {
  printf -- '%s/docs/LEAD_V2_STATE.md' "${LEADV2_PROJECT_ROOT}"
}

# ── Core Python flock + atomic-write helper ───────────────────────────────
# _leadv2_yaml_py_lock <lockfile> <yaml_file> <op> [args...]
#
# ops: register   <session_id> <task_id> <worktree> <branch> <started_at>
#                 <phase> <class> <pid> <pid_birth> <parent_session_id>
#                 <daemon_mode> <last_pulse_at> <pulse_log>
#      unregister <task_id>
#      update_phase <task_id> <phase>
#      update_pulse <task_id> <ts>
#      mark_stale  <task_id>
#      read        → writes YAML to stdout (no mutation)
#
_leadv2_yaml_py_lock() {
  python3 - "$@" <<'PYEOF'
import sys, os, fcntl, tempfile
try:
    import yaml
except ImportError:
    print("[registry] PyYAML not found; install pyyaml", file=sys.stderr)
    sys.exit(1)

lockfile_path = sys.argv[1]
yaml_path     = sys.argv[2]
op            = sys.argv[3]
args          = sys.argv[4:]

INITIAL = {
    "meta": {
        "schema_version": 2,
        "rendered_at": "",
        "hard_limit": 3,
        "heavy_strategic_solo": True,
        "light_max": 3,
        "standard_max": 2,
    },
    "sessions": [],
}

def _pid_alive(pid_val) -> bool:
    try:
        pid = int(pid_val)
        os.kill(pid, 0)
        return True
    except (TypeError, ValueError, ProcessLookupError, PermissionError):
        return False

os.makedirs(os.path.dirname(lockfile_path), exist_ok=True)
lock_fd = open(lockfile_path, "a+")
try:
    fcntl.flock(lock_fd, fcntl.LOCK_EX)

    # Ensure yaml file exists
    os.makedirs(os.path.dirname(yaml_path), exist_ok=True)
    if not os.path.exists(yaml_path):
        with open(yaml_path, "w", encoding="utf-8") as fh:
            yaml.dump(INITIAL, fh, default_flow_style=False, sort_keys=False)

    with open(yaml_path, encoding="utf-8") as fh:
        data = yaml.safe_load(fh) or {}

    if "meta" not in data:
        data["meta"] = INITIAL["meta"].copy()
    if "sessions" not in data or data["sessions"] is None:
        data["sessions"] = []

    sessions = data["sessions"]

    if op == "read":
        yaml.dump(data, sys.stdout, default_flow_style=False, sort_keys=False)
        sys.exit(0)

    elif op == "register":
        (session_id, task_id, worktree, branch, started_at,
         phase, cls, pid, pid_birth, parent_session_id,
         daemon_mode, last_pulse_at, pulse_log) = args

        pid_int = int(pid) if pid not in ("null", "", "None") else None
        daemon_bool = daemon_mode.lower() in ("1", "true", "yes")

        # Replace stale row for same task_id if PID is dead
        existing = next((s for s in sessions if s.get("task_id") == task_id), None)
        if existing:
            if _pid_alive(existing.get("pid")):
                # Active row already present — idempotent
                sys.exit(0)
            else:
                sessions.remove(existing)

        sessions.append({
            "session_id": session_id,
            "task_id": task_id,
            "worktree": worktree,
            "branch": branch,
            "started_at": started_at,
            "phase": phase,
            "class": cls,
            "pulse_log": pulse_log,
            "pid": pid_int,
            "pid_birth": pid_birth,
            "parent_session_id": None if parent_session_id in ("null", "", "None") else parent_session_id,
            "daemon_mode": daemon_bool,
            "last_pulse_at": last_pulse_at,
            "stale": False,
            "note": "",
        })
        # Return session_id on stdout
        print(session_id)

    elif op == "unregister":
        task_id = args[0]
        data["sessions"] = [s for s in sessions if s.get("task_id") != task_id]

    elif op == "update_phase":
        task_id, new_phase = args
        for s in sessions:
            if s.get("task_id") == task_id:
                s["phase"] = new_phase
                break

    elif op == "update_pulse":
        task_id, ts = args
        for s in sessions:
            if s.get("task_id") == task_id:
                s["last_pulse_at"] = ts
                break

    elif op == "update_pid":
        task_id, pid_str = args
        pid_int = int(pid_str) if pid_str not in ("null", "", "None") else None
        for s in sessions:
            if s.get("task_id") == task_id:
                s["pid"] = pid_int
                break

    elif op == "mark_stale":
        task_id = args[0]
        for s in sessions:
            if s.get("task_id") == task_id:
                s["stale"] = True
                break

    elif op == "set_rendered_at":
        ts_val = args[0]
        if "meta" not in data:
            data["meta"] = {}
        data["meta"]["rendered_at"] = ts_val

    else:
        print(f"[registry] unknown op: {op}", file=sys.stderr)
        sys.exit(1)

    # Atomic write: temp + rename
    dir_ = os.path.dirname(yaml_path)
    tmp_fd, tmp_path = tempfile.mkstemp(dir=dir_, suffix=".tmp")
    try:
        with os.fdopen(tmp_fd, "w", encoding="utf-8") as tf:
            yaml.dump(data, tf, default_flow_style=False, sort_keys=False)
        os.replace(tmp_path, yaml_path)
    except Exception:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise

finally:
    fcntl.flock(lock_fd, fcntl.LOCK_UN)
    lock_fd.close()
PYEOF
}

# ── Public functions ───────────────────────────────────────────────────────

# _lv2_durable_pid — walk $PPID chain to find the durable 'claude' process PID.
# Returns the claude process PID on stdout, or PPID as fallback.
# Rationale: gate1-prompt.sh runs as a short-lived bash subprocess; stale-pid-sweep
# drops any session whose pid is dead at next SessionStart. Registering with the
# durable claude process PID keeps the session alive until the real session ends.
_lv2_durable_pid() {
  python3 - "$PPID" <<'PYEOF' || printf -- '%s' "$PPID"
import sys, subprocess
from typing import Optional

def ppid_of(pid: int) -> Optional[int]:
    try:
        r = subprocess.run(
            ['ps', '-o', 'ppid=', '-p', str(pid)],
            capture_output=True, text=True, timeout=2
        )
        s = r.stdout.strip()
        return int(s) if s else None
    except Exception:
        return None

def comm_of(pid: int) -> str:
    try:
        r = subprocess.run(
            ['ps', '-o', 'comm=', '-p', str(pid)],
            capture_output=True, text=True, timeout=2
        )
        return r.stdout.strip().split('/')[-1].lower()
    except Exception:
        return ''

start = int(sys.argv[1])
pid = start
visited: set = set()
while pid and pid > 1 and pid not in visited:
    visited.add(pid)
    if 'claude' in comm_of(pid):
        print(pid, end='')
        sys.exit(0)
    nxt = ppid_of(pid)
    if nxt is None or nxt == pid or nxt == 1:
        break
    pid = nxt
# fallback: start is PPID of the bash script (caller's shell), reasonably durable
print(start, end='', file=sys.stdout)
print(f'[lv2_durable_pid] WARNING: no claude process found in PPID chain; using fallback pid={start}', file=sys.stderr)
PYEOF
}

# leadv2_active_register <task_id> <class> <worktree> <branch> <daemon_mode>
# Writes a new session row to active.yaml.
# Returns (stdout): session_id in format s-YYYYMMDDTHHMMSSZ-PID
leadv2_active_register() {
  local task_id="${1:?task_id required}"
  local cls="${2:-Standard}"
  local worktree="${3:-$(pwd)}"
  local branch="${4:-}"
  local daemon_mode="${5:-false}"

  if [[ -z "$branch" ]]; then
    branch="$(git -C "$worktree" rev-parse --abbrev-ref HEAD 2>/dev/null || printf -- 'unknown')"
  fi

  # Use the durable claude process PID so stale-pid-sweep doesn't drop the row
  # at the next SessionStart when the gate1 bash subprocess has already exited.
  local durable_pid
  durable_pid="$(_lv2_durable_pid)"

  local session_id ts pid_birth pulse_log parent_sid
  ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  # Tiebreaker: append $$ (gate1 subprocess pid, unique per invocation) after durable_pid.
  # durable_pid is the liveness key; $$ ensures uniqueness when two tasks register same second.
  session_id="s-$(date -u +%Y%m%dT%H%M%SZ)-${durable_pid}-$$"
  pid_birth="$(ps -o lstart= -p "${durable_pid}" 2>/dev/null | tr -s ' ' || printf -- 'unknown')"
  pulse_log="docs/leadv2/tasks/${task_id}/pulse.md"
  parent_sid="${LEADV2_PARENT_SESSION_ID:-null}"

  local yaml_file lockfile
  yaml_file="$(_leadv2_yaml_file)"
  lockfile="$(_leadv2_yaml_lockfile)"

  _leadv2_yaml_py_lock \
    "$lockfile" "$yaml_file" register \
    "$session_id" "$task_id" "$worktree" "$branch" "$ts" \
    "intake" "$cls" "${durable_pid}" "$pid_birth" "$parent_sid" \
    "$daemon_mode" "$ts" "$pulse_log"

  # Auto-refresh LEAD_V2_STATE.md on every register — non-fatal to register itself
  _render_log="/tmp/lv2-render-$(date +%s).log"
  leadv2_active_render_index 2>"$_render_log" || {
    printf -- '[registry] WARN: render_index failed after register:\n' >&2
    cat "$_render_log" >&2
  }
}

# leadv2_active_unregister <task_id>
leadv2_active_unregister() {
  local task_id="${1:?task_id required}"
  local yaml_file lockfile
  yaml_file="$(_leadv2_yaml_file)"
  lockfile="$(_leadv2_yaml_lockfile)"
  [[ -f "$yaml_file" ]] || return 0
  _leadv2_yaml_py_lock "$lockfile" "$yaml_file" unregister "$task_id"

  # Auto-refresh LEAD_V2_STATE.md on every unregister — non-fatal to unregister itself
  _render_log="/tmp/lv2-render-$(date +%s).log"
  leadv2_active_render_index 2>"$_render_log" || {
    printf -- '[registry] WARN: render_index failed after unregister:\n' >&2
    cat "$_render_log" >&2
  }
}

# leadv2_active_update_phase <task_id> <phase>
leadv2_active_update_phase() {
  local task_id="${1:?task_id required}"
  local phase="${2:?phase required}"
  local yaml_file lockfile
  yaml_file="$(_leadv2_yaml_file)"
  lockfile="$(_leadv2_yaml_lockfile)"
  [[ -f "$yaml_file" ]] || return 0
  _leadv2_yaml_py_lock "$lockfile" "$yaml_file" update_phase "$task_id" "$phase"
}

# leadv2_active_update_pulse <task_id>
leadv2_active_update_pulse() {
  local task_id="${1:?task_id required}"
  local ts
  ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  local yaml_file lockfile
  yaml_file="$(_leadv2_yaml_file)"
  lockfile="$(_leadv2_yaml_lockfile)"
  [[ -f "$yaml_file" ]] || return 0
  _leadv2_yaml_py_lock "$lockfile" "$yaml_file" update_pulse "$task_id" "$ts"
}

# leadv2_active_render_index
# Regenerates docs/LEAD_V2_STATE.md as markdown index from active.yaml.
leadv2_active_render_index() {
  local yaml_file state_md ts
  yaml_file="$(_leadv2_yaml_file)"
  state_md="$(_leadv2_state_md)"
  ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

  mkdir -p "$(dirname "$state_md")"

  python3 - "$yaml_file" "$state_md" "$ts" <<'PYEOF'
import sys, os
try:
    import yaml
except ImportError:
    print("[registry] PyYAML not found", file=sys.stderr)
    sys.exit(1)

yaml_file, state_md, ts = sys.argv[1], sys.argv[2], sys.argv[3]

if not os.path.exists(yaml_file):
    sessions = []
    hard_limit = 2
else:
    with open(yaml_file, encoding="utf-8") as fh:
        data = yaml.safe_load(fh) or {}
    sessions = data.get("sessions") or []
    hard_limit = (data.get("meta") or {}).get("hard_limit", 2)

# Preserve "## Recent history" block from prior render so it survives regeneration.
# Block ends at next H2 heading or EOF. Lead/founder edits this section by hand.
# Uses re.MULTILINE so the match is anchored to line-start, not inside HTML comments.
import re
history_block = ""
if os.path.exists(state_md):
    with open(state_md, encoding="utf-8") as fh:
        prior = fh.read()
    m = re.search(r'^## Recent history', prior, re.MULTILINE)
    if m:
        tail = prior[m.start():]
        next_h2 = tail.find("\n## ", 1)
        history_block = tail if next_h2 == -1 else tail[:next_h2]
        history_block = history_block.rstrip() + "\n"

lines = [
    "<!-- DO NOT EDIT TABLE — regenerated from docs/leadv2/active.yaml by leadv2_active_render_index -->",
    "<!-- Per-task state: docs/leadv2/tasks/<task_id>/STATE.md -->",
    "<!-- '## Recent history' below is preserved across renders; edit by hand. -->",
    "",
    "# /leadv2 Active Sessions",
    "",
    f"Last updated: {ts}",
    "",
    "| task_id | phase | class | started_at | daemon |",
    "|---|---|---|---|---|",
]

for s in sessions:
    tid     = s.get("task_id", "?")
    phase   = s.get("phase", "?")
    cls     = s.get("class", "?")
    started = (s.get("started_at") or "")[:16]
    daemon  = "yes" if s.get("daemon_mode") else "no"
    lines.append(f"| {tid} | {phase} | {cls} | {started} | {daemon} |")

lines.append("")
lines.append(f"Sessions: {len(sessions)} / {hard_limit} max")
lines.append("")

out = "\n".join(lines) + "\n"
if history_block:
    out += "\n" + history_block

with open(state_md, "w", encoding="utf-8") as fh:
    fh.write(out)
print(f"[registry] rendered {state_md} ({len(sessions)} sessions, history_preserved={bool(history_block)})")
PYEOF

  # Write rendered_at back to active.yaml under the same lock discipline (non-fatal)
  local lockfile
  lockfile="$(_leadv2_yaml_lockfile)"
  if [[ -f "$yaml_file" ]]; then
    _leadv2_yaml_py_lock "$lockfile" "$yaml_file" set_rendered_at "$ts" \
      || printf -- '[registry] WARN: rendered_at write to active.yaml failed (non-fatal)\n' >&2
  fi
}

# leadv2_active_list
# Prints active.yaml sessions as a human-readable table to stdout.
leadv2_active_list() {
  local yaml_file
  yaml_file="$(_leadv2_yaml_file)"

  if [[ ! -f "$yaml_file" ]]; then
    echo "[registry] no active.yaml found at $yaml_file"
    return 0
  fi

  python3 - "$yaml_file" <<'PYEOF'
import sys
try:
    import yaml
except ImportError:
    print("[registry] PyYAML not found", file=sys.stderr)
    sys.exit(1)

with open(sys.argv[1], encoding="utf-8") as fh:
    data = yaml.safe_load(fh) or {}
sessions = data.get("sessions") or []
meta = data.get("meta") or {}
print(f"Active sessions ({len(sessions)} / {meta.get('hard_limit', 2)} max):")
print(f"{'session_id':<30} {'task_id':<20} {'phase':<12} {'class':<10} {'pid':<8} {'daemon':<7} {'stale'}")
print("-" * 100)
for s in sessions:
    sid    = (s.get("session_id") or "?")[:28]
    tid    = (s.get("task_id") or "?")[:18]
    phase  = (s.get("phase") or "?")[:10]
    cls    = (s.get("class") or "?")[:8]
    pid    = str(s.get("pid") or "null")[:6]
    daemon = "yes" if s.get("daemon_mode") else "no"
    stale  = "STALE" if s.get("stale") else "-"
    print(f"{sid:<30} {tid:<20} {phase:<12} {cls:<10} {pid:<8} {daemon:<7} {stale}")
PYEOF
}

# leadv2_active_check_limits <class>
# Exit codes: 0=OK, 1=hard_limit_reached, 2=heavy_conflict, 3=budget_refused
leadv2_active_check_limits() {
  local cls="${1:-Standard}"
  local yaml_file overrides_file
  yaml_file="$(_leadv2_yaml_file)"
  overrides_file="${LEADV2_PROJECT_ROOT}/.claude/leadv2-overrides/active-limits.yaml"

  python3 - "$yaml_file" "$cls" "$overrides_file" <<'PYEOF'
import sys, os
try:
    import yaml
except ImportError:
    sys.exit(0)  # fail open if yaml missing

yaml_file, cls, overrides_file = sys.argv[1], sys.argv[2], sys.argv[3]

if not os.path.exists(yaml_file):
    sys.exit(0)

with open(yaml_file, encoding="utf-8") as fh:
    data = yaml.safe_load(fh) or {}

meta = data.get("meta") or {}
sessions = [s for s in (data.get("sessions") or []) if not s.get("stale")]

# Repo-local override (per leadv2-overrides/active-limits.yaml) wins over active.yaml meta
overrides = {}
if os.path.exists(overrides_file):
    try:
        with open(overrides_file, encoding="utf-8") as fh:
            overrides = yaml.safe_load(fh) or {}
    except Exception as e:
        print(f"[registry] WARN: failed to read overrides {overrides_file}: {e}", file=sys.stderr)

def _resolve(key, default):
    if key in overrides:
        return overrides[key]
    if key in meta:
        return meta[key]
    return default

hard_limit           = _resolve("hard_limit", 3)
heavy_strategic_solo = _resolve("heavy_strategic_solo", True)
light_max            = _resolve("light_max", 3)
standard_max         = _resolve("standard_max", 2)

cls_l = cls.lower()

# Check hard limit (total active sessions, all classes)
if len(sessions) >= hard_limit:
    print(f"[registry] hard limit reached: {len(sessions)}/{hard_limit} active sessions", file=sys.stderr)
    sys.exit(1)

# Check heavy/strategic conflict (solo rule)
if cls_l in ("heavy", "strategic") and heavy_strategic_solo:
    conflicting = [s for s in sessions if s.get("class", "").lower() in ("heavy", "strategic")]
    if conflicting:
        print(f"[registry] heavy/strategic conflict: {conflicting[0].get('task_id')} already running", file=sys.stderr)
        sys.exit(2)

# Per-class caps
def _count(label):
    return sum(1 for s in sessions if s.get("class", "").lower() == label)

if cls_l == "light" and _count("light") >= light_max:
    print(f"[registry] light cap reached: {_count('light')}/{light_max}", file=sys.stderr)
    sys.exit(1)

# Standard cap counts Standard + Standard-light (treated equally)
if cls_l in ("standard", "standard-light"):
    std_count = sum(1 for s in sessions if s.get("class", "").lower() in ("standard", "standard-light"))
    if std_count >= standard_max:
        print(f"[registry] standard cap reached: {std_count}/{standard_max}", file=sys.stderr)
        sys.exit(1)

sys.exit(0)
PYEOF
}
