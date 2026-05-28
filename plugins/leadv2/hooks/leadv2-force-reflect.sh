#!/usr/bin/env bash
# Stop hook: force Phase 8 close (which contains lead-reflect) when a task reached
# substantive completion (verify/deploy) but the lead is ending the session without closing.
#
# WHY: lead-reflect is Step 2 of the leadv2-close skill — prose the lead routinely skips,
# so the self-learning loop never starts (synthesis-log empty all-time, 2026-05-29 diagnosis).
# The clean "closed" signal (phase8-passed.flag) is written by leadv2-phase8-assert.sh ONLY
# AFTER reflect (assert A4 requires the "<task_id> ✅" history line) — useless for forcing
# reflect. So we trigger on the PRE-close completion signal instead: a fresh verify*/deploy*
# artifact in the task handoff dir, with no close + no reflect yet.
#
# Bounded to ONE forced block per task (a .reflect-forced marker), never loops
# (honours stop_hook_active), and only fires on a recent completion artifact (<30 min) so
# old abandoned task dirs don't re-trigger.
set -euo pipefail
trap 'echo "[$(basename "$0")] error at line $LINENO" >&2; exit 0' ERR

INPUT="$(cat 2>/dev/null || true)"
CWD="$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || echo "")"
[[ -z "$CWD" ]] && CWD="$PWD"

STOP_ACTIVE="$(echo "$INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null || echo "false")"
[[ "$STOP_ACTIVE" == "true" ]] && exit 0

now=$(date +%s)
mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0; }

for base in "$CWD/docs/handoff" "$CWD/docs/leadv2/tasks"; do
  [[ -d "$base" ]] || continue
  for taskdir in "$base"/*/; do
    [[ -d "$taskdir" ]] || continue

    # Substantive completion reached? (verify ran, or deploy artifact present)
    comp=""
    for art in "$taskdir"verify*.md "$taskdir"deploy*.md "$taskdir"deploy*.yaml; do
      [[ -f "$art" ]] && { comp="$art"; break; }
    done
    [[ -z "$comp" ]] && continue

    # Only act on a RECENT completion (within 30 min) — avoid re-firing on stale task dirs.
    [[ $(( now - $(mtime "$comp") )) -ge 1800 ]] && continue

    # Close already completed for this task?
    { [[ -f "${taskdir}phase8-passed.flag" ]] || [[ -f "${taskdir}phase11-passed.flag" ]]; } && continue

    # Reflect already ran (lead-reflect touches this on completion)?
    [[ -f "${taskdir}reflect-done.flag" ]] && continue

    # Already forced once for this task — do not trap the session in repeated blocks.
    [[ -f "${taskdir}.reflect-forced" ]] && continue
    touch "${taskdir}.reflect-forced"

    cat <<'JSON'
{"decision":"block","reason":"A leadv2 task reached verify/deploy but Phase 8 close has not run, so lead-reflect (and the self-learning loop) is being skipped — this is the #1 reason synthesis never fires. Run Phase 8 close NOW before ending: invoke the leadv2-close skill, which writes the LEAD_V2_STATE history entry with a signature (phase + failure_class) and a falsifiable pattern_for_immune, runs the skill-synthesize cluster check, and finalizes the task. When the history entry is written, touch <task-dir>/reflect-done.flag so this does not fire again. If verify did NOT actually pass (task not really done), say so and continue — this block fires at most once per task."}
JSON
    exit 0
  done
done
exit 0
