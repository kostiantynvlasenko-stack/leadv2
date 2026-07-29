#!/usr/bin/env bash
# leadv2-phase8-assert.sh — Phase 8 gate assertions for /leadv2.
# Run by leadv2-phase8-close.sh after render; also callable standalone.
#
# Usage:
#   leadv2-phase8-assert.sh <task_id>
#   LEADV2_TASK_ID=PO-XXX leadv2-phase8-assert.sh
#
# Hard checks (all must pass — exit 1 on any failure):
#   A1  docs/leadv2/closed/<task_id>.yaml  exists
#   A2  docs/tasks.yaml (or lane yamls fallback) has terminal status for task_id
#   A3  docs/leadv2/active.yaml  does NOT contain task_id
#   A4  docs/LEAD_V2_STATE.md  history mentions "<task_id> ✅"
#   A6  docs/handoff/<task_id>/merge-blocker.flag  does NOT exist (RISK-7-PERSIST-MERGE-RACE-01:
#       Phase 6 (leadv2-deploy-merge.sh) writes this on any merge-failure exit; a lying-green
#       close otherwise proceeds even though the ff-only merge/deploy never actually landed)
#   A7  docs/handoff/<task_id>/e2e-gate-passed.flag exists and is <1h old
#       (project E2E gate run by leadv2-phase8-e2e-gate.sh — E2E-INTO-DEV-LOOP-01)
#   A8  deploy-class tasks (task_class: deploy) must have a passing
#       deploy-verify artifact (DEPLOY-CLASS-VERIFY-GATE-01). N/A for
#       non-deploy tasks (leadv2-deploy-verify-check.sh rc=3); never a hard
#       failure when the check script itself is not yet vendored here.
#
# Best-effort warnings (log_warning + continue; never exit 1):
#   W1  docs/BOARD.md HEAD section has today's date AND task_id
#   W2  docs/agents/product-owner/DIALOGUE.md  has an entry for task_id
#   W3  docs/leadv2/tasks/<task_id>/STATE.md  has "status: closed"
#   W4  docs/agents/product-owner/QUEUE.md  has "[x]" line for task_id
#
# Exit codes:
#   0   all HARD assertions PASS — writes the worktree-local sentinel and a
#       shared control-plane completion receipt visible from every worktree
#   1   one or more HARD assertions FAILED — prints missing-item list to stderr
#   2   bad usage (missing task_id arg)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${CLAUDE_PROJECT_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
export LEADV2_PROJECT_ROOT="${LEADV2_PROJECT_ROOT:-${PROJECT_ROOT}}"
cd "$PROJECT_ROOT"

# shellcheck source=leadv2-helpers.sh
source "${SCRIPT_DIR}/leadv2-helpers.sh"
_lv2_load_paths

log()         { printf -- '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }
log_info()    { log "INFO: $*"; }
log_error()   { log "ERROR: $*"; }
log_pass()    { log "PASS: $*"; }
log_fail()    { log "FAIL: $*"; }
log_warning() { log "WARN: $*"; }

# ── argument parsing ──────────────────────────────────────────────────────────
TASK_ID="${1:-${LEADV2_TASK_ID:-}}"
if [[ -z "$TASK_ID" ]]; then
  log_error "task_id required (arg1 or LEADV2_TASK_ID env)"
  exit 2
fi

# Hard failures accumulate here; warnings do not.
# MUST be declared before the FIRST check that appends to it. It used to sit
# below A7/A8 (~line 158), so every A7/A8 hard failure was silently erased
# before the verdict was computed: a task with a missing E2E sentinel or a
# failed deploy-verify still closed GREEN. That is the hollow-close mechanism
# this gate exists to kill (ASSERT-FAILURES-ERASED-01, 2026-07-27).
failures=()

# ── A7: E2E gate sentinel exists and is fresh (E2E-INTO-DEV-LOOP-01) ─────────
E2E_SENTINEL="${LEADV2_HANDOFF_DIR}/${TASK_ID}/e2e-gate-passed.flag"
if [[ -f "$E2E_SENTINEL" ]]; then
  now=$(date +%s)
  mtime=$(stat -f %m "$E2E_SENTINEL" 2>/dev/null || stat -c %Y "$E2E_SENTINEL" 2>/dev/null || echo 0)
  age=$(( now - mtime ))
  if (( age > 3600 )); then
    log_fail "A7 E2E gate sentinel stale (${age}s > 1h): ${E2E_SENTINEL}"
    failures+=("A7: ${E2E_SENTINEL} is ${age}s old (>1h) -- re-run: bash ${SCRIPT_DIR}/leadv2-phase8-e2e-gate.sh ${TASK_ID}")
  else
    log_pass "A7 E2E gate: sentinel fresh (${age}s old)"
  fi
else
  log_fail "A7 E2E gate sentinel missing: ${E2E_SENTINEL}"
  failures+=("A7: ${E2E_SENTINEL} not found -- run: bash ${SCRIPT_DIR}/leadv2-phase8-e2e-gate.sh ${TASK_ID}")
fi

# ── A8: deploy-verify artifact required for deploy-class tasks ──────────────
# (DEPLOY-CLASS-VERIFY-GATE-01) Shells out to leadv2-deploy-verify-check.sh:
#   rc 0 -> PASS (deploy verified, or legitimately bypassed with a reason)
#   rc 3 -> N/A (task classified `code`, not `deploy`) -- not counted as failure
#   rc 1/2 -> FAIL -- deploy-class task closing without a machine-checkable
#             deploy-verify artifact (the OUTBOX-DEPLOY-UNBLOCK-01 hollow-close
#             this task exists to fix)
# Missing check script (not yet vendored in this repo) -> WARNING, never a
# hard failure: a repo without the propagated files must not false-RED every
# non-deploy task in the meantime.
A8_CHECK="${SCRIPT_DIR}/leadv2-deploy-verify-check.sh"
CLASSIFIER="${SCRIPT_DIR}/leadv2-deploy-classify.sh"
# A8_EVALUATED: 1 iff the check script is non-empty AND ran (incl. N/A rc=3 --
# N/A is a legitimate evaluated result, not "unevaluated"). 0 only when the
# script is absent or 0-byte (M2: the N/8 receipt must not count a
# warn-skipped A8 as verified).
A8_EVALUATED=0
if [[ -f "$A8_CHECK" && -s "$A8_CHECK" ]]; then
  a8_out=""
  a8_rc=0
  # shellcheck disable=SC2097,SC2098  # intentional: scopes env vars to the forked
  # bash "$A8_CHECK" child process only, not the current shell -- correct here.
  a8_out=$(PROJECT_ROOT="$LEADV2_PROJECT_ROOT" LEADV2_PROJECT_ROOT="$LEADV2_PROJECT_ROOT" bash "$A8_CHECK" "$TASK_ID" 2>&1) || a8_rc=$?
  case "$a8_rc" in
    0)
      # critic2 #4: a 0-byte/truncated check script running as `bash <empty>`
      # also exits 0 -- require the real PASS:/WARN: prefix so a corrupted
      # script that happens to exit 0 is caught, not silently logged PASS.
      if [[ "$a8_out" == PASS:* || "$a8_out" == WARN:* ]]; then
        log_pass "A8 deploy-verify: ${a8_out}"
      else
        log_fail "A8 deploy-verify: suspect truncated/corrupted check script (rc=0, unexpected output: ${a8_out})"
        failures+=("A8: ${A8_CHECK} exited 0 with unrecognized output (suspect truncated/corrupted) -- ${a8_out}")
      fi
      A8_EVALUATED=1
      ;;
    3)
      log_info "A8 N/A (non-deploy): ${a8_out}"
      A8_EVALUATED=1
      ;;
    *)
      log_fail "A8 deploy-verify: ${a8_out}"
      failures+=("A8: deploy-verify check failed (exit ${a8_rc}) -- ${a8_out} -- run: bash ${SCRIPT_DIR}/leadv2-deploy-verify-check.sh ${TASK_ID}")
      A8_EVALUATED=1
      ;;
  esac
else
  # critic2 #4: missing/empty check script must gate on classification,
  # mirroring D6 (leadv2-phase8-e2e-gate.sh) -- warn-only is correct for a
  # non-deploy task (repo not yet vendored with the check script), but a
  # deploy-class task closing with NO deploy-verify check script at all is
  # exactly the hollow-close this task exists to kill and must hard-fail.
  A8_CLASS="code"
  if [[ -f "$CLASSIFIER" ]]; then
    A8_CLASS="$(bash "$CLASSIFIER" "$TASK_ID" 2>/dev/null || echo code)"
  fi
  if [[ "$A8_CLASS" == "deploy" ]]; then
    log_fail "A8 deploy-verify check script missing/empty for deploy-class task: ${A8_CHECK}"
    failures+=("A8: ${A8_CHECK} missing or 0-byte for deploy-class task ${TASK_ID} -- vendor leadv2-deploy-verify-check.sh before closing")
  else
    log_warning "A8 deploy-verify check script not found: ${A8_CHECK} -- non-blocking (not yet vendored in this repo, task not deploy-class)"
  fi
fi

# ── file paths ────────────────────────────────────────────────────────────────
CLOSED_YAML="${LEADV2_LEADV2_DIR}/closed/${TASK_ID}.yaml"
TASK_STATE="${LEADV2_LEADV2_DIR}/tasks/${TASK_ID}/STATE.md"
ACTIVE_YAML="${LEADV2_LEADV2_DIR}/active.yaml"
STATE_FILE="${LEADV2_LEAD_STATE_PATH}"
BOARD_FILE="${LEADV2_BOARD_PATH}"
DIALOGUE_FILE="${LEADV2_DIALOGUE_PATH}"
QUEUE_FILE="${LEADV2_QUEUE_PATH}"
TASKS_YAML="${LEADV2_PROJECT_ROOT}/docs/tasks.yaml"
QUEUE_DIR="${LEADV2_PROJECT_ROOT}/docs/agents/product-owner/queue"
SENTINEL="${LEADV2_HANDOFF_DIR}/${TASK_ID}/phase8-passed.flag"
REFLECT_HISTORY="${LEADV2_PROJECT_ROOT}/docs/leadv2/reflect-history.yaml"

TODAY="$(date '+%Y-%m-%d')"

# ── A1: closed YAML exists ────────────────────────────────────────────────────
if [[ -f "$CLOSED_YAML" ]]; then
  log_pass "A1 closed YAML: ${CLOSED_YAML}"
else
  log_fail "A1 closed YAML missing: ${CLOSED_YAML}"
  failures+=("A1: ${CLOSED_YAML} not found — run leadv2-phase8-close.sh first")
fi

# ── A2: tasks.yaml (or lane yamls fallback) has terminal status for task_id ───
# Bridge mode: prefer tasks.yaml when present; else read lane yamls directly.
#
# CLOSE-GATE-A2-STORE-YAML-IMPEDANCE-01 (D-VOCAB): verified_closed is terminal
# in the authoritative store (e.g. persona-engine's Supabase work_items, via
# scripts/task-sync-yaml.sh) but was missing here -- plain bug, now fixed.
# claimed_done/needs_evidence are the store's deliberate "work is done, an
# acceptance probe is pending" states -- these are LANE-TERMINAL, not plain
# terminal: A2 passes them ONLY when BOTH a release receipt (the sentinel
# leadv2_tasks_release writes) AND this task's own phase-8 evidence artifact
# ($SENTINEL, i.e. phase8-passed.flag) exist on disk -- proof the lane
# actually finished the work, not merely that the store reached one of these
# statuses by some other path. queued/pending/in_progress/unknown status
# still FAIL -- this must never become "always pass".
# fix-round-1 Finding 3: derived from the single shared source
# (leadv2_tasks_yaml_common.py) instead of a hardcoded literal, so drift
# there (e.g. a status added/removed) propagates here automatically instead
# of creating a 4th silently-stale copy. Literal fallback below only fires
# if the shared module can't be imported at all (e.g. corrupted install) --
# kept identical to the shared constant so behavior is unchanged either way.
## NOTE: these two derivation blocks deliberately avoid a bare `import sys`
## first line (test-leadv2-phase8-assert-a2-schema.sh's _extract_a2_python
## greps for the literal `^import sys$` to locate the REAL A2 heredoc below
## -- a bare `import sys` here would false-match and corrupt the extraction).
TERMINAL_STATUSES="$(python3 -c '
import sys; sys.path.insert(0, sys.argv[1])
try:
    from leadv2_tasks_yaml_common import TERMINAL_STATUSES
    print(TERMINAL_STATUSES)
except Exception:
    pass
' "$SCRIPT_DIR" 2>/dev/null)"
TERMINAL_STATUSES="${TERMINAL_STATUSES:-done|poisoned|rejected|failed|archived|closed|completed|admin-closed|verified_closed}"
LANE_TERMINAL_STATUSES="$(python3 -c '
import sys; sys.path.insert(0, sys.argv[1])
try:
    from leadv2_tasks_yaml_common import LANE_TERMINAL_STATUSES
    print(LANE_TERMINAL_STATUSES)
except Exception:
    pass
' "$SCRIPT_DIR" 2>/dev/null)"
LANE_TERMINAL_STATUSES="${LANE_TERMINAL_STATUSES:-claimed_done|needs_evidence}"
RELEASE_RECEIPT="${LEADV2_LEADV2_DIR}/closed/.tasks-sentinel-${TASK_ID}.yaml"
if [[ -f "$TASKS_YAML" ]]; then
  if python3 - "$TASK_ID" "$TASKS_YAML" "$TERMINAL_STATUSES" "$LANE_TERMINAL_STATUSES" "$SCRIPT_DIR" <<'PYEOF' 2>/dev/null
import sys
task_id, path, terminals_raw, lane_terminal_raw, scripts_dir = sys.argv[1:6]
terminals = set(terminals_raw.split("|"))
lane_terminal = set(lane_terminal_raw.split("|")) if lane_terminal_raw else set()
sys.path.insert(0, scripts_dir)
from leadv2_tasks_yaml_common import load_tasks_items
items = load_tasks_items(path)
for it in items:
    if isinstance(it, dict) and str(it.get("id","")) == task_id:
        st = it.get("status","")
        if st in terminals:
            sys.exit(0)
        if st in lane_terminal:
            sys.exit(3)
        sys.exit(1)
# Not found in tasks.yaml — check lane yamls as fallback
sys.exit(2)
PYEOF
  then
    log_pass "A2 tasks.yaml: ${TASK_ID} has terminal status"
  else
    rc=$?
    if [[ $rc -eq 3 ]]; then
      # fix-round-1 Finding 1 (poison receipt): -f existence alone is not
      # proof of a successful release -- write_closed_sentinel() also fires
      # on outcome=poison and is write-once (never refreshed), so a task
      # poisoned once and later reaching claimed_done/needs_evidence by some
      # other path would PASS on a receipt that literally says
      # `outcome: poison`. Parse the receipt and require the outcome field
      # to be a success outcome (completed_success, the value
      # write_closed_sentinel() writes for outcome=="success") in addition
      # to both files existing.
      receipt_outcome=""
      if [[ -f "$RELEASE_RECEIPT" ]]; then
        receipt_outcome="$(python3 -c '
import sys, yaml
try:
    d = yaml.safe_load(open(sys.argv[1], encoding="utf-8")) or {}
except Exception:
    d = {}
print(str(d.get("outcome") or ""))
' "$RELEASE_RECEIPT" 2>/dev/null)"
      fi
      if [[ -f "$SENTINEL" && "$receipt_outcome" == "completed_success" ]]; then
        log_pass "A2 PASS (lane-terminal, acceptance evidence pending): ${TASK_ID} status is claimed_done/needs_evidence, release receipt (outcome: completed_success) + phase-8 evidence both present"
      else
        log_fail "A2 tasks.yaml: ${TASK_ID} is lane-terminal (claimed_done/needs_evidence) but missing release receipt with outcome=completed_success and/or phase-8 evidence artifact (receipt outcome: '${receipt_outcome:-<missing>}')"
        failures+=("A2: ${TASK_ID} status is claimed_done/needs_evidence -- lane-terminal requires BOTH ${RELEASE_RECEIPT} with outcome: completed_success AND ${SENTINEL} to exist (got outcome='${receipt_outcome:-<missing>}'); run leadv2_tasks_release then leadv2-phase8-e2e-gate.sh")
      fi
    elif [[ $rc -eq 2 ]]; then
      log_fail "A2 tasks.yaml: ${TASK_ID} not found — task not in tasks.yaml"
      failures+=("A2: ${TASK_ID} not found in ${TASKS_YAML} — run leadv2_tasks_release or ensure tasks.yaml is populated")
    else
      log_fail "A2 tasks.yaml: ${TASK_ID} status is not terminal"
      failures+=("A2: ${TASK_ID} in ${TASKS_YAML} does not have terminal status (${TERMINAL_STATUSES}) — run queue-release")
    fi
  fi
else
  # Fallback: read lane yamls directly (pre-cutover)
  if python3 - "$TASK_ID" "$QUEUE_DIR" "$TERMINAL_STATUSES" <<'PYEOF' 2>/dev/null
import sys, os, yaml
task_id   = sys.argv[1]
qdir      = sys.argv[2]
terminals = set(sys.argv[3].split("|"))
for lane in ("action", "recovery", "intelligence", "human-needed"):
    f = os.path.join(qdir, f"{lane}.yaml")
    if not os.path.isfile(f): continue
    items = yaml.safe_load(open(f)) or []
    for it in (items if isinstance(items, list) else []):
        if isinstance(it, dict) and str(it.get("id","")) == task_id:
            sys.exit(0 if it.get("status","") in terminals else 1)
# Not found in any lane — treat as PASS (may be a manual-only task)
sys.exit(0)
PYEOF
  then
    log_pass "A2 lane yamls: ${TASK_ID} has terminal status (or not tracked)"
  else
    log_fail "A2 lane yamls: ${TASK_ID} not marked terminal in any lane yaml"
    failures+=("A2: ${TASK_ID} status not terminal in lane yamls — run leadv2-queue-release.sh")
  fi
fi

# ── A3: active.yaml does NOT contain task_id ─────────────────────────────────
# Simple grep-style check: task_id value appears under sessions block.
# We look for "task_id: <TASK_ID>" (YAML key-value pattern).
if [[ -f "$ACTIVE_YAML" ]]; then
  # Use python with args to avoid shell-quoting issues inside -c string
  if python3 - "$TASK_ID" "$ACTIVE_YAML" <<'PYEOF'
import sys, re
task_id = sys.argv[1]
path = sys.argv[2]
content = open(path).read()
# Match 'task_id: PO-XXX' inside sessions block (YAML pattern)
pattern = r'task_id\s*:\s*["\']?' + re.escape(task_id) + r'["\']?'
found = bool(re.search(pattern, content))
sys.exit(1 if found else 0)
PYEOF
  then
    log_pass "A3 active.yaml: ${TASK_ID} not present (unregistered)"
  else
    log_fail "A3 active.yaml still contains ${TASK_ID}"
    failures+=("A3: ${ACTIVE_YAML} still has ${TASK_ID} — run leadv2_active_unregister '${TASK_ID}'")
  fi
else
  log_pass "A3 active.yaml: file absent (treated as empty — no active sessions)"
fi

# ── A4: reflect-history.yaml has structured entry for task_id (real signal) ───
# Also accepts cosmetic board "✅" line as secondary signal, but the structured
# entry in reflect-history.yaml is required — it proves lead-reflect §5a ran
# and learning data was captured (not just a board cosmetic render).
A4_REFLECT_OK=0

# Primary: structured entry in reflect-history.yaml
if [[ -f "$REFLECT_HISTORY" ]]; then
  if python3 - "$TASK_ID" "$REFLECT_HISTORY" <<'PYEOF' 2>/dev/null
import sys, yaml
task_id = sys.argv[1]
path = sys.argv[2]
try:
    d = yaml.safe_load(open(path, encoding="utf-8")) or {}
except Exception:
    sys.exit(1)
entries = d.get("entries") or []
for e in entries:
    if isinstance(e, dict) and e.get("task") == task_id:
        sys.exit(0)
sys.exit(1)
PYEOF
  then
    A4_REFLECT_OK=1
    log_pass "A4 reflect-history.yaml: has structured entry for ${TASK_ID}"
  else
    log_fail "A4 reflect-history.yaml: NO entry for ${TASK_ID}"
  fi
else
  log_fail "A4 reflect-history.yaml not found: ${REFLECT_HISTORY}"
fi

# Secondary (cosmetic fallback check — kept for debugging but NOT sufficient alone)
if [[ -f "$STATE_FILE" ]]; then
  if python3 -c "
import sys, re
content = open('${STATE_FILE}').read()
if re.search(r'\b${TASK_ID}\s+✅', content):
    sys.exit(0)
sys.exit(1)
" 2>/dev/null; then
    log_pass "A4 LEAD_V2_STATE.md: board has ${TASK_ID} ✅ (cosmetic)"
  else
    log_warning "A4 LEAD_V2_STATE.md: missing '${TASK_ID} ✅' board line — non-blocking (reflect-history.yaml is authoritative)"
  fi
fi

# Hard assertion: structured reflect entry is REQUIRED
if [[ $A4_REFLECT_OK -eq 0 ]]; then
  failures+=("A4: docs/leadv2/reflect-history.yaml has no entry for ${TASK_ID} — run lead-reflect §5a to append structured entry (this is required; board ✅ line alone is insufficient)")
fi

# ── A5: closed YAML must NOT contain placeholder lie-language in live_signal/verification ──
# Hard-fails ONLY when live_signal/verification is PRESENT with placeholder deferral text.
# (case-insensitive: pending, verify-tonight, verify tonight, DO AFTER COMPACT, TODO verify)
# When field is simply ABSENT/empty -> WARNING only (non-blocking). Keeps anti-lying-green
# teeth without blocking 294/304 legacy closed YAMLs that lack the field entirely.
if [[ -f "$CLOSED_YAML" ]]; then
  # Use python3 -c with args to avoid heredoc; exit 0=ok 1=placeholder 2=absent/unparseable
  # Initialize before invocation so set -e abort cannot prevent capture.
  a5_rc=0
  python3 -c '
import sys, re, yaml
PLACEHOLDER_RE = re.compile(
    r"\bpending\b|verify[-\s]tonight|do\s+after\s+compact|todo\s+verify",
    re.IGNORECASE,
)
try:
    d = yaml.safe_load(open(sys.argv[2], encoding="utf-8")) or {}
except Exception:
    sys.exit(2)
value = (d.get("live_signal") or d.get("verification") or "").strip()
if not value: sys.exit(2)
sys.exit(1 if PLACEHOLDER_RE.search(value) else 0)
  '  "$TASK_ID" "$CLOSED_YAML" 2>/dev/null || a5_rc=$?
  case $a5_rc in
    0)
      log_pass "A5 closed YAML: live_signal/verification present and not a placeholder"
      ;;
    1)
      log_fail "A5 closed YAML: placeholder lie-language detected in ${CLOSED_YAML}"
      failures+=("A5: ${CLOSED_YAML} has placeholder lie-language (pending/TODO verify/etc.) -- replace with real evidence or remove the field")
      ;;
    *)
      log_warning "A5 closed YAML: live_signal/verification absent or empty -- non-blocking (set when evidence available)"
      ;;
  esac
else
  log_warning "A5 closed YAML not found (A1 would catch this): ${CLOSED_YAML} -- non-blocking"
fi

# ── A6: merge-blocker.flag must NOT exist (Phase 6 must have succeeded and cleared it) ────────
MERGE_BLOCKER="${LEADV2_HANDOFF_DIR}/${TASK_ID}/merge-blocker.flag"
if [[ -f "$MERGE_BLOCKER" ]]; then
  log_fail "A6 merge-blocker present: ${MERGE_BLOCKER}"
  failures+=("A6: merge-blocker present -- Phase 6 failed, never cleared -- re-run leadv2-deploy-merge.sh ${TASK_ID}, or rm -f ${MERGE_BLOCKER} if already resolved manually")
else
  log_pass "A6 merge-blocker: absent (Phase 6 clean)"
fi

# ── W1 (best-effort): BOARD.md HEAD has today's date AND task_id ─────────────
if [[ -f "$BOARD_FILE" ]]; then
  has_today=0
  has_taskid=0
  if python3 -c "
import sys, re
content = open('${BOARD_FILE}').read()[:4000]
if re.search(r'${TODAY}', content): sys.exit(0)
sys.exit(1)
" 2>/dev/null; then has_today=1; fi
  if python3 -c "
import sys, re
content = open('${BOARD_FILE}').read()[:4000]
if re.search(r'\b${TASK_ID}\b', content): sys.exit(0)
sys.exit(1)
" 2>/dev/null; then has_taskid=1; fi
  if [[ $has_today -eq 1 && $has_taskid -eq 1 ]]; then
    log_pass "W1 BOARD.md HEAD: has today (${TODAY}) and ${TASK_ID}"
  else
    log_warning "W1 BOARD.md HEAD: missing today=(${has_today}) or task_id=(${has_taskid}) — non-blocking"
  fi
else
  log_warning "W1 BOARD.md not found: ${BOARD_FILE} — non-blocking"
fi

# ── W2 (best-effort): DIALOGUE.md has entry for task_id ──────────────────────
if [[ -f "$DIALOGUE_FILE" ]]; then
  if python3 - "$TASK_ID" "$DIALOGUE_FILE" <<'PYEOF' 2>/dev/null
import sys, re
task_id = sys.argv[1]
content = open(sys.argv[2]).read()
sys.exit(0 if re.search(r'\b' + re.escape(task_id) + r'\b', content) else 1)
PYEOF
  then
    log_pass "W2 DIALOGUE.md: has entry for ${TASK_ID}"
  else
    log_warning "W2 DIALOGUE.md: no entry for ${TASK_ID} — non-blocking"
  fi
else
  log_warning "W2 DIALOGUE.md not found: ${DIALOGUE_FILE} — non-blocking"
fi

# ── W3 (best-effort): per-task STATE.md has status: closed ───────────────────
if [[ -f "$TASK_STATE" ]]; then
  if python3 -c "
import sys, re
content = open('${TASK_STATE}').read()
sys.exit(0 if re.search(r'status\s*:\s*closed', content) else 1)
" 2>/dev/null; then
    log_pass "W3 task STATE.md: status=closed"
  else
    log_warning "W3 task STATE.md: 'status: closed' not found in ${TASK_STATE} — non-blocking"
  fi
else
  log_warning "W3 task STATE.md missing: ${TASK_STATE} — non-blocking"
fi

# ── W4 (best-effort): QUEUE.md has [x] for task_id ───────────────────────────
if [[ -f "$QUEUE_FILE" ]]; then
  if python3 - "$TASK_ID" "$QUEUE_FILE" <<'PYEOF' 2>/dev/null
import sys, re
task_id = sys.argv[1]
content = open(sys.argv[2]).read()
sys.exit(0 if re.search(r'\[x\].*' + re.escape(task_id), content) else 1)
PYEOF
  then
    log_pass "W4 QUEUE.md: has [x] for ${TASK_ID}"
  else
    log_warning "W4 QUEUE.md: no [x] for ${TASK_ID} — non-blocking (QUEUE.md may be frozen redirect)"
  fi
else
  log_warning "W4 QUEUE.md not found: ${QUEUE_FILE} — non-blocking"
fi

# ── A9: lane-shape artifact set + retro shape check (LANE-SHAPE-01) ──────────
# Additive/optional: only evaluated when docs/handoff/<task_id>/context.yaml
# carries a `shape` field (dispatched via leadv2-lane-shape.sh classify — the
# main plan/build/review/verify pipeline never sets this field, so tasks that
# never opted in are completely unaffected: A9_EVALUATED stays 0 and TOTAL_HARD
# is not inflated). Gated by LEADV2_LANE_SHAPE, same as classify: off = skipped
# entirely; warn = runs and logs but never fails; enforce = hard failure.
A9_EVALUATED=0
A9_BIN="${SCRIPT_DIR}/leadv2-lane-shape.sh"
A9_CTX="${LEADV2_HANDOFF_DIR}/${TASK_ID}/context.yaml"
if [[ "${LEADV2_LANE_SHAPE:-off}" != "off" && -f "${A9_CTX}" && -x "${A9_BIN}" ]]; then
  if python3 -c "import yaml,sys; sys.exit(0 if (yaml.safe_load(open(sys.argv[1]))or{}).get('shape') else 1)" "${A9_CTX}" 2>/dev/null; then
    A9_EVALUATED=1
    A9_FAIL=0
    if ! "${A9_BIN}" assert-artifacts --task-id "${TASK_ID}"; then
      A9_FAIL=1
      failures+=("A9: ${TASK_ID} — per-shape artifact set incomplete, see stderr above; run: ${A9_BIN} assert-artifacts --task-id ${TASK_ID}")
    fi
    if ! "${A9_BIN}" retro-check --task-id "${TASK_ID}"; then
      A9_FAIL=1
      failures+=("A9: ${TASK_ID} — retro shape check failed: the actual diff needs LINE but the task declared solo (see stderr above)")
    fi
    if [[ "${A9_FAIL}" -eq 0 ]]; then
      log_pass "A9 lane-shape: ${TASK_ID} artifact set + retro shape check OK"
    else
      log_fail "A9 lane-shape: ${TASK_ID} failed (see failures above)"
    fi
  fi
fi

# ── result ────────────────────────────────────────────────────────────────────
# M2: TOTAL_HARD reflects whether A8 was actually evaluated (7 base checks
# A1-A7 + A8 only when A8_EVALUATED=1) -- a warn-skipped A8 (non-deploy task,
# check script not vendored) must not inflate the receipt to a false "8/8".
TOTAL_HARD=$((7 + A8_EVALUATED + A9_EVALUATED))
A8_SUFFIX=""
[[ "$A8_EVALUATED" -eq 0 ]] && A8_SUFFIX=" (A8 not evaluated)"
log_info "=== Phase 8 assertions for ${TASK_ID}: $((TOTAL_HARD - ${#failures[@]})) / ${TOTAL_HARD} HARD checks PASS${A8_SUFFIX} ==="

if (( ${#failures[@]} > 0 )); then
  {
    printf -- '\n'
    printf -- 'GATE FAILED: %d assertion(s) not satisfied for %s:\n' "${#failures[@]}" "${TASK_ID}"
    for item in "${failures[@]}"; do
      printf -- '  - %s\n' "$item"
    done
    printf -- '\n'
    printf -- 'Fix each item above and re-run:\n'
    printf -- '  bash .claude/scripts/leadv2-phase8-close.sh %s\n' "${TASK_ID}"
    printf -- '\n'
  } >&2
  exit 1
fi

# ── write sentinel on full PASS ───────────────────────────────────────────────
mkdir -p "$(dirname "$SENTINEL")"
ASSERTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf -- 'phase8-passed: %s\nasserted_at: %s\ntask_id: %s\nassertions: %s/%s%s\n' \
  "${TASK_ID}" \
  "${ASSERTED_AT}" \
  "${TASK_ID}" \
  "${TOTAL_HARD}" "${TOTAL_HARD}" "${A8_SUFFIX}" \
  > "$SENTINEL"

# A linked worktree's docs/handoff directory is private to that worktree. The
# supervisor and provider-neutral runner live in the main checkout, so the
# local flag alone is not a cross-session completion signal. Mirror the PASS
# into the canonical control plane atomically. This receipt is written only
# after all hard Phase-8 assertions passed; consumers validate its schema and
# never infer completion from a clean model exit.
COMPLETION_RECEIPT="$(
  PROJECT_ROOT="$LEADV2_PROJECT_ROOT" \
    "${SCRIPT_DIR}/leadv2-state-path.sh" --no-link "completions/${TASK_ID}.json"
)"
if ! python3 - "$COMPLETION_RECEIPT" "$TASK_ID" "$ASSERTED_AT" "$SENTINEL" "$LEADV2_PROJECT_ROOT" "$TOTAL_HARD" "$A8_EVALUATED" <<'PYEOF'
import json, os, sys, tempfile

path, task_id, asserted_at, sentinel, project_root, total_hard, a8_evaluated = sys.argv[1:]
payload = {
    "schema_version": 1,
    "task_id": task_id,
    "status": "phase8_passed",
    "asserted_at": asserted_at,
    "assertions": f"{total_hard}/{total_hard}",
    "a8_evaluated": bool(int(a8_evaluated)),
    "worktree": project_root,
    "sentinel": sentinel,
}
directory = os.path.dirname(path)
os.makedirs(directory, exist_ok=True)
fd, tmp = tempfile.mkstemp(prefix=".completion.", suffix=".tmp", dir=directory)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, sort_keys=True)
        fh.write("\n")
        fh.flush()
        os.fsync(fh.fileno())
    os.replace(tmp, path)
except BaseException:
    try:
        os.unlink(tmp)
    except FileNotFoundError:
        pass
    raise
PYEOF
then
  rm -f "$SENTINEL"
  log_error "Phase 8 assertions passed, but shared completion receipt could not be written: ${COMPLETION_RECEIPT}"
  exit 1
fi

# Bus publication is a wake-up optimization for the periodic supervisor. The
# durable receipt above remains the source of truth if bus publication fails.
if ! PROJECT_ROOT="$LEADV2_PROJECT_ROOT" \
  "${SCRIPT_DIR}/leadv2-bus.sh" publish "$TASK_ID" closed \
  "{\"status\":\"phase8_passed\",\"asserted_at\":\"${ASSERTED_AT}\"}"; then
  log_warning "shared completion receipt exists, but closed bus event could not be published"
fi

log_info "Sentinel written: ${SENTINEL}"
log_info "Completion receipt written: ${COMPLETION_RECEIPT}"
log_info "Phase 8 gate PASSED for ${TASK_ID} (${TOTAL_HARD}/${TOTAL_HARD} hard assertions${A8_SUFFIX})"
exit 0
