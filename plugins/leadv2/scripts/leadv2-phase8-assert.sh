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
#
# Best-effort warnings (log_warning + continue; never exit 1):
#   W1  docs/BOARD.md HEAD section has today's date AND task_id
#   W2  docs/agents/product-owner/DIALOGUE.md  has an entry for task_id
#   W3  docs/leadv2/tasks/<task_id>/STATE.md  has "status: closed"
#   W4  docs/agents/product-owner/QUEUE.md  has "[x]" line for task_id
#
# Exit codes:
#   0   all HARD assertions PASS — writes sentinel docs/handoff/<task_id>/phase8-passed.flag
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

# Hard failures accumulate here; warnings do not.
failures=()

# ── A1: closed YAML exists ────────────────────────────────────────────────────
if [[ -f "$CLOSED_YAML" ]]; then
  log_pass "A1 closed YAML: ${CLOSED_YAML}"
else
  log_fail "A1 closed YAML missing: ${CLOSED_YAML}"
  failures+=("A1: ${CLOSED_YAML} not found — run leadv2-phase8-close.sh first")
fi

# ── A2: tasks.yaml (or lane yamls fallback) has terminal status for task_id ───
# Bridge mode: prefer tasks.yaml when present; else read lane yamls directly.
TERMINAL_STATUSES="done|poisoned|rejected|failed|archived|closed|completed|admin-closed"
if [[ -f "$TASKS_YAML" ]]; then
  if python3 - "$TASK_ID" "$TASKS_YAML" "$TERMINAL_STATUSES" "$SCRIPT_DIR" <<'PYEOF' 2>/dev/null
import sys
task_id, path, terminals_raw, scripts_dir = sys.argv[1:5]
terminals = set(terminals_raw.split("|"))
sys.path.insert(0, scripts_dir)
from leadv2_tasks_yaml_common import load_tasks_items
items = load_tasks_items(path)
for it in items:
    if isinstance(it, dict) and str(it.get("id","")) == task_id:
        sys.exit(0 if it.get("status","") in terminals else 1)
# Not found in tasks.yaml — check lane yamls as fallback
sys.exit(2)
PYEOF
  then
    log_pass "A2 tasks.yaml: ${TASK_ID} has terminal status"
  else
    rc=$?
    if [[ $rc -eq 2 ]]; then
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
A4_BOARD_OK=0

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
    A4_BOARD_OK=1
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
A5_OK=0
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
      A5_OK=1
      log_pass "A5 closed YAML: live_signal/verification present and not a placeholder"
      ;;
    1)
      log_fail "A5 closed YAML: placeholder lie-language detected in ${CLOSED_YAML}"
      failures+=("A5: ${CLOSED_YAML} has placeholder lie-language (pending/TODO verify/etc.) -- replace with real evidence or remove the field")
      ;;
    *)
      A5_OK=1
      log_warning "A5 closed YAML: live_signal/verification absent or empty -- non-blocking (set when evidence available)"
      ;;
  esac
else
  log_warning "A5 closed YAML not found (A1 would catch this): ${CLOSED_YAML} -- non-blocking"
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

# ── result ────────────────────────────────────────────────────────────────────
log_info "=== Phase 8 assertions for ${TASK_ID}: $((5 - ${#failures[@]})) / 5 HARD checks PASS ==="

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
printf -- 'phase8-passed: %s\nasserted_at: %s\ntask_id: %s\nassertions: 5/5\n' \
  "${TASK_ID}" \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  "${TASK_ID}" \
  > "$SENTINEL"

log_info "Sentinel written: ${SENTINEL}"
log_info "Phase 8 gate PASSED for ${TASK_ID} (5/5 hard assertions)"
exit 0
