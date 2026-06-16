#!/usr/bin/env bash
# leadv2-phase8-close.sh — Phase 8 close for /leadv2.
# Writes the closed-task YAML, calls render, then calls the gate (G2).
#
# Usage:
#   leadv2-phase8-close.sh <task_id>
#   LEADV2_TASK_ID=PO-XXX leadv2-phase8-close.sh
#
# Required env / args:
#   LEADV2_TASK_ID   (or first positional arg)
#
# Optional env (override values written into YAML):
#   LEADV2_TITLE           — task title (≤120 chars)
#   LEADV2_SUMMARY         — one-line summary for STATE.md history (≤120 chars)
#   LEADV2_CLASS           — Light|Standard|Heavy|Strategic  (default: Standard)
#   LEADV2_OUTCOME         — outcome enum (default: completed_success)
#   LEADV2_COMMIT          — short SHA or "no-deploy"        (default: auto from git)
#   LEADV2_VPS_DEPLOYED    — comma-separated list            (default: "")
#   LEADV2_ALSO_CLOSES     — comma-separated list            (default: "")
#   LEADV2_FOLLOWUPS       — newline-separated list          (default: "")
#   LEADV2_BOARD_PROSE     — multiline (default: minimal auto-generated)
#   LEADV2_DIALOGUE_PROSE  — multiline (default: minimal auto-generated)
#
# Exit codes:
#   0  success
#   1  missing required input or render/gate failure
#   3  fingerprint conflict (YAML exists with different content)

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJECT_ROOT"

SCRIPTS_DIR="${PROJECT_ROOT}/.claude/scripts"

log()       { printf -- '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }
log_info()  { log "INFO: $*"; }
log_error() { log "ERROR: $*"; }

# ── dependency check ──────────────────────────────────────────────────────────
if ! command -v python3 &>/dev/null; then
  log_error "python3 is required but not found"
  exit 1
fi

# ── required args ─────────────────────────────────────────────────────────────
TASK_ID="${1:-${LEADV2_TASK_ID:-}}"
if [[ -z "$TASK_ID" ]]; then
  log_error "task_id required (arg1 or LEADV2_TASK_ID env)"
  exit 1
fi

CLOSED_DIR="docs/leadv2/closed"
YAML_PATH="${CLOSED_DIR}/${TASK_ID}.yaml"
HANDOFF_DIR="docs/handoff/${TASK_ID}"

# ── gather YAML field values ───────────────────────────────────────────────────
CLOSED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
TITLE="${LEADV2_TITLE:-${TASK_ID}}"
SUMMARY="${LEADV2_SUMMARY:-${TASK_ID} closed}"
CLASS="${LEADV2_CLASS:-Standard}"
OUTCOME="${LEADV2_OUTCOME:-completed_success}"
VPS_DEPLOYED="${LEADV2_VPS_DEPLOYED:-}"

# Auto-detect commit SHA from git if not provided
if [[ -n "${LEADV2_COMMIT:-}" ]]; then
  COMMIT="${LEADV2_COMMIT}"
else
  COMMIT="$(git rev-parse --short HEAD 2>/dev/null || printf -- 'no-deploy')"
fi

# Build files_touched from git diff against previous commit (best-effort)
FILES_TOUCHED_JSON="[]"
if [[ "$COMMIT" != "no-deploy" ]]; then
  files_raw="$(git diff --name-only HEAD~1 HEAD 2>/dev/null || true)"
  if [[ -n "$files_raw" ]]; then
    FILES_TOUCHED_JSON="$(printf -- '%s\n' "$files_raw" | python3 -c '
import sys, json
lines = [l.rstrip() for l in sys.stdin if l.strip()]
print(json.dumps(lines))
')"
  fi
fi

# Build vps_deployed list
VPS_JSON="[]"
if [[ -n "$VPS_DEPLOYED" ]]; then
  VPS_JSON="$(printf -- '%s' "$VPS_DEPLOYED" | python3 -c '
import sys, json
raw = sys.stdin.read().strip()
items = [x.strip() for x in raw.split(",") if x.strip()]
print(json.dumps(items))
')"
fi

# also_closes list
ALSO_CLOSES_JSON="[]"
if [[ -n "${LEADV2_ALSO_CLOSES:-}" ]]; then
  ALSO_CLOSES_JSON="$(printf -- '%s' "${LEADV2_ALSO_CLOSES}" | python3 -c '
import sys, json
raw = sys.stdin.read().strip()
items = [x.strip() for x in raw.split(",") if x.strip()]
print(json.dumps(items))
')"
fi

# followups list
FOLLOWUPS_JSON="[]"
if [[ -n "${LEADV2_FOLLOWUPS:-}" ]]; then
  FOLLOWUPS_JSON="$(printf -- '%s' "${LEADV2_FOLLOWUPS}" | python3 -c '
import sys, json
raw = sys.stdin.read().strip()
items = [x.strip() for x in raw.split("\n") if x.strip()]
print(json.dumps(items))
')"
fi

# Default prose fields if not provided
if [[ -z "${LEADV2_BOARD_PROSE:-}" ]]; then
  BOARD_PROSE="- **${TASK_ID} ✅ SHIPPED ${COMMIT}.** ${SUMMARY}"
else
  BOARD_PROSE="${LEADV2_BOARD_PROSE}"
fi

if [[ -z "${LEADV2_DIALOGUE_PROSE:-}" ]]; then
  DIALOGUE_PROSE="task_id: ${TASK_ID} | outcome: ${OUTCOME} | class: ${CLASS}
${SUMMARY}"
else
  DIALOGUE_PROSE="${LEADV2_DIALOGUE_PROSE}"
fi

# ── build candidate YAML content ───────────────────────────────────────────────
mkdir -p "$CLOSED_DIR" "$HANDOFF_DIR"

CANDIDATE_YAML="$(
  TASK_ID="$TASK_ID" \
  CLOSED_AT="$CLOSED_AT" \
  TITLE="$TITLE" \
  SUMMARY="$SUMMARY" \
  CLASS="$CLASS" \
  OUTCOME="$OUTCOME" \
  FILES_TOUCHED_JSON="$FILES_TOUCHED_JSON" \
  COMMIT="$COMMIT" \
  VPS_JSON="$VPS_JSON" \
  ALSO_CLOSES_JSON="$ALSO_CLOSES_JSON" \
  FOLLOWUPS_JSON="$FOLLOWUPS_JSON" \
  BOARD_PROSE="$BOARD_PROSE" \
  DIALOGUE_PROSE="$DIALOGUE_PROSE" \
  python3 - <<'PYEOF'
import os, yaml, json

data = {
    "task_id":          os.environ["TASK_ID"],
    "closed_at":        os.environ["CLOSED_AT"],
    "title":            os.environ["TITLE"],
    "summary_one_line": os.environ["SUMMARY"],
    "class":            os.environ["CLASS"],
    "outcome":          os.environ["OUTCOME"],
    "files_touched":    json.loads(os.environ["FILES_TOUCHED_JSON"]),
    "commit":           os.environ["COMMIT"],
    "vps_deployed":     json.loads(os.environ["VPS_JSON"]),
    "also_closes":      json.loads(os.environ["ALSO_CLOSES_JSON"]),
    "followups":        json.loads(os.environ["FOLLOWUPS_JSON"]),
    "board_prose":      os.environ["BOARD_PROSE"],
    "dialogue_prose":   os.environ["DIALOGUE_PROSE"],
}
print(yaml.dump(data, default_flow_style=False, allow_unicode=True, sort_keys=True), end="")
PYEOF
)"

# ── fingerprint-check write ────────────────────────────────────────────────────
# Rules:
#   - YAML absent → write
#   - YAML present, same normalized sha256 → skip (idempotent)
#   - YAML present, different content → exit 3 with diff to stderr
write_yaml() {
  if [[ ! -f "$YAML_PATH" ]]; then
    printf -- '%s\n' "$CANDIDATE_YAML" > "$YAML_PATH"
    log_info "Wrote ${YAML_PATH}"
    return 0
  fi

  # Compare normalized sha256
  existing_hash="$(printf -- '%s\n' "$(cat "$YAML_PATH")" | python3 -c '
import sys, yaml, json, hashlib
content = sys.stdin.read()
data = yaml.safe_load(content)
normalized = json.dumps(data, sort_keys=True, ensure_ascii=False)
print(hashlib.sha256(normalized.encode()).hexdigest())
' 2>/dev/null || printf -- 'PARSE_ERROR')"

  new_hash="$(printf -- '%s\n' "$CANDIDATE_YAML" | python3 -c '
import sys, yaml, json, hashlib
content = sys.stdin.read()
data = yaml.safe_load(content)
normalized = json.dumps(data, sort_keys=True, ensure_ascii=False)
print(hashlib.sha256(normalized.encode()).hexdigest())
' 2>/dev/null || printf -- 'PARSE_ERROR')"

  if [[ "$existing_hash" == "$new_hash" ]]; then
    log_info "YAML unchanged (fingerprint match) — skipping write"
    return 0
  fi

  log_error "YAML fingerprint conflict for ${TASK_ID}:"
  diff <(cat "$YAML_PATH") <(printf -- '%s\n' "$CANDIDATE_YAML") >&2 || true
  log_error "Existing YAML differs from candidate. Delete ${YAML_PATH} to overwrite, or"
  log_error "set LEADV2_COMMIT / env vars so candidate matches existing content."
  exit 3
}

write_yaml

log_info "=== Phase 8 close — ${TASK_ID} ==="

# ── render: write board/state/dialogue/queue ───────────────────────────────────
log_info "Running render..."
if ! bash "${SCRIPTS_DIR}/leadv2-render-close.sh" "$TASK_ID"; then
  rc=$?
  log_error "Render failed (exit ${rc}) — aborting close"
  exit 1
fi

# ── gate (G2 — leadv2-phase8-assert.sh) ──────────────────────────────────────
# NOTE: leadv2-phase8-gate.sh (.claude/hooks/) is the PreToolUse push-blocker hook.
#       leadv2-phase8-assert.sh (.claude/scripts/) is the G2 assertion script.
ASSERT_SCRIPT="${SCRIPTS_DIR}/leadv2-phase8-assert.sh"
if [[ -x "$ASSERT_SCRIPT" ]]; then
  log_info "Running gate assertions (G2)..."
  if ! bash "$ASSERT_SCRIPT" "$TASK_ID"; then
    rc=$?
    log_error "Gate assertions failed (exit ${rc})"
    exit 1
  fi
else
  log_info "[skip] leadv2-phase8-assert.sh not yet present — skipping gate assertions"
fi

# ── Outcome-watch: schedule for Heavy/Standard tasks ─────────────────────────
# Deterministic shell dispatch — not prose the lead skips.
# Writes docs/leadv2/watches/<TASK_ID>.yaml; swept at every SessionStart by stale-sweeper.
OUTCOME_WATCH_SCRIPT="${SCRIPTS_DIR}/leadv2-outcome-watch.sh"
if [[ -x "$OUTCOME_WATCH_SCRIPT" ]]; then
  # C2.3/D1/D5: Heavy always; Standard only when LEADV2_SOAK_EVERY_DEPLOY=1.
  # --deploy-class drives delay_hours from soak-class-delays.yaml (D22) — no inline literal.
  case "${CLASS}" in
    Heavy)
      log_info "Scheduling outcome-watch for ${TASK_ID} class=Heavy (soak-class-delays.yaml delay)"
      LEADV2_PROJECT_ROOT="${PROJECT_ROOT}" bash "$OUTCOME_WATCH_SCRIPT" \
        --schedule --task-id "$TASK_ID" --deploy-class Heavy &
      ;;
    Standard)
      if [[ "${LEADV2_SOAK_EVERY_DEPLOY:-0}" == "1" ]]; then
        log_info "Scheduling outcome-watch for ${TASK_ID} class=Standard (LEADV2_SOAK_EVERY_DEPLOY=1)"
        LEADV2_PROJECT_ROOT="${PROJECT_ROOT}" bash "$OUTCOME_WATCH_SCRIPT" \
          --schedule --task-id "$TASK_ID" --deploy-class Standard &
      else
        log_info "[skip] outcome-watch not scheduled for class=Standard (LEADV2_SOAK_EVERY_DEPLOY not set)"
      fi
      ;;
    *)
      log_info "[skip] outcome-watch not scheduled for class=${CLASS} (Heavy/Standard only)"
      ;;
  esac
else
  log_info "[skip] leadv2-outcome-watch.sh not found — outcome-watch not scheduled"
fi

# ── Causal analysis: RECOVERY-* tasks only ───────────────────────────────────
# Runs automatically when task id starts with RECOVERY-. Non-blocking: causal
# lookup failure never gates close. Output (causal.yaml) written to handoff dir.
if [[ "$TASK_ID" == RECOVERY-* ]]; then
  CAUSAL_SCRIPT="${SCRIPTS_DIR}/leadv2-causal-analyze.sh"
  if [[ -x "$CAUSAL_SCRIPT" ]]; then
    log_info "RECOVERY task detected — running causal analysis for ${TASK_ID}"
    CAUSAL_OUT="${HANDOFF_DIR}/causal.yaml"
    causal_block=""
    # Run with a 90s wall-clock guard so a slow repo never stalls close
    if causal_block=$(timeout 90 bash "$CAUSAL_SCRIPT" --regression-task "$TASK_ID" 2>/dev/null); then
      log_info "Causal analysis complete (exit 0 — cause found)"
    else
      rc=$?
      if [[ $rc -eq 1 ]]; then
        log_info "Causal analysis complete (exit 1 — cause_unknown; log entry written)"
      else
        log_warn "Causal analysis returned exit ${rc} — writing partial output if available"
      fi
    fi
    # Write caused_by block to handoff dir regardless of exit code
    if [[ -n "$causal_block" ]]; then
      printf -- '%s\n' "$causal_block" > "$CAUSAL_OUT"
      log_info "Causal output written to ${CAUSAL_OUT}"
    else
      log_info "[skip] causal analysis produced no stdout block (check leadv2-causal-log.yaml)"
    fi
  else
    log_info "[skip] leadv2-causal-analyze.sh not found or not executable — skipping causal analysis"
  fi
else
  log_info "[skip] causal analysis not applicable (task_id=${TASK_ID} does not start with RECOVERY-)"
fi

# ── Scorecard: non-blocking write on close ────────────────────────────────────
# Gated by LEADV2_SCORECARD_ON_CLOSE=1. Failures log to stderr but never abort close.
if [[ "${LEADV2_SCORECARD_ON_CLOSE:-0}" == "1" ]]; then
  SCORECARD_WRITE_SCRIPT="${SCRIPTS_DIR}/leadv2-scorecard-write.sh"
  COST_FLUSH_SCRIPT="${SCRIPTS_DIR}/leadv2-cost-flush.sh"
  if [[ -x "$COST_FLUSH_SCRIPT" ]]; then
    log_info "Flushing cost markers for ${TASK_ID}..."
    LEADV2_PROJECT_ROOT="${PROJECT_ROOT}" bash "$COST_FLUSH_SCRIPT" "${HANDOFF_DIR}"       || log_error "[scorecard] cost-flush failed — continuing (non-blocking)"
  else
    log_info "[skip] leadv2-cost-flush.sh not found — skipping cost flush"
  fi
  if [[ -x "$SCORECARD_WRITE_SCRIPT" ]]; then
    log_info "Writing scorecard row for ${TASK_ID}..."
    LEADV2_PROJECT_ROOT="${PROJECT_ROOT}" bash "$SCORECARD_WRITE_SCRIPT" --task-id "$TASK_ID"       || log_error "[scorecard] scorecard-write failed — continuing (non-blocking)"
  else
    log_info "[skip] leadv2-scorecard-write.sh not found — skipping scorecard write"
  fi
else
  log_info "[skip] scorecard write skipped (LEADV2_SCORECARD_ON_CLOSE not set)"
fi

# ── Memory GC: weekly report-only pass ───────────────────────────────────────
# Runs in report-only mode; never blocks close. Fires at most once per 7 days.
MEMORY_GC_SCRIPT="${SCRIPTS_DIR}/leadv2-memory-gc.sh"
MEMORY_GC_STAMP="${PROJECT_ROOT}/docs/leadv2/.memory-gc-last"
if [[ -x "$MEMORY_GC_SCRIPT" ]]; then
  _gc_now=$(date +%s 2>/dev/null || echo 0)
  _gc_last=$(cat "$MEMORY_GC_STAMP" 2>/dev/null || echo 0)
  _gc_age=$(( _gc_now - _gc_last ))
  if [[ $_gc_age -ge 604800 ]]; then
    LEADV2_PROJECT_ROOT="${PROJECT_ROOT}" bash "$MEMORY_GC_SCRIPT" \
      --project-root "${PROJECT_ROOT}" || true
    echo "memory-gc: report refreshed (weekly)"
  else
    log_info "[skip] memory-gc skipped (last run ${_gc_age}s ago, threshold 604800s)"
  fi
else
  log_info "[skip] leadv2-memory-gc.sh not found — memory-gc skipped"
fi
# ── end memory GC ─────────────────────────────────────────────────────────────

# ── [BANDIT-01] Non-blocking route-bandit update ─────────────────────────────
# Runs after scorecard step; failures never gate close. File-exists guard per design §sync-point.
# FIX-BANDIT-COST-01: removed trailing & — update must run AFTER scorecard write completes so
# cmd_update can find the scorecard row via grep. Background spawn caused a race where update
# ran before flock-protected append finished, saw no row, emitted update_result=skipped, and
# total_updates never incremented. Synchronous call is still non-blocking to close (|| true).
BANDIT_UPDATE_SCRIPT="${SCRIPTS_DIR}/leadv2-route-bandit.sh"
if [[ -x "$BANDIT_UPDATE_SCRIPT" ]]; then
  log_info "Running bandit reward update for ${TASK_ID}..."
  LEADV2_PROJECT_ROOT="${PROJECT_ROOT}" PROJECT_ROOT="${PROJECT_ROOT}" \
    timeout 30 bash "$BANDIT_UPDATE_SCRIPT" update \
    --task-id "$TASK_ID" || { log_error "[bandit] update failed — continuing (non-blocking)"; true; }
else
  log_info "[skip] leadv2-route-bandit.sh not found — bandit update skipped (BANDIT-01 Group A pending)"
fi
# ── end bandit update ─────────────────────────────────────────────────────────

# ── [R4] Learn trigger: every N closes drop a signal for leadv2-learn ────────
# Gated by LEADV2_LEARN_ON_CLOSE=1 (DEFAULT OFF).
# Counts lines in scorecard.jsonl; when count % N == 0 writes a trigger file
# that lead picks up at next session start. Non-blocking: never gates close.
# LEADV2_LEARN_EVERY_N tunes the interval (default 10).
if [[ "${LEADV2_LEARN_ON_CLOSE:-0}" == "1" ]]; then
  _learn_n="${LEADV2_LEARN_EVERY_N:-10}"
  # Use PROJECT_ROOT-relative path (phase8 always cd'd to PROJECT_ROOT above)
  _sc_file="${PROJECT_ROOT}/docs/leadv2/scorecard.jsonl"
  # Only trigger learn when scorecard is also enabled; stale line-counts from
  # prior sessions cannot be isolated when scorecard is disabled, so guard both.
  _close_count=0
  if [[ "${LEADV2_SCORECARD_ON_CLOSE:-0}" == "1" && -f "$_sc_file" ]]; then
    _close_count=$(wc -l < "$_sc_file" 2>/dev/null || echo 0)
    _close_count=$(( _close_count + 0 ))   # strip whitespace
  fi
  if [[ $_learn_n -gt 0 && $(( _close_count % _learn_n )) -eq 0 && $_close_count -gt 0 ]]; then
    _trigger_dir="${PROJECT_ROOT}/docs/leadv2"
    mkdir -p "$_trigger_dir"
    _trigger_file="${_trigger_dir}/.learn-trigger"
    # Read task_class from context.yaml; default to 'general' if absent.
    _task_class=$(python3 -c "
import yaml, pathlib
p = pathlib.Path('${PROJECT_ROOT}/docs/handoff/${TASK_ID}/context.yaml')
if p.exists():
    d = yaml.safe_load(p.read_text()) or {}
    print(d.get('task_class', 'general'))
else:
    print('general')
" 2>/dev/null || echo 'general')
    printf -- 'trigger_task_id: %s
trigger_close_count: %d
triggered_at: %s
trigger_task_class: %s
'       "$TASK_ID" "$_close_count" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$_task_class" > "$_trigger_file" 
    log_info "[learn-trigger] wrote ${_trigger_file} (close_count=${_close_count}, every_n=${_learn_n})"
  else
    log_info "[skip] learn-trigger not due (close_count=${_close_count} mod ${_learn_n} != 0, or LEADV2_LEARN_ON_CLOSE not triggering)"
  fi
else
  log_info "[skip] learn-trigger skipped (LEADV2_LEARN_ON_CLOSE not set)"
fi
# ── end learn trigger ─────────────────────────────────────────────────────────


# ── [SYS-DRAIN-FOLLOWUPS-AT-CLOSE-01] Followup drain warning ────────────────
# Grep handoff dir for followups*.md / decision items not yet in tasks.yaml or BOARD.
# Non-blocking: logs warnings, never aborts close. lean: no auto-promotion — upgrade when tasks API stable.
_drain_warn_count=0
if [[ -d "$HANDOFF_DIR" ]]; then
  _drain_py="${PROJECT_ROOT}/.claude/scripts/leadv2-drain-warn-check.py"
  while IFS= read -r _fu_file; do
    [[ -f "$_fu_file" ]] || continue
    while IFS= read -r _line; do
      [[ -z "$_line" ]] && continue
      _ref_found=0
      _key="$(python3 -c "import sys,re; s=sys.argv[1]; s=re.sub(r'^[-*!#\s]+','',s); print(s[:60])" "$_line" 2>/dev/null || true)"
      [[ -z "$_key" ]] && continue
      if [[ -f "${PROJECT_ROOT}/docs/tasks.yaml" ]]; then
        python3 "$_drain_py" check_tasks "${PROJECT_ROOT}/docs/tasks.yaml" "$_key" 2>/dev/null && _ref_found=1
      fi
      if [[ "$_ref_found" -eq 0 ]] && [[ -f "${PROJECT_ROOT}/docs/BOARD.md" ]]; then
        python3 "$_drain_py" check_board "${PROJECT_ROOT}/docs/BOARD.md" "$_key" 2>/dev/null && _ref_found=1
      fi
      if [[ "$_ref_found" -eq 0 ]]; then
        log_info "[DRAIN-WARN] Untracked followup in $(basename "$_fu_file"): $_line"
        _drain_warn_count=$(( _drain_warn_count + 1 ))
      fi
    done < <(python3 "$_drain_py" extract_items "$_fu_file" 2>/dev/null || true)
  done < <(find "$HANDOFF_DIR" -maxdepth 1 \( -name "followups*.md" -o -name "*followup*.md" \) 2>/dev/null || true)
fi
if [[ "$_drain_warn_count" -gt 0 ]]; then
  log_info "[DRAIN-WARN] ${_drain_warn_count} untracked followup item(s) in ${HANDOFF_DIR} — add to tasks.yaml or BOARD.md before closing."
else
  log_info "[drain-check] no untracked followup items in ${HANDOFF_DIR}"
fi
# ── end followup drain warning ────────────────────────────────────────────────

log_info "Phase 8 close complete for ${TASK_ID} (YAML: ${YAML_PATH})"
exit 0
