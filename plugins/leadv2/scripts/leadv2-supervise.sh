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
#   active.yaml — D-d (SUPERVISE-V2-01 item 4) ONLY: adopts a triple-proof
#     tmux orphan row, and tombstones+prunes a row corroborated dead across
#     two consecutive calls. Both writes are additive/subtractive only —
#     never rewrites a live row, never restarts/kills a process. Gated
#     observe_only (env or automatic D-e 2-cycle rollout window) skips both.
#   <control-plane>/tombstones.yaml — one entry per pruned dead row, written
#     BEFORE the prune under a separate lock.
#
# Usage:
#   leadv2-supervise.sh [--json] [--since <ISO>] [--print]
#
# SESSION-HANDOFF-01: a full (non-delta) --json call also carries a bounded
# "resume" key — a live-composed <supervisor-handoff> restore block (role +
# founder rules, live lanes, focus/next-action, freshest open-threads tail,
# tasks.yaml P0/P1 top-10). Computed by scripts/leadv2-supervise-resume.sh
# from the same canonical on-disk sources this script already reads/
# reconciles — no new state file. `--print` execs straight into that
# composer (skipping every mutation path below: sentinel write, tmux
# adopt/prune, phase-backfill, truth-probe) as a lightweight fallback entry
# point for the leadv2-supervise skill.
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
PRINT_MODE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --json)  JSON_MODE=1; shift ;;
    --since) SINCE="${2:-}"; shift 2 ;;
    --print) PRINT_MODE=1; shift ;;
    -h|--help)
      printf -- 'Usage: leadv2-supervise.sh [--json] [--since <ISO>] [--print]\n'
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

# SESSION-HANDOFF-01: --print is a lightweight fallback entry point for the
# leadv2-supervise skill — composes the SAME bounded <supervisor-handoff>
# resume block as the "resume" key below, via the shared composer script,
# but skips every mutation/reconciliation path in this script (sentinel
# write, tmux adoption/prune, phase-backfill, truth-probe). Read-only,
# fast, safe to call whenever the mandatory --json call is unavailable.
if [[ "$PRINT_MODE" -eq 1 ]]; then
  RESUME_SH="${SCRIPT_DIR}/leadv2-supervise-resume.sh"
  if [[ -x "$RESUME_SH" || -f "$RESUME_SH" ]]; then
    if [[ "$JSON_MODE" -eq 1 ]]; then
      exec bash "$RESUME_SH" --json --project-root "$PROJECT_ROOT"
    else
      exec bash "$RESUME_SH" --project-root "$PROJECT_ROOT"
    fi
  fi
  printf -- '<supervisor-handoff>\nHANDOFF DEGRADED — resume composer script missing at %s\n</supervisor-handoff>\n' "$RESUME_SH"
  exit 0
fi

# LEAD-CONTROL-PLANE-01: active.yaml lives in the control plane (outside any
# worktree) — resolved via leadv2-state-path.sh, never hardcoded here.
ACTIVE_YAML="$(PROJECT_ROOT="$PROJECT_ROOT" "${SCRIPT_DIR}/leadv2-state-path.sh" active.yaml)"
HANDOFF_DIR="${PROJECT_ROOT}/docs/handoff"
SNAPSHOT="$(PROJECT_ROOT="$PROJECT_ROOT" "${SCRIPT_DIR}/leadv2-state-path.sh" .supervise-last.json)"
SUPERVISE_SENTINEL="$(PROJECT_ROOT="$PROJECT_ROOT" "${SCRIPT_DIR}/leadv2-state-path.sh" .supervise-active)"

# SUPERVISE-GUARD-01 (restored, SUPERVISE-V2-01 fix-1 C1; mode split fix-2
# R2-1): (re)write the supervise-mode sentinel -- {"pid","started_at","mode"}
# -- consumed by hooks/leadv2-supervise-fanout-guard.sh (PreToolUse:Agent).
# `mode` resolves the D-f=A contradiction found in codex-review-2.md finding
# 1. The current default is provider-aware full-cycle relay: the supervisor
# dispatches complete Claude/Codex sessions through leadv2-fanout.sh and must
# not create abbreviated in-session worker lanes. Two compatibility modes:
#   - "legacy-relay" (DEFAULT): coordinator-only; any Agent spawn is denied
#     and directed to the provider-neutral full-cycle fanout runner.
#   - "interactive-lanes": compatibility escape hatch for old flows that
#     intentionally use same-session Workflow/Agent lanes.
# `mode` is recomputed on every (re)write (reflects the CURRENT invocation's
# intent), while pid/started_at identity is preserved for a live sentinel.
# Idempotent: a live sentinel keeps its original started_at; a missing/dead
# one is (re)written with the durable claude-process pid (see
# leadv2-active-registry.sh:_lv2_durable_pid). Cleared on Stop by
# hooks/leadv2-supervise-sentinel-cleanup.sh, and self-heals (deleted) by the
# guard itself the next time it sees a dead pid. Deleted by 799dc99's B1
# root-resolution refactor and never re-added -- guard was silently inert
# (lying-green: hook installed, reads a file nobody wrote) until fix-1.
_SUP_MODE="${LEADV2_SUPERVISE_MODE:-legacy-relay}"
if [[ "$_SUP_MODE" != "interactive-lanes" && "$_SUP_MODE" != "legacy-relay" ]]; then
  _SUP_MODE="legacy-relay"
fi
if [[ -f "${SCRIPT_DIR}/leadv2-active-registry.sh" ]]; then
  # shellcheck source=leadv2-active-registry.sh
  source "${SCRIPT_DIR}/leadv2-active-registry.sh"
  _SUP_PID="$(_lv2_durable_pid 2>/dev/null || echo "$PPID")"
  _SUP_TS="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  python3 - "$SUPERVISE_SENTINEL" "$_SUP_PID" "$_SUP_TS" "$_SUP_MODE" <<'PYSENTINEL' 2>/dev/null || true
import sys, os, json, tempfile

path, pid_str, ts, mode = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

def pid_alive(pid_val):
    try:
        os.kill(int(pid_val), 0)
        return True
    except (TypeError, ValueError, ProcessLookupError, PermissionError):
        return False

existing_started_at = None
existing_pid = None
existing_mode = None
if os.path.isfile(path):
    try:
        with open(path, encoding="utf-8") as fh:
            d = json.load(fh) or {}
        if pid_alive(d.get("pid")):
            existing_started_at = d.get("started_at")
            existing_pid = int(d.get("pid"))
            existing_mode = d.get("mode")
    except Exception:
        pass

# A background supervise-loop and a concurrent ordinary lead both call this
# snapshot script. Neither may steal ownership from the live interactive
# supervisor: the PreToolUse guard is intentionally scoped to one process
# tree. Only the current owner may refresh its own mode; a different live PID
# preserves the existing identity and mode verbatim.
caller_pid = int(pid_str)
if existing_pid is not None and existing_pid != caller_pid:
    owner_pid = existing_pid
    owner_mode = existing_mode or "legacy-relay"
else:
    owner_pid = caller_pid
    owner_mode = mode

out = {
    "pid": owner_pid,
    "started_at": existing_started_at or ts,
    "mode": owner_mode,
}
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
# scripts/leadv2-phase8-assert.sh after all seven hard assertions pass — a
# second, shared signal alongside the worktree-local phase8-passed.flag.
LEADV2_DIR_RESOLVED="$(PROJECT_ROOT="$PROJECT_ROOT" "${SCRIPT_DIR}/leadv2-state-path.sh" 2>/dev/null || true)"
BUS_JSONL="${LEADV2_DIR_RESOLVED:+${LEADV2_DIR_RESOLVED}/bus.jsonl}"
BUS_OFFSET_FILE="${LEADV2_DIR_RESOLVED:+${LEADV2_DIR_RESOLVED}/.bus-offsets/supervise-closed-consumer}"

# ── D-d tmux reconciliation + honest death (SUPERVISE-V2-01 item 4) ────────
# Gathered on EVERY call (delta and full) — corroborated death requires two
# CONSECUTIVE 5s event polls to see the same evidence, not just the 300s
# pulse. Portable: real tmux binary, no GNU-only flags; "|||" delimiter
# (never a raw tab) avoids shell tab-escaping ambiguity in -F format strings.
# LEADV2_SUPERVISE_TMUX_SOCKET lets tests point at an isolated `tmux -L`
# server without ever touching a real "leadv2" session.
TMUX_SESSION_NAME="${LEADV2_FANOUT_TMUX_SESSION:-leadv2}"
TMUX_SOCKET_ARGS=()
if [[ -n "${LEADV2_SUPERVISE_TMUX_SOCKET:-}" ]]; then
  TMUX_SOCKET_ARGS=(-L "$LEADV2_SUPERVISE_TMUX_SOCKET")
fi
TMUX_WINDOWS_TSV=""
TMUX_PANES_TSV=""
if command -v tmux >/dev/null 2>&1 && tmux "${TMUX_SOCKET_ARGS[@]}" has-session -t "$TMUX_SESSION_NAME" 2>/dev/null; then
  TMUX_WINDOWS_TSV="$(tmux "${TMUX_SOCKET_ARGS[@]}" list-windows -t "$TMUX_SESSION_NAME" -F '#{window_name}' 2>/dev/null || true)"
  TMUX_PANES_TSV="$(tmux "${TMUX_SOCKET_ARGS[@]}" list-panes -t "$TMUX_SESSION_NAME" -F '#{window_name}|||#{pane_pid}' 2>/dev/null || true)"
fi
TASKS_YAML_PATH="${PROJECT_ROOT}/docs/tasks.yaml"
TOMBSTONES_FILE="$(PROJECT_ROOT="$PROJECT_ROOT" "${SCRIPT_DIR}/leadv2-state-path.sh" tombstones.yaml)"
ACTIVE_LOCKFILE="${ACTIVE_YAML}.lock"
# D-e: first 2 full-call reconciliation cycles after rollout are ALWAYS
# observe-only for legacy rows (enforced cycle-counted in the python core
# below via the persisted snapshot, not just this env flag). This env flag
# additionally lets a caller force observe-only at ANY time (verification.md
# canary command uses it).
OBSERVE_ONLY="${LEADV2_SUPERVISE_OBSERVE_ONLY:-0}"

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

# ── F2 truth-probe generic hook contract (SUPERVISE-V2-01 item 3) ──────────
# Runs ONLY on a full (non-delta, SINCE empty) snapshot call — the loop's own
# 300s pulse cadence is what makes those calls, so this naturally runs "once
# per 300s pulse" without a separate timer here. If
# <repo>/.claude/leadv2-overrides/supervise-truth-probe.sh exists+executable,
# invoke it with a 10s PORTABLE timeout (python3 subprocess.run(timeout=...),
# never the GNU-only `timeout` binary) and require JSON stdout shaped
# {"breaches": [{id, severity, summary, evidence_cmd}, ...]}. ANY failure —
# missing hook, non-zero exit, timeout, malformed JSON — degrades to
# status:"unavailable" with breaches:[] (fail-open-to-EMPTY). This must NEVER
# be read as "no breaches confirmed clear" (fail-open-to-clear) — callers
# (leadv2-supervise-pick.sh, the loop's URGENT renderer) key off `status`,
# not just an empty breaches list. The persona-engine probe INSTANCE is
# written elsewhere (GLM-FIRST-01, out of this task's scope) — this is only
# the generic contract + cache writer.
TRUTH_BREACHES_JSON='{"status":"skipped","breaches":[]}'
if [[ -z "$SINCE" ]]; then
  TRUTH_PROBE_SH="${PROJECT_ROOT}/.claude/leadv2-overrides/supervise-truth-probe.sh"
  if [[ -x "$TRUTH_PROBE_SH" ]]; then
    TRUTH_BREACHES_JSON="$(python3 - "$TRUTH_PROBE_SH" <<'PYPROBE'
# SUPERVISE-V2-01 fix: the probe script backgrounds 3 check functions (ssh/
# curl/python3 children) via `&`. `subprocess.run(capture_output=True,
# timeout=N)` pipes stdout/stderr; on timeout it SIGKILLs only the DIRECT
# child, never the process group. Any grandchild still alive at that instant
# (a straggler ssh/curl under network load) keeps the inherited PIPE write-end
# open, so CPython's communicate() blocks draining that pipe well past the
# declared timeout -- reproduced hanging 20s+ past a timeout=10 in isolation.
# Fix: start the probe in its own session (setsid) so `&`-backgrounded
# descendants share its process group (bash job control is off by default in
# non-interactive scripts), capture stdout to a plain temp FILE (never
# blocks -- no pipe backpressure), and on timeout SIGKILL the whole group via
# os.killpg before giving up. Timeout raised 10->12 to sit safely above the
# probe's own 9s internal watchdog + cleanup instead of nearly tying it.
import subprocess, sys, json, os, signal, tempfile

probe_path = sys.argv[1]
try:
    with tempfile.TemporaryFile() as outf:
        proc = subprocess.Popen(
            [probe_path],
            stdout=outf,
            stderr=subprocess.DEVNULL,
            stdin=subprocess.DEVNULL,
            start_new_session=True,
        )
        try:
            rc = proc.wait(timeout=12)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
            except (ProcessLookupError, PermissionError):
                pass
            try:
                proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                pass
            print(json.dumps({"status": "unavailable", "breaches": [], "reason": "timeout"}))
            sys.exit(0)
        outf.seek(0)
        out = outf.read().decode("utf-8", errors="replace")
        if rc != 0:
            print(json.dumps({"status": "unavailable", "breaches": [], "reason": f"exit {rc}"}))
        else:
            try:
                d = json.loads(out)
                breaches = d.get("breaches") if isinstance(d, dict) else None
                if not isinstance(breaches, list):
                    breaches = []
                print(json.dumps({"status": "checked", "breaches": breaches}))
            except Exception as e:
                print(json.dumps({"status": "unavailable", "breaches": [], "reason": f"malformed_json:{e.__class__.__name__}"}))
except Exception as e:
    print(json.dumps({"status": "unavailable", "breaches": [], "reason": e.__class__.__name__}))
PYPROBE
)"
  else
    TRUTH_BREACHES_JSON='{"status":"no_probe_configured","breaches":[]}'
  fi
  # Best-effort ONLY (per header comment above: "informational only, never
  # read as fail-open-to-clear"). An unwritable state dir must NOT kill this
  # script here — the real B1 fail-closed contract belongs to the snapshot
  # write in the python core below, which already emits a typed
  # state_write_error. Regression (test-supervise-failclosed.sh Test 5):
  # this block used to die under `set -e` on a failed redirect/mv before the
  # typed-error path ever ran, producing rc=1 with EMPTY stdout instead of
  # {"error":"state_write_error",...}. Every write attempt below is now
  # guarded so a permission failure degrades silently and falls through to
  # the real fail-closed check.
  TRUTH_BREACHES_FILE="$(PROJECT_ROOT="$PROJECT_ROOT" "${SCRIPT_DIR}/leadv2-state-path.sh" truth-breaches-last.json)"
  mkdir -p "$(dirname "$TRUTH_BREACHES_FILE")" 2>/dev/null || true
  _TB_TMP="${TRUTH_BREACHES_FILE}.tmp.$$"
  python3 -c '
import json, sys, datetime
d = json.loads(sys.argv[1])
d["observed_at"] = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
print(json.dumps(d))
' "$TRUTH_BREACHES_JSON" > "$_TB_TMP" 2>/dev/null || printf -- '%s' "$TRUTH_BREACHES_JSON" > "$_TB_TMP" 2>/dev/null || true
  if [[ -f "$_TB_TMP" ]]; then
    mv "$_TB_TMP" "$TRUTH_BREACHES_FILE" 2>/dev/null || rm -f "$_TB_TMP" 2>/dev/null || true
  fi
fi

python3 - "$ACTIVE_YAML" "$HANDOFF_DIR" "$SNAPSHOT" "$JSON_MODE" "$SINCE" "$CP_QUESTIONS_DIR" "${BUS_JSONL:-}" "${BUS_OFFSET_FILE:-}" "$TRUTH_BREACHES_JSON" "$TMUX_WINDOWS_TSV" "$TMUX_PANES_TSV" "$TASKS_YAML_PATH" "$ACTIVE_LOCKFILE" "$TOMBSTONES_FILE" "$OBSERVE_ONLY" "$SCRIPT_DIR" "$PROJECT_ROOT" <<'PY'
import sys, os, json, glob, datetime, subprocess
from collections import deque

(active_yaml, handoff_dir, snapshot_path, json_mode, since, cp_questions_dir,
 bus_jsonl, bus_offset_file, truth_breaches_json, tmux_windows_tsv,
 tmux_panes_tsv, tasks_yaml_path, active_lockfile, tombstones_file,
 observe_only_env, script_dir, project_root) = sys.argv[1:18]
json_mode = json_mode == "1"
delta_mode = bool(since)

try:
    _truth = json.loads(truth_breaches_json)
except Exception:
    _truth = {"status": "unavailable", "breaches": []}
truth_probe_status = _truth.get("status", "unavailable")
truth_probe_reason = _truth.get("reason")
truth_breaches = _truth.get("breaches") or []

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

# ── D-d: tmux reconciliation, triple-proof adoption, corroborated death ────
# (SUPERVISE-V2-01 item 4). Runs every call (delta and full) so death
# corroboration can span two consecutive 5s event polls, per D-d spec.
def _ps_tree():
    try:
        r = subprocess.run(["ps", "-eo", "pid,ppid,comm"], capture_output=True, text=True, timeout=5)
    except Exception:
        return {}, {}
    children_, comms_ = {}, {}
    for line in r.stdout.splitlines()[1:]:
        parts = line.split(None, 2)
        if len(parts) < 3:
            continue
        try:
            pid_v, ppid_v = int(parts[0]), int(parts[1])
        except ValueError:
            continue
        comms_[pid_v] = parts[2].split("/")[-1].lower()
        children_.setdefault(ppid_v, []).append(pid_v)
    return children_, comms_

def _find_claude_descendant(pane_pid, children_, comms_):
    if pane_pid is None:
        return None
    seen, q = set(), deque([pane_pid])
    while q:
        p = q.popleft()
        if p in seen:
            continue
        seen.add(p)
        if "claude" in comms_.get(p, ""):
            return p
        for c in children_.get(p, []):
            q.append(c)
    return None

def _pid_birth_of(pid_val):
    try:
        r = subprocess.run(["ps", "-o", "lstart=", "-p", str(pid_val)], capture_output=True, text=True, timeout=5)
        b = r.stdout.strip()
        return " ".join(b.split()) if b else None
    except Exception:
        return None

tmux_windows = {w.strip() for w in tmux_windows_tsv.splitlines() if w.strip()}
tmux_panes = {}
for line in tmux_panes_tsv.splitlines():
    if "|||" not in line:
        continue
    wname, pane_pid_s = line.split("|||", 1)
    wname = wname.strip()
    try:
        tmux_panes[wname] = int(pane_pid_s.strip())
    except ValueError:
        continue

known_task_ids = set()
try:
    if os.path.isfile(tasks_yaml_path):
        with open(tasks_yaml_path, encoding="utf-8") as fh:
            _td = yaml.safe_load(fh)
        _items = []
        if isinstance(_td, list):
            _items = _td
        elif isinstance(_td, dict):
            for _k in ("tasks", "items", "queues"):
                if isinstance(_td.get(_k), list):
                    _items = _td[_k]
                    break
        for it in _items:
            if isinstance(it, dict) and it.get("id"):
                known_task_ids.add(str(it["id"]))
except Exception as e:
    warnings.append(f"tasks.yaml unreadable for tmux-adoption id check: {e.__class__.__name__}: {e}")
# mission D-d: "tid in tasks.yaml/active" — an already-live registry row also
# satisfies the id-membership leg of the triple proof.
known_task_ids |= set(current.keys())

children_map, comms_map = (_ps_tree() if (tmux_windows or current) else ({}, {}))

orphans = []
pending_adopts = []  # triple-proof-satisfied candidates this call
for wname in sorted(tmux_windows):
    if wname in current:
        continue  # matching live row already exists — nothing to adopt
    pane_pid = tmux_panes.get(wname)
    claude_pid = _find_claude_descendant(pane_pid, children_map, comms_map)
    if wname in known_task_ids and claude_pid is not None:
        pending_adopts.append({
            "task_id": wname, "window": wname, "pane_pid": pane_pid,
            "pid": claude_pid, "pid_birth": _pid_birth_of(claude_pid),
        })
    else:
        reason = "unknown_task_id" if wname not in known_task_ids else "no_live_claude_pid"
        orphans.append({"window": wname, "reason": reason})

# D-e: the first 2 FULL (non-delta) reconciliation cycles after rollout are
# ALWAYS observe-only for legacy protocol_version==1 rows — counted here
# (never in a delta call) so a burst of 5s polls can't fast-forward past it.
reconcile_cycle = int(prev.get("reconcile_cycle_count", 0)) if isinstance(prev, dict) else 0
if not delta_mode:
    reconcile_cycle += 1
force_observe_only = reconcile_cycle <= 2
observe_only = force_observe_only or (observe_only_env == "1")

SPAWN_GRACE_MIN = 5
prev_dead_candidates = (prev.get("dead_candidates") or {}) if isinstance(prev, dict) else {}
dead_candidates_next = {}
dead_now = []
pending_prunes = []

for tid, s in list(current.items()):
    started_at_dt = parse_iso(s.get("started_at"))
    if started_at_dt and (now - started_at_dt).total_seconds() < SPAWN_GRACE_MIN * 60:
        continue  # spawning grace — never a death candidate this young
    backend = s.get("backend") or ("tmux" if s.get("tmux_window") else ("headless" if s.get("daemon_mode") else "terminal"))

    # R2-3 fix (codex-review-2.md finding 3): death evidence is gathered
    # per-signal (window presence, PID liveness/birth) but for a tmux-backend
    # lane BOTH must be corroborated together — D-d spec is "death =
    # corroborated (window+PID birth, 2 polls)", not either signal alone. The
    # prior code treated ANY single reason as sufficient, so a tmux window
    # that transiently fails to list (tmux server hiccup, rename race) while
    # the underlying claude PID is provably still alive got pruned after two
    # polls — a live child killed by a false-positive, in direct violation of
    # D-d and the live-child off_limits constraint. Non-tmux backends
    # (headless/workflow — no window concept at all) are unaffected: PID
    # evidence alone remains sufficient for them, exactly as before.
    window_missing = False
    if backend == "tmux":
        win = s.get("tmux_window") or tid
        window_missing = win not in tmux_windows

    pid = s.get("pid")
    pid_issue = False
    pid_issue_reason = None
    if pid is None or not pid_alive(pid):
        pid_issue = True
        pid_issue_reason = "pid dead"
    else:
        stored_birth = s.get("pid_birth")
        cur_birth = _pid_birth_of(pid)
        if stored_birth and cur_birth and stored_birth != cur_birth:
            pid_issue = True
            pid_issue_reason = "pid birth mismatch (reuse)"

    reasons = []
    if backend == "tmux":
        if window_missing and pid_issue:
            reasons = ["tmux window missing", pid_issue_reason]
        # else: window-missing alone or pid-issue alone on a tmux lane is
        # NOT corroborated evidence of death — no reasons, falls through to
        # `continue` below, same as fully-clean evidence.
    elif pid_issue:
        reasons = [pid_issue_reason]

    if not reasons:
        continue  # evidence clears any prior candidate marker — not carried forward

    is_legacy = s.get("protocol_version", 1) == 1
    if tid in prev_dead_candidates:
        # corroborated on a second consecutive poll — ALWAYS computed, even
        # under observe_only (honesty: a candidate must be visible via
        # would_prune, never silently dropped just because the write is
        # gated). Only the actual write below is observe_only-gated.
        dead_now.append({"task_id": tid, "reasons": reasons, "legacy": is_legacy})
        dead_candidates_next[tid] = prev_dead_candidates[tid]
        pending_prunes.append({"task_id": tid, "reasons": reasons, "last_state": dict(s),
                                "gated": observe_only or (is_legacy and force_observe_only)})
    else:
        dead_candidates_next[tid] = now_iso()

apply_prunes = [p for p in pending_prunes if not p["gated"]]

# ── Apply mutations under the SAME lock leadv2-active-registry.sh uses ─────
# (extends active.yaml, never rewrites the registry's own lock primitive —
# this is a direct, independent flock on the identical lockfile path).
applied_adopts = []
tombstoned_ids = []  # R2-4: only these task_ids may ever be pruned from active.yaml
if (pending_adopts or apply_prunes) and not observe_only:
    import fcntl as _fcntl
    # B1 fail-closed (test-supervise-failclosed.sh Test 5 regression guard):
    # any OSError while writing active.yaml/tombstones under an unwritable
    # state dir must surface as the typed state_write_error contract, never
    # an unhandled traceback (untyped stdout + non-JSON crash).
    try:
      os.makedirs(os.path.dirname(active_lockfile), exist_ok=True)
      _lf = open(active_lockfile, "a+")
      try:
        _fcntl.flock(_lf, _fcntl.LOCK_EX)

        # R2-4 fix (codex-review-2.md finding 4): tombstone FIRST, prune
        # SECOND. The prior order wrote active.yaml with the dead rows
        # ALREADY REMOVED before the tombstone file was even opened — a
        # tombstone write failure (or a crash between the two writes) meant
        # a row was permanently pruned with no historical record at all,
        # violating "tombstone before prune". Now: a row is only removed
        # from active.yaml if its tombstone write DURABLY SUCCEEDED this
        # call; a tombstone failure keeps the row live in active.yaml (and
        # in `current`, below) and surfaces a warning — never a silent
        # permanent prune with no tombstone.
        if apply_prunes:
          _tlock = tombstones_file + ".lock"
          try:
            os.makedirs(os.path.dirname(tombstones_file), exist_ok=True)
            _tlf = open(_tlock, "a+")
            try:
                _fcntl.flock(_tlf, _fcntl.LOCK_EX)
                _existing = []
                if os.path.isfile(tombstones_file):
                    try:
                        with open(tombstones_file, encoding="utf-8") as fh:
                            _existing = yaml.safe_load(fh) or []
                        if not isinstance(_existing, list):
                            _existing = []
                    except Exception:
                        _existing = []
                for p in apply_prunes:
                    _existing.append({
                        "task_id": p["task_id"], "tombstoned_at": now_iso(),
                        "reasons": p["reasons"], "last_state": p["last_state"],
                        "log_path": p["last_state"].get("log_path"),
                    })
                _ttmp = tombstones_file + f".tmp.{os.getpid()}"
                with open(_ttmp, "w", encoding="utf-8") as fh:
                    yaml.dump(_existing, fh, default_flow_style=False, sort_keys=False)
                os.replace(_ttmp, tombstones_file)
                tombstoned_ids = [p["task_id"] for p in apply_prunes]
            finally:
                _fcntl.flock(_tlf, _fcntl.LOCK_UN)
                _tlf.close()
          except OSError as e:
            # Tombstone write failed — do NOT prune. Every intended-prune
            # row stays in active.yaml this cycle; loud warning, never a
            # swallowed failure (same loud-fail philosophy as the
            # control-plane question read above).
            warnings.append(
                f"tombstone write failed for {[p['task_id'] for p in apply_prunes]} "
                f"({e.__class__.__name__}: {e}) — row(s) KEPT, prune skipped this cycle"
            )
            tombstoned_ids = []

        with open(active_yaml, encoding="utf-8") as fh:
            _d = yaml.safe_load(fh) or {}
        _sess = _d.setdefault("sessions", [])
        _by_tid = {s.get("task_id"): s for s in _sess}
        for a in pending_adopts:
            if a["task_id"] in _by_tid:
                continue  # raced with another writer — never clobber
            _row = {
                "session_id": f"tmux-adopt-{a['task_id']}-{int(now.timestamp())}",
                "task_id": a["task_id"], "worktree": None, "branch": None,
                "started_at": now_iso(), "phase": "unknown", "class": "Standard",
                "pulse_log": None, "pid": a["pid"], "pid_birth": a["pid_birth"],
                "parent_session_id": None, "daemon_mode": False,
                "last_pulse_at": now_iso(), "stale": False,
                "note": f"adopted from tmux window {a['window']}",
                "protocol_version": 2, "backend": "tmux", "origin": "adopted",
                "phase_started_at": now_iso(), "updated_at": now_iso(),
                "tmux_window": a["window"], "tmux_pane": a.get("pane_pid"),
                "log_path": None, "provider_receipts": [],
            }
            _sess.append(_row)
            applied_adopts.append(a["task_id"])
        # Only tombstone-confirmed ids are removed — a tombstone-failed
        # prune candidate is left in place (see above).
        _prune_ids = set(tombstoned_ids)
        if _prune_ids:
            _d["sessions"] = [s for s in _sess if s.get("task_id") not in _prune_ids]
        _tmp = active_yaml + f".tmp.{os.getpid()}"
        with open(_tmp, "w", encoding="utf-8") as fh:
            yaml.dump(_d, fh, default_flow_style=False, sort_keys=False)
        os.replace(_tmp, active_yaml)
      finally:
        _fcntl.flock(_lf, _fcntl.LOCK_UN)
        _lf.close()

      # Best-effort founder escalation via the existing canonical question
      # channel — never a second question mechanism, never auto-restart.
      # Only for rows that were ACTUALLY tombstoned+pruned this call.
      if tombstoned_ids:
        _ask_sh = os.path.join(script_dir, "leadv2-ask.sh")
        if os.path.isfile(_ask_sh):
            for p in apply_prunes:
                if p["task_id"] not in tombstoned_ids:
                    continue
                try:
                    subprocess.run(
                        [_ask_sh, p["task_id"],
                         f"Task {p['task_id']} corroborated dead: {'; '.join(p['reasons'])}. Escalate.",
                         "--option", "inspect|inspect logs first",
                         "--option", "restart|restart the task",
                         "--option", "abandon|mark abandoned",
                         "--no-block"],
                        capture_output=True, text=True, timeout=10,
                    )
                except Exception as e:
                    warnings.append(f"dead-escalation ask failed for {p['task_id']}: {e.__class__.__name__}: {e}")
    except OSError as e:
        emit_fatal("state_write_error", f"could not write active.yaml/tombstones mutation: {e.__class__.__name__}: {e}")

# Reflect mutations in THIS call's in-memory view without re-reading the file.
for tid in applied_adopts:
    a = next(x for x in pending_adopts if x["task_id"] == tid)
    current[tid] = {
        "task_id": tid, "phase": "unknown", "started_at": now_iso(),
        "last_pulse_at": now_iso(), "pid": a["pid"], "stale": False,
        "protocol_version": 2, "backend": "tmux", "tmux_window": a["window"],
    }
# R2-4: only actually-tombstoned rows are removed from the in-memory view —
# a gated (observe_only) OR tombstone-failed candidate stays visible in
# `current`/table, never silently vanishes just because a prune was skipped.
for p in pending_prunes:
    if p["task_id"] in tombstoned_ids:
        current.pop(p["task_id"], None)
sessions = list(current.values())

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
# R2-5 fix (codex-review-2.md finding 5): dead_now must participate in the
# SAME dedup discipline as waiting/stuck/closed. Previously the JSON `dead`
# key returned the raw dead_now list on EVERY call — including every 5s
# delta poll while the row remained corroborated-dead-but-not-yet-pruned
# (e.g. observe_only, or a tombstone failure per R2-4's keep-row path) —
# so leadv2-supervise-loop.sh's _render_events appended a duplicate DEAD
# urgent line every single poll instead of once per liveness change,
# violating the pulse ceiling ("unchanged poll -> zero bytes appended").
for d in dead_now:
    current_events.add(f"dead:{d['task_id']}:{'|'.join(d['reasons'])}")

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
            # D-d bookkeeping (item 4): carried forward so death corroboration
            # spans two consecutive calls and the D-e 2-cycle observe-only
            # rollout window survives across invocations of this script.
            "dead_candidates": dead_candidates_next,
            "reconcile_cycle_count": reconcile_cycle,
        }, fh, indent=2)
    os.replace(tmp, snapshot_path)
except Exception as e:
    emit_fatal("state_write_error", f"could not write snapshot to {snapshot_path}: {e.__class__.__name__}: {e}")

# ── Filter output items to only the ones whose event_key is in new_events ──
def event_key_waiting(q):
    return f"waiting:{q['task_id']}:{q['qid']}"

def event_key_stuck(st):
    return f"stuck:{st['task_id']}:{'|'.join(st['reasons'])}"

def event_key_dead(d):
    return f"dead:{d['task_id']}:{'|'.join(d['reasons'])}"

out_waiting = [q for q in waiting_items if event_key_waiting(q) in new_events] if delta_mode else waiting_items
out_stuck = [st for st in stuck_items if event_key_stuck(st) in new_events] if delta_mode else stuck_items
out_closed = [tid for tid in closed_now if f"closed:{tid}" in new_events] if delta_mode else closed_now
# R2-5: same filter pattern as waiting/stuck/closed — a full (non-delta)
# call always reports the complete live dead_now state; a delta call only
# reports a dead_now entry whose event_key is NEW since the last snapshot.
out_dead = [d for d in dead_now if event_key_dead(d) in new_events] if delta_mode else dead_now

# ── SESSION-HANDOFF-01: bounded resume object (full calls only) ────────────
# Rides this mandatory first --json call the leadv2-supervise skill already
# makes — no new hook, no new state file. Computed only on a full (non-delta)
# call, same gating as truth_probe/orphans/adopted above; a delta poll never
# needs to re-render the whole restore block. Best-effort: any failure here
# degrades to a typed stub, never crashes the parent snapshot call (this
# script's contract is "exit 0 always" for a status probe).
resume_obj = {"status": "skipped_delta"} if delta_mode else {"status": "degraded", "degraded": ["resume composer unavailable"]}
if not delta_mode:
    resume_script = os.path.join(script_dir, "leadv2-supervise-resume.sh")
    if os.path.isfile(resume_script):
        try:
            _rr = subprocess.run(
                ["bash", resume_script, "--json", "--project-root", project_root],
                capture_output=True, text=True, timeout=8,
            )
            resume_obj = json.loads(_rr.stdout) if _rr.returncode == 0 and _rr.stdout.strip() else {
                "status": "degraded", "degraded": [f"resume composer exit {_rr.returncode}"]
            }
        except Exception as e:
            resume_obj = {"status": "degraded", "degraded": [f"resume composer error: {e.__class__.__name__}: {e}"]}

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
        # F2 truth-probe contract (SUPERVISE-V2-01 item 3): only populated on
        # a full (non-delta) call — see the bash block above. delta_mode
        # calls always report status "skipped" with an empty list; consumers
        # must not read that as "clear".
        "truth_probe": truth_probe_status,
        "truth_probe_reason": truth_probe_reason,
        "truth_breaches": truth_breaches,
        # D-d (item 4): orphans are reported, NEVER silently adopted; dead
        # rows are corroborated-twice and already tombstoned+pruned above
        # (or reported only, if observe_only) — the loop's pulse renderer
        # excludes any task_id present here from the N-lane count.
        "orphans": orphans,
        "adopted": applied_adopts,
        # Honesty (CONTROL-TRUTH discipline): a triple-proof-eligible
        # candidate must never go INVISIBLE just because observe_only
        # skipped the write — that is exactly the "control renders, engine
        # never reads it" lying-green pattern. would_adopt/would_prune list
        # every candidate that passed proof but was not applied this call.
        "would_adopt": [a["task_id"] for a in pending_adopts if a["task_id"] not in applied_adopts],
        # Fixed observe_only visibility gap: report every GATED prune
        # (per-item p["gated"], not just the global observe_only flag) —
        # a legacy row individually gated by D-e's 2-cycle window while
        # global observe_only is false must still surface here, never be
        # silently dropped.
        "would_prune": [p["task_id"] for p in pending_prunes if p["gated"]],
        # R2-5 fix (codex-review-2.md finding 5): out_dead, not the raw
        # dead_now list — deduped through new_events exactly like
        # waiting/stuck/closed, so a delta call reports a DEAD event once
        # per liveness change, never once per 5s poll while the state is
        # unchanged (pulse-ceiling violation otherwise).
        "dead": out_dead,
        "observe_only": observe_only,
        "reconcile_cycle": reconcile_cycle,
        # SESSION-HANDOFF-01: bounded <supervisor-handoff> restore block —
        # "skipped_delta" on a --since call (never recomputed), a typed
        # {"status":"degraded",...} stub if the composer failed/timed out,
        # never a fabricated block. See leadv2-supervise-resume.sh.
        "resume": resume_obj,
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
