#!/usr/bin/env bash
# Stop hook: force Phase 8 close (which contains lead-reflect) when a task reached
# substantive completion (verify/deploy) but the lead is ending the session without closing.
#
# WHY: lead-reflect is Step 2 of the leadv2-close skill — prose the lead routinely skips,
# so the self-learning loop never starts (synthesis-log empty all-time, 2026-05-29 diagnosis).
# The clean "closed" signal (phase8-passed.flag) is written by leadv2-phase8-assert.sh ONLY
# AFTER reflect (assert A4 requires the "<task_id> ✅" history line) — useless for forcing
# reflect. So we trigger on the authoritative phase state from docs/leadv2/active.yaml.
#
# PHASE SIGNAL (active.yaml) — replaces the old mtime/artifact-glob approach:
#   Fire ONLY when a session's `phase` field is one of: deploy, verify, live_verify, close.
#   These map to the real phase strings written by leadv2_active_update_phase:
#     - deploy      -> after Phase 5 REVIEW passes   (leadv2-review/SKILL.md)
#     - verify      -> after Phase 6 DEPLOY completes (leadv2-deploy/SKILL.md)
#     - close       -> after Phase 7 LIVE VERIFY      (leadv2-verify/SKILL.md)
#     - live_verify -> alias used by some older tasks
#   Do NOT fire for: intake, classify, plan, build, review -- task not yet substantively complete.
#
# WHY MTIME WAS WRONG:
#   `git worktree` checkout resets every file's mtime to the current time. An unrelated stale
#   task's verify.md would look fresh (age < 30 min) after any worktree operation, causing this
#   hook to block early phases (Plan/Build) of a DIFFERENT active task. The mtime signal had
#   no binding to the current session's active task whatsoever.
#
# Bounded to ONE forced block per task (.reflect-forced marker), never loops
# (honours stop_hook_active), reads active.yaml for authoritative phase state.
set -euo pipefail
trap 'echo "[$(basename "$0")] error at line $LINENO" >&2; exit 0' ERR

INPUT="$(cat 2>/dev/null || true)"
CWD="$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || echo "")"
[[ -z "$CWD" ]] && CWD="$PWD"

STOP_ACTIVE="$(echo "$INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null || echo "false")"
[[ "$STOP_ACTIVE" == "true" ]] && exit 0

# Try primary path then fallback; first existing wins. If neither exists, exit 0.
ACTIVE_YAML=""
for _candidate in "$CWD/docs/leadv2/active.yaml" "$CWD/.claude/leadv2-tasks/active.yaml"; do
  if [[ -f "$_candidate" ]]; then
    ACTIVE_YAML="$_candidate"
    break
  fi
done
[[ -n "$ACTIVE_YAML" ]] || exit 0

# Parse active.yaml with python3 (pyyaml is a project dependency).
# For each session whose phase is in the trigger set, check flags and emit block if needed.
python3 - "$CWD" "$ACTIVE_YAML" <<'PYEOF'
import sys, os, json, yaml

cwd       = sys.argv[1]
yaml_path = sys.argv[2]

TRIGGER_PHASES = {"deploy", "verify", "live_verify", "close"}

try:
    with open(yaml_path, encoding="utf-8") as fh:
        data = yaml.safe_load(fh) or {}
except Exception:
    sys.exit(0)

sessions = data.get("sessions") or []

for sess in sessions:
    phase   = (sess.get("phase") or "").lower().strip()
    task_id = (sess.get("task_id") or "").strip()

    if phase not in TRIGGER_PHASES:
        continue
    if not task_id:
        continue

    # Resolve task directory (handoff dir preferred; fallback to leadv2/tasks).
    handoff_dir = os.path.join(cwd, "docs", "handoff", task_id)
    tasks_dir   = os.path.join(cwd, "docs", "leadv2", "tasks", task_id)
    if os.path.isdir(handoff_dir):
        taskdir = handoff_dir
    elif os.path.isdir(tasks_dir):
        taskdir = tasks_dir
    else:
        # Create handoff dir so marker files have a home.
        os.makedirs(handoff_dir, exist_ok=True)
        taskdir = handoff_dir

    # Skip if already properly closed.
    # reflect-done.flag: set by lead-reflect §5 after writing reflect-history.yaml entry.
    # phase8-passed.flag: written by phase8-assert ONLY after reflect-history.yaml entry
    #   exists (A4 hard check) — so it implies reflect ran.
    # phase11-passed.flag: alias for older tasks.
    # reflect-history.yaml entry: the authoritative structured signal — checked explicitly
    #   so we do NOT treat phase8-passed.flag alone as proof (it was previously written
    #   off the cosmetic board "✅" line via A4 checking LEAD_V2_STATE.md pattern only).
    closed = False

    # Check flag files first (fast path)
    for flag in ("reflect-done.flag", "phase11-passed.flag"):
        if os.path.isfile(os.path.join(taskdir, flag)):
            closed = True
            break

    # Check reflect-history.yaml for a structured entry (authoritative)
    if not closed:
        reflect_history = os.path.join(cwd, "docs", "leadv2", "reflect-history.yaml")
        if os.path.isfile(reflect_history):
            try:
                import yaml  # pyyaml is a project dependency
                with open(reflect_history, encoding="utf-8") as rh:
                    rdata = yaml.safe_load(rh) or {}
                entries = rdata.get("entries") or []
                if any(isinstance(e, dict) and e.get("task") == task_id for e in entries):
                    closed = True
            except Exception:
                pass  # parse failure → do not treat as closed, let block fire

    # phase8-passed.flag: now gated on reflect-history.yaml via A4 hard check,
    # so it IS a valid done signal — but only after the above checks to be safe.
    if not closed:
        if os.path.isfile(os.path.join(taskdir, "phase8-passed.flag")):
            closed = True

    if closed:
        continue

    # One-shot guard: block at most once per task.
    forced_marker = os.path.join(taskdir, ".reflect-forced")
    if os.path.isfile(forced_marker):
        continue

    # Touch the one-shot marker and emit the block.
    try:
        open(forced_marker, "a").close()
    except OSError:
        pass  # best-effort; still emit block

    # Write a stub reflect-history.yaml entry so leadv2-learn.js has data even
    # when the lead skips the full Phase 8 close skill.  The learn workflow reads
    # docs/leadv2/reflect-history.yaml entries[].{task,failure_class,pattern,lesson}.
    # This is the authoritative sink — without it, synthesis never fires (303 tasks,
    # 0 entries confirmed 2026-06-17).  Full close should overwrite with richer data.
    try:
        import datetime
        reflect_path = os.path.join(cwd, "docs", "leadv2", "reflect-history.yaml")
        os.makedirs(os.path.dirname(reflect_path), exist_ok=True)
        # Load existing file or initialise structure.
        existing = {}
        if os.path.isfile(reflect_path):
            try:
                with open(reflect_path, encoding="utf-8") as _rh:
                    existing = yaml.safe_load(_rh) or {}
            except Exception:
                existing = {}
        entries = existing.get("entries") or []
        # Idempotent: skip if this task already has an entry.
        if not any(isinstance(e, dict) and e.get("task") == task_id for e in entries):
            entries.append({
                "task": task_id,
                "phase": phase,
                "failure_class": "skipped_close",
                "pattern": f"task {task_id} reached {phase} phase but Phase 8 close was not invoked",
                "lesson": "Run leadv2-close skill at the end of every task to populate reflect-history",
                "written_by": "force-reflect-hook",
                "ts": datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
            })
            existing["entries"] = entries
            with open(reflect_path, "w", encoding="utf-8") as _wh:
                yaml.dump(existing, _wh, allow_unicode=True, default_flow_style=False)
    except Exception:
        pass  # never block on reflect write failure

    print(json.dumps({
        "decision": "block",
        "reason": (
            "A leadv2 task reached verify/deploy but Phase 8 close has not run, so "
            "lead-reflect (and the self-learning loop) is being skipped -- this is the "
            "#1 reason synthesis never fires. Run Phase 8 close NOW before ending: "
            "invoke the leadv2-close skill, which writes the LEAD_V2_STATE history entry "
            "with a signature (phase + failure_class) and a falsifiable pattern_for_immune, "
            "runs the skill-synthesize cluster check, and finalizes the task. When the "
            "history entry is written, touch <task-dir>/reflect-done.flag so this does "
            "not fire again. If verify did NOT actually pass (task not really done), say so "
            "and continue -- this block fires at most once per task."
        ),
    }))
    sys.exit(0)

sys.exit(0)
PYEOF
exit 0
