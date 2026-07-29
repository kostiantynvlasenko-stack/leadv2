#!/usr/bin/env bash
# leadv2-lane-heartbeat.sh — durable per-task heartbeat + uniform liveness (PULSE-01).
#
# PROBLEM (2026-07-29, jcode design import #2 — see memory
# reference-external-repos-evaluated-reject): liveness was GUESSED from a
# stream file's mtime. Both directions failed in one day: twice a live lane
# quiet-but-alive was announced dead; three Codex lanes reported
# status=completed having produced nothing (an exhausted provider still
# answers "done"). "Alive" and "did it do anything" were both guesses.
#
# FIX: a durable heartbeat field in the existing registry (docs/leadv2/
# active.yaml, via leadv2-active-registry.sh's new heartbeat/mark_finished
# ops) plus ONE reader that computes a verdict the SAME way for every arm
# (Codex app-server job, GLM job, local Sonnet subagent) — no ps/pgrep, no
# stream-mtime guessing. A crashed lane cannot write its own heartbeat, so
# staleness is ALWAYS the coordinator's read of heartbeat AGE, never a
# self-report. "I don't know" is representable as its own state
# (running_stale) instead of being folded into either extreme.
#
# VERDICT VOCABULARY (see resolve_verdict() below for the exact rules):
#   running        — heartbeat age <= threshold, no terminal report yet.
#   running_stale  — heartbeat age >  threshold, no terminal report yet.
#                    NOT dead — the honest "I don't know" state.
#   dead           — heartbeat stale AND a LOCAL pid is confirmed gone.
#                    Only reachable for arms that register a local pid
#                    (Sonnet); a Codex/GLM row with no pid never resolves to
#                    dead from this reader — running_stale is its ceiling.
#   completed      — terminal_status=completed AND evidence is non-empty.
#   finished_empty — terminal_status=completed but evidence is empty/absent,
#                    OR terminal_status=finished_empty explicitly. This is
#                    the fix for "provider says done, produced nothing."
#   failed / cancelled — passthrough of an explicit terminal report.
#
# SCOPE OF THIS PASS: the write side (heartbeat/mark_finished ops + this
# reader) is complete and arm-agnostic. Wiring every producer (the Sonnet
# EYES pulse.json hook, the Codex/GLM job-registry watchdog in
# leadv2-supervise-loop.sh) to call `beat`/`finish` on their own cadence is
# the natural next step, deliberately left as follow-up so this diff stays
# reviewable and one-step-revertible — see ROLLBACK below. `sync-from-pulse`
# gives any caller a ready-made bridge from the existing pulse.json artifact
# without touching that hook's <50ms/no-python3 hot-path budget.
#
# ROLLBACK: LEADV2_LANE_LIVENESS_LEGACY=1 makes any NEW caller of this
# script's `status` a no-op that defers entirely to the old inference (exit
# 3, prints nothing) — existing mtime-based callers (leadv2-supervise.sh's
# pulse_verdict) are untouched by this file and keep working exactly as
# before regardless of this flag.
#
# Shared plugin — nothing repo-specific. Per-repo variation via
# .claude/leadv2-overrides/ (none needed today).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LEADV2_PROJECT_ROOT="${LEADV2_PROJECT_ROOT:-${CLAUDE_PROJECT_DIR:-$PWD}}"

# shellcheck source=leadv2-active-registry.sh
source "${SCRIPT_DIR}/leadv2-active-registry.sh"

STALE_MIN="${LEADV2_HEARTBEAT_STALE_MIN:-25}"

_usage() {
  cat >&2 <<'EOF'
usage:
  leadv2-lane-heartbeat.sh beat   <task_id> [checkpoint]
  leadv2-lane-heartbeat.sh finish <task_id> <outcome> [--worktree <path>] [--evidence <json>]
  leadv2-lane-heartbeat.sh status <task_id> [--json]
  leadv2-lane-heartbeat.sh status --all [--json]

outcome: completed | finished_empty | failed | cancelled
EOF
}

cmd="${1:-}"; shift || true

case "$cmd" in
  beat)
    task_id="${1:?task_id required}"; shift || true
    checkpoint="${1:-}"
    leadv2_active_heartbeat "$task_id" "$checkpoint"
    ;;

  finish)
    task_id="${1:?task_id required}"; shift || true
    outcome="${1:?outcome required (completed|finished_empty|failed|cancelled)}"; shift || true
    worktree=""
    evidence_json=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --worktree) worktree="$2"; shift 2 ;;
        --evidence) evidence_json="$2"; shift 2 ;;
        *) echo "[lane-heartbeat] finish: unknown arg: $1" >&2; exit 2 ;;
      esac
    done
    if [[ -z "$evidence_json" ]]; then
      if [[ -n "$worktree" && -d "$worktree/.git" ]]; then
        # Evidence = an actual non-empty diff in the lane's own worktree.
        # git is arm-agnostic (works whether Codex, GLM, or Sonnet made the
        # change) — this is what makes the check uniform instead of
        # per-provider. Never trusts a bare self-reported "done".
        stat_out="$(git -C "$worktree" diff --stat HEAD 2>/dev/null || true)"
        lines="$(printf '%s' "$stat_out" | grep -c . || true)"
        if [[ "$lines" -gt 0 ]]; then
          evidence_json="$(printf '{"has_diff":true,"diff_stat_lines":%s,"source":"git diff --stat HEAD"}' "$lines")"
        else
          evidence_json='{"has_diff":false,"source":"git diff --stat HEAD"}'
        fi
      else
        evidence_json='{}'
      fi
    fi
    leadv2_active_mark_finished "$task_id" "$outcome" "$evidence_json"
    ;;

  status)
    json_mode=0
    all_mode=0
    task_id=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --json) json_mode=1; shift ;;
        --all) all_mode=1; shift ;;
        *) task_id="$1"; shift ;;
      esac
    done
    if [[ "${LEADV2_LANE_LIVENESS_LEGACY:-0}" == "1" ]]; then
      echo "[lane-heartbeat] LEADV2_LANE_LIVENESS_LEGACY=1 — this reader is disabled; use the pre-PULSE-01 mtime inference" >&2
      exit 3
    fi
    if [[ "$all_mode" -eq 0 && -z "$task_id" ]]; then
      _usage; exit 2
    fi
    yaml_file="$(_leadv2_yaml_file)"
    python3 - "$yaml_file" "$task_id" "$all_mode" "$json_mode" "$STALE_MIN" <<'PYEOF'
import sys, os, json, datetime
try:
    import yaml
except ImportError:
    print("[lane-heartbeat] PyYAML not found", file=sys.stderr); sys.exit(1)

yaml_file, task_id, all_mode, json_mode, stale_min_s = sys.argv[1:6]
all_mode = all_mode == "1"
json_mode = json_mode == "1"
stale_min = float(stale_min_s)

def parse_iso(s):
    if not s:
        return None
    try:
        s2 = str(s).rstrip("Z")
        dt = datetime.datetime.fromisoformat(s2)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=datetime.timezone.utc)
        return dt
    except Exception:
        return None

def pid_confirmed_dead(pid_val):
    """True only when a LOCAL pid is present AND kill(pid, 0) fails. This is
    the ONLY place a pid is consulted — never a ps/pgrep scan (that trap is
    what produced false verdicts before: ps output differs in shape across
    arms, and a Codex/GLM job never HAS a local pid to check)."""
    if pid_val is None:
        return False
    try:
        os.kill(int(pid_val), 0)
        return False
    except (TypeError, ValueError, ProcessLookupError, PermissionError):
        return True

def resolve_verdict(row, now):
    """Pure function: registry row -> (status, reason). No I/O, no ps calls
    beyond kill(pid, 0) — everything else comes from the row itself, so the
    exact same code path answers for a Codex row and a Sonnet row."""
    term = row.get("terminal_status")
    if term:
        evidence = row.get("terminal_evidence") or {}
        has_evidence = bool(
            evidence.get("has_diff")
            or evidence.get("non_empty")
            or evidence.get("commit_sha")
            or evidence.get("diff_stat_lines")
        )
        if term == "completed":
            if has_evidence:
                return ("completed", f"terminal_status=completed, evidence={evidence}")
            return ("finished_empty",
                     f"terminal_status=completed but evidence is empty ({evidence}) — "
                     f"downgraded: a provider reporting done proves nothing by itself")
        if term == "finished_empty":
            return ("finished_empty", "terminal_status=finished_empty (explicit)")
        if term in ("failed", "cancelled"):
            return (term, f"terminal_status={term}")
        return (term, f"terminal_status={term} (unrecognized value, passthrough)")

    # No terminal report -> still running per the registry. Heartbeat AGE is
    # the only staleness signal; a crashed lane cannot write its own
    # heartbeat, so this is always the COORDINATOR's read, never a self-report.
    hb_raw = row.get("last_pulse_at") or row.get("started_at")
    ref = parse_iso(hb_raw)
    if ref is None:
        return ("running_stale", f"no parseable heartbeat/started_at on record ({hb_raw!r})")

    age_min = (now - ref).total_seconds() / 60.0
    if age_min <= stale_min:
        return ("running", f"heartbeat age {age_min:.1f}m <= {stale_min:.0f}m threshold")

    # Past threshold: this is "I don't know", not "dead" -- UNLESS a local
    # pid is present and confirmed gone. Arms with no local pid (Codex/GLM
    # app-server jobs) can never reach "dead" through this function; their
    # ceiling is running_stale, which is the correct, honest answer.
    pid = row.get("pid")
    if pid_confirmed_dead(pid):
        return ("dead", f"heartbeat age {age_min:.1f}m > {stale_min:.0f}m AND pid={pid} confirmed gone (kill -0 failed)")
    pid_note = f"pid={pid} still alive" if pid is not None else "no local pid to confirm (non-local arm)"
    return ("running_stale", f"heartbeat age {age_min:.1f}m > {stale_min:.0f}m threshold, {pid_note}")

if not os.path.isfile(yaml_file):
    print(json.dumps({"error": "registry_error", "message": f"active.yaml not found at {yaml_file}"}))
    sys.exit(1)
with open(yaml_file, encoding="utf-8") as fh:
    data = yaml.safe_load(fh) or {}
sessions = data.get("sessions") or []

now = datetime.datetime.now(datetime.timezone.utc)
rows = sessions if all_mode else [s for s in sessions if s.get("task_id") == task_id]
if not all_mode and not rows:
    print(json.dumps({"error": "not_found", "message": f"task_id {task_id} not in active.yaml"}))
    sys.exit(4)

results = []
for s in rows:
    status, reason = resolve_verdict(s, now)
    results.append({"task_id": s.get("task_id"), "status": status, "reason": reason,
                     "backend": s.get("backend", "?"), "pid": s.get("pid")})

if json_mode:
    print(json.dumps(results if all_mode else results[0], indent=2))
else:
    for r in results:
        print(f"{r['task_id']}\t{r['status']}\t{r['reason']}")
PYEOF
    ;;

  sync-from-pulse)
    # Bridge for the existing per-tool-call pulse.json artifact (Sonnet arm
    # only) into the durable registry heartbeat, at whatever cadence the
    # CALLER chooses (e.g. once per supervise-loop tick) -- never per tool
    # call, so leadv2-pulse-json.sh's hot-path budget is untouched.
    task_id="${1:?task_id required}"
    pulse_file="${LEADV2_PROJECT_ROOT}/docs/handoff/${task_id}/pulse.json"
    if [[ ! -f "$pulse_file" ]]; then
      echo "[lane-heartbeat] sync-from-pulse: no pulse.json for ${task_id} at ${pulse_file}" >&2
      exit 5
    fi
    checkpoint="$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(f\"{d.get('tool','?')}@{d.get('phase','?')}\")" "$pulse_file" 2>/dev/null || echo "?")"
    leadv2_active_heartbeat "$task_id" "$checkpoint"
    ;;

  *)
    _usage
    exit 2
    ;;
esac
