#!/usr/bin/env bash
set -euo pipefail
_LV2_D="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# leadv2-daemon.sh — long-running daemon for Phase 4 autonomous operation.
# Polls task queue, spawns /leadv2 next per item.
# Implements: quiet hours, outcome-based circuit breaker, parallel tasks, state file, resume.
#
# CHANGES (W1):
#   1. Outcome-based circuit breaker: reads docs/LEAD_V2_STATE.md after each task and
#      classifies by outcome field (completed_success|completed_with_warnings → SUCCESS;
#      rolled_back|paused_recovery|failed|missing-entry → FAIL; blocked → BLOCKED).
#      Exit code alone is no longer authoritative.
#   2. Parallel independent tasks: LEADV2_MAX_PARALLEL (default 1) dispatches
#      provider-neutral Phase 0..8 runners when tasks have zero file overlap.
#
# TESTING:
#   Outcome parsing:
#     printf 'status: ok\nhistory:\n- task_id: TEST\n  outcome: rolled_back\n' \
#       > /tmp/fake-state.md
#     LEADV2_STATE_FILE=/tmp/fake-state.md python3 -c "
#     import yaml
#     with open('/tmp/fake-state.md') as f: state = yaml.safe_load(f) or {}
#     h = next((e for e in reversed(state.get('history',[])) if e.get('task_id')=='TEST'), None)
#     print(h.get('outcome') if h else 'MISSING')
#     "
#   Parallelism:
#     LEADV2_MAX_PARALLEL=2 bash .claude/scripts/leadv2-daemon.sh --dry-run

usage() {
  cat >&2 <<EOF
Usage: leadv2-daemon.sh [--poll-seconds <sec>] [--queue-file <path>] [--dry-run] [--resume] [--stop]

Env vars (read on start, can be overridden by flags):
  LEADV2_POLL_SECONDS              default 1800
  LEADV2_QUIET_HOURS               default "23-06" (UTC), format "HH-HH"; set "" to disable
  LEADV2_MAX_CONSECUTIVE_FAILURES  default 3
  LEADV2_COST_CEILING_USD          default 50 (informational, via helpers leadv2_cost_check)
  LEADV2_QUEUE_FILE                default "${LEADV2_TASK_QUEUE:-docs/leadv2/tasks.yaml}"
  LEADV2_MAX_PARALLEL              default 1 (parallel independent tasks when > 1)
  LEADV2_STATE_FILE                default "docs/LEAD_V2_STATE.md" (overridable for testing)
EOF
  exit 1
}

POLL="${LEADV2_POLL_SECONDS:-1800}"
QUEUE="${LEADV2_QUEUE_FILE:-${LEADV2_TASK_QUEUE:-docs/leadv2/tasks.yaml}}"
QUEUE_DIR_DEFAULT="${LEADV2_TASK_QUEUE_DIR:-docs/leadv2/queue}"
QUIET_HOURS="${LEADV2_QUIET_HOURS:-23-06}"
MAX_FAILS="${LEADV2_MAX_CONSECUTIVE_FAILURES:-3}"
PARALLEL="${LEADV2_MAX_PARALLEL:-1}"
STATE_MD="${LEADV2_STATE_FILE:-docs/LEAD_V2_STATE.md}"
DRY_RUN=0
MODE="run"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --poll-seconds) POLL="$2"; shift 2 ;;
    --queue-file) QUEUE="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --resume) MODE="resume"; shift ;;
    --stop) MODE="stop"; shift ;;
    -h|--help) usage ;;
    *) echo "[leadv2-daemon] unknown arg: $1" >&2; usage ;;
  esac
done

PIDFILE="/tmp/leadv2-daemon.pid"
LOGFILE="/tmp/leadv2-daemon.log"
STATEFILE="/tmp/leadv2-daemon.state"

log() {
  local ts
  ts=$(date -u +%FT%TZ)
  echo "[leadv2-daemon] $ts $*" | tee -a "$LOGFILE" >&2
}

in_quiet_hours() {
  [[ -z "$QUIET_HOURS" ]] && return 1
  local from to now
  from="${QUIET_HOURS%-*}"
  to="${QUIET_HOURS#*-}"
  now=$(TZ="Europe/Kiev" date +%H)
  if [[ "$from" -le "$to" ]]; then
    [[ "$now" -ge "$from" && "$now" -lt "$to" ]]
  else
    [[ "$now" -ge "$from" || "$now" -lt "$to" ]]
  fi
}

get_state_field() {
  local field="$1"
  [[ -f "$STATEFILE" ]] || { echo ""; return; }
  awk -v f="$field" '$1 == f":" {$1=""; sub(/^ /,""); print; exit}' "$STATEFILE"
}

write_state() {
  local paused="$1" fails="$2" last_success="$3" last_failure="$4" last_task="$5"
  local last_outcome="${6:-}"
  local last_batch_size="${7:-1}"
  local last_claim_id="${8:-}"
  local last_claim_lane="${9:-}"
  cat > "$STATEFILE" <<EOF
paused: $paused
consecutive_failures: $fails
last_success: $last_success
last_failure: $last_failure
last_task_id: $last_task
last_outcome: $last_outcome
last_parallel_batch_size: $last_batch_size
last_claim_id: $last_claim_id
last_claim_lane: $last_claim_lane
updated_at: $(date -u +%FT%TZ)
EOF
}

push_notify() {
  local msg="$1"
  log "NOTIFY: $msg"
  if command -v notify-push >/dev/null 2>&1; then
    notify-push "$msg" 2>/dev/null || true
  fi
}

# ── Founder-input: decision files ─────────────────────────────────────────────
DECISIONS_DIR="${PROJECT_ROOT:-$(pwd)}/docs/leadv2-decisions"
DECISIONS_RESOLVED="${DECISIONS_DIR}/_resolved"
STATUS_MD="${PROJECT_ROOT:-$(pwd)}/docs/LEAD_V2_STATUS.md"
# Track last pending decision id to avoid duplicate creation per circuit-break
_LAST_DECISION_ID=""

# create_decision_file <task_id> <phase> <trigger> <question> <last_fail_reason>
create_decision_file() {
  local task_id="$1" phase="$2" trigger="$3" question="$4" last_fail_reason="$5"
  local ts; ts=$(date -u +%Y-%m-%dT%H-%M-%SZ)
  local dec_id="${ts}-${task_id}"
  local dec_file="${DECISIONS_DIR}/${dec_id}.yaml"
  local re_ping_at; re_ping_at=$(date -u -d "+2 hours" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || python3 -c "import datetime; print((datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)+datetime.timedelta(hours=2)).strftime('%Y-%m-%dT%H:%M:%SZ'))")

  # Read last 3 history entries from STATE_MD
  local history_json
  history_json=$(python3 - "$STATE_MD" <<'PY'
import sys, yaml, json
try:
    with open(sys.argv[1]) as f:
        state = yaml.safe_load(f) or {}
    h = (state.get("history") or [])[-3:]
    print(json.dumps(h))
except Exception:
    print("[]")
PY
  )

  mkdir -p "$DECISIONS_DIR"
  python3 - "$dec_file" "$dec_id" "$task_id" "$phase" "$trigger" \
            "$question" "$last_fail_reason" "$history_json" "$re_ping_at" <<'PY'
import sys, yaml, os

dec_file, dec_id, task_id, phase, trigger, question, last_fail_reason, history_json, re_ping_at = sys.argv[1:]
import json
history = json.loads(history_json)

doc = {
    "id": dec_id,
    "created_at": dec_id.split("-")[0] + "-" + dec_id.split("-")[1] + "-" + dec_id.split("-")[2][:2],
    "task_id": task_id,
    "phase": phase,
    "trigger": trigger,
    "status": "pending",
    "question": question,
    "options": [
        {"id": "A", "label": "Retry once more (reset failure count)",         "action": "retry_task"},
        {"id": "B", "label": "Skip, mark blocked-on-human, continue queue",    "action": "skip_task"},
        {"id": "C", "label": "Pause daemon; investigate manually; resume when ready", "action": "pause_indefinite"},
        {"id": "D", "label": "Roll back last commit and open a RECOVERY- task","action": "rollback_and_investigate"},
    ],
    "context": {
        "task_class": "unknown",
        "files_touched": [],
        "last_fail_reason": last_fail_reason,
        "last_n_history": history,
    },
    "answer": {"selected": None, "selected_at": None, "notes": None},
    "escalation": {"re_ping_at": re_ping_at, "re_ping_count": 0},
}
tmp = dec_file + ".tmp"
with open(tmp, "w") as f:
    yaml.dump(doc, f, default_flow_style=False, allow_unicode=True, sort_keys=False)
os.replace(tmp, dec_file)
print(dec_id)
PY
  echo "$dec_id"
}

# check_answered_decisions — process any decisions with status=answered
check_answered_decisions() {
  [[ -d "$DECISIONS_DIR" ]] || return 0

  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    grep -q 'status: answered' "$f" 2>/dev/null || continue

    local action dec_id task_id
    action=$(python3 -c "
import yaml, sys
with open(sys.argv[1]) as fh: d = yaml.safe_load(fh) or {}
sel = d.get('answer',{}).get('selected','')
opts = d.get('options') or []
opt = next((o for o in opts if str(o.get('id','')).upper() == str(sel).upper()), {})
print(opt.get('action',''))
" "$f" 2>/dev/null || echo "")
    dec_id=$(python3 -c "
import yaml, sys
with open(sys.argv[1]) as fh: d = yaml.safe_load(fh) or {}
print(d.get('id',''))
" "$f" 2>/dev/null || echo "")
    task_id=$(python3 -c "
import yaml, sys
with open(sys.argv[1]) as fh: d = yaml.safe_load(fh) or {}
print(d.get('task_id',''))
" "$f" 2>/dev/null || echo "")

    log "decision answered: id=$dec_id task=$task_id action=$action"

    case "$action" in
      retry_task)
        write_state false 0 "$(get_state_field last_success)" "$(get_state_field last_failure)" "$task_id" "" "1"
        log "decision $dec_id → retry_task: paused cleared, consecutive_failures reset"
        ;;
      skip_task)
        # Mark task as blocked-on-human in QUEUE
        if [[ -f "$QUEUE" ]]; then
          python3 - "$QUEUE" "$task_id" <<'PY'
import sys, re
queue_file, task_id = sys.argv[1], sys.argv[2]
with open(queue_file) as f:
    lines = f.readlines()
out = []
for line in lines:
    if re.search(r'\[ \]', line) and task_id in line and 'blocked-on-human' not in line:
        line = line.replace('- [ ]', '- [x] [blocked-on-human]', 1)
    out.append(line)
with open(queue_file, 'w') as f:
    f.writelines(out)
PY
        fi
        write_state false "$(get_state_field consecutive_failures)" \
          "$(get_state_field last_success)" "$(get_state_field last_failure)" \
          "$task_id" "blocked" "1"
        log "decision $dec_id → skip_task: marked blocked-on-human"
        ;;
      pause_indefinite)
        write_state true "$(get_state_field consecutive_failures)" \
          "$(get_state_field last_success)" "$(get_state_field last_failure)" \
          "$task_id" "paused-indefinite" "1"
        log "decision $dec_id → pause_indefinite: daemon paused"
        ;;
      rollback_and_investigate)
        local rollback_script="$_LV2_D/leadv2-rollback.sh"
        if [[ -f "$rollback_script" ]]; then
          bash "$rollback_script" --yes 2>&1 | tee -a "$LOGFILE" || true
        else
          log "WARN: leadv2-rollback.sh not found — skipping rollback"
        fi
        # Append RECOVERY- task to queue
        if [[ -f "$QUEUE" ]]; then
          local rec_id="RECOVERY-${task_id}"
          printf -- '- [ ] [%s] Investigate rollback from %s\n' "$rec_id" "$task_id" >> "$QUEUE"
        fi
        write_state false 0 "$(get_state_field last_success)" "$(get_state_field last_failure)" \
          "$task_id" "rollback" "1"
        log "decision $dec_id → rollback_and_investigate: rollback called, RECOVERY task appended"
        ;;
      *)
        log "WARN: decision $dec_id has unknown action '$action' — ignoring"
        ;;
    esac

    # Move to resolved
    local date_dir; date_dir=$(date -u +%Y%m%d)
    mkdir -p "${DECISIONS_RESOLVED}/${date_dir}"
    mv "$f" "${DECISIONS_RESOLVED}/${date_dir}/${dec_id}.yaml" 2>/dev/null || true
    _LAST_DECISION_ID=""

  done < <(find "$DECISIONS_DIR" -maxdepth 1 -name '*.yaml' ! -name '_*' 2>/dev/null)
}

# re_ping_pending_decisions — send reminders for decisions past their re_ping_at time
re_ping_pending_decisions() {
  [[ -d "$DECISIONS_DIR" ]] || return 0
  local now_epoch; now_epoch=$(date +%s)

  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    grep -q 'status: pending' "$f" 2>/dev/null || continue

    python3 - "$f" "$now_epoch" <<'PY'
import sys, yaml, os, datetime

dec_file   = sys.argv[1]
now_epoch  = int(sys.argv[2])

with open(dec_file) as fh:
    doc = yaml.safe_load(fh) or {}

esc = doc.get("escalation") or {}
re_ping_at_str = str(esc.get("re_ping_at", ""))
if not re_ping_at_str:
    sys.exit(0)

try:
    re_ping_epoch = int(datetime.datetime.strptime(
        re_ping_at_str, "%Y-%m-%dT%H:%M:%SZ").replace(
        tzinfo=datetime.timezone.utc).timestamp())
except ValueError:
    sys.exit(0)

if now_epoch < re_ping_epoch:
    sys.exit(0)

# Time to re-ping
count = int(esc.get("re_ping_count", 0))
count += 1
# next ping: min(2h * 2^count, 12h)
delay_h = min(2 * (2 ** count), 12)
next_ping = (datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None) + datetime.timedelta(hours=delay_h)).strftime("%Y-%m-%dT%H:%M:%SZ")

doc["escalation"]["re_ping_count"] = count
doc["escalation"]["re_ping_at"] = next_ping

tmp = dec_file + ".tmp"
with open(tmp, "w") as fh:
    yaml.dump(doc, fh, default_flow_style=False, allow_unicode=True, sort_keys=False)
os.replace(tmp, dec_file)

task_id  = doc.get("task_id", "?")
question = (doc.get("question") or "")[:120]
# W6-fix: changed prefix from "RE_PING|" (could match yaml content) to an
# impossible-in-yaml sentinel. ">>> RE_PING >>>" cannot appear in yaml values.
print(f">>> RE_PING >>> {task_id}|{count}|{question}")
PY

  done < <(find "$DECISIONS_DIR" -maxdepth 1 -name '*.yaml' ! -name '_*' 2>/dev/null)
}

# write_status_file — regenerate docs/LEAD_V2_STATUS.md atomically
write_status_file() {
  local mode="${1:-daemon}" phase="${2:-—}" task_id="${3:-—}" task_desc="${4:-—}"
  local task_class="${5:-—}" started="${6:-—}"
  local circuit_state paused fails last_fail pending_count
  paused=$(get_state_field paused)
  fails=$(get_state_field consecutive_failures)
  last_fail=$(get_state_field last_failure)
  [[ -z "$fails" ]] && fails=0
  [[ "$paused" == "true" ]] && circuit_state="paused-circuit-break" || circuit_state="ok"

  # Count pending decisions
  pending_count=0
  local pending_lines=""
  if [[ -d "$DECISIONS_DIR" ]]; then
    while IFS= read -r f; do
      [[ -z "$f" ]] && continue
      grep -q 'status: pending' "$f" 2>/dev/null || continue
      pending_count=$((pending_count + 1))
      local dec_id dec_question dec_file_base
      dec_id=$(grep -m1 '^id:' "$f" | sed "s/id: //;s/['\"]//g" | xargs)
      dec_question=$(grep -m1 '^question:' "$f" | sed "s/question: //;s/['\"]//g" | xargs)
      dec_file_base=$(basename "$f")
      pending_lines="${pending_lines}- [${dec_id}] ${dec_question} → answer at \`docs/leadv2-decisions/${dec_file_base}\`\n"
    done < <(find "$DECISIONS_DIR" -maxdepth 1 -name '*.yaml' ! -name '_*' 2>/dev/null | sort | head -10)
  fi
  [[ -z "$pending_lines" ]] && pending_lines="_None._"

  # Duration
  local duration="—"
  if [[ "$started" != "—" && -n "$started" ]]; then
    duration=$(python3 -c "
import datetime, sys
try:
    s = datetime.datetime.strptime(sys.argv[1], '%Y-%m-%dT%H:%M:%SZ')
    d = datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None) - s
    tot = int(d.total_seconds())
    h, m = divmod(tot // 60, 60)
    print(f'{h}h{m:02d}m' if h else f'{m}m')
except Exception:
    print('—')
" "$started" 2>/dev/null || echo "—")
  fi

  # Last 5 history
  local history_table
  history_table=$(python3 - "$STATE_MD" <<'PY'
import sys, yaml
try:
    with open(sys.argv[1]) as f:
        state = yaml.safe_load(f) or {}
    h = (state.get("history") or [])
    h = h[-5:]
    rows = []
    for e in reversed(h):
        t  = str(e.get("completed_at") or e.get("started_at") or "—")[:19]
        tid = str(e.get("task_id","—"))
        ph = str(e.get("phase","—"))
        oc = str(e.get("outcome","—"))
        rows.append(f"| {t} | {tid} | {ph} | {oc} |")
    if not rows:
        print("| — | — | — | — |")
    else:
        print("\n".join(rows))
except Exception:
    print("| — | — | — | — |")
PY
  )

  local ts; ts=$(date -u +%FT%TZ)
  local tmp; tmp="${STATUS_MD}.tmp"

  {
    printf '# /leadv2 Live Status\n'
    printf '_Last updated: %s_\n\n' "$ts"
    printf '## Current state\n'
    printf -- '- **Mode:** %s\n' "$mode"
    printf -- '- **Phase:** %s\n' "$phase"
    printf -- '- **Task:** %s — %s\n' "$task_id" "$task_desc"
    printf -- '- **Task class:** %s\n' "$task_class"
    printf -- '- **Started:** %s\n' "$started"
    printf -- '- **Duration:** %s\n\n' "$duration"
    printf '## Blockers\n'
    printf -- '- **Circuit state:** %s\n' "$circuit_state"
    printf -- '- **Consecutive failures:** %s/%s\n' "$fails" "$MAX_FAILS"
    printf -- '- **Last fail:** %s\n\n' "${last_fail:-—}"
    printf '## Pending decisions\n'
    printf -- '%b\n\n' "$pending_lines"
    printf '## Recent history (last 5)\n'
    printf '| Time | Task | Phase | Outcome |\n'
    printf '|---|---|---|---|\n'
    printf '%s\n\n' "$history_table"
    printf '## How to interact\n'
    printf -- '- Quick check: `bash .claude/scripts/leadv2-status.sh`\n'
    printf -- '- Answer a pending decision: edit the yaml file OR run `bash .claude/scripts/leadv2-decide.sh <id> <option>`\n'
    printf -- '- Force resume after manual fix: `bash .claude/scripts/leadv2-daemon.sh --resume`\n'
    printf -- '- Stop daemon: `bash .claude/scripts/leadv2-daemon.sh --stop`\n'
  } > "$tmp"
  mv "$tmp" "$STATUS_MD"
}

# ── Outcome-based task classification ────────────────────────────────────────
# Reads $STATE_MD, finds task_id in history, returns: SUCCESS | FAIL | BLOCKED
parse_task_outcome() {
  local task_id="$1"
  [[ -f "$STATE_MD" ]] || { echo "FAIL"; return; }

  python3 - "$STATE_MD" "$task_id" <<'PY'
import sys, yaml

state_file = sys.argv[1]
task_id    = sys.argv[2]

try:
    with open(state_file) as f:
        state = yaml.safe_load(f) or {}
except Exception as e:
    print(f"WARN: yaml parse error: {e}", file=sys.stderr)
    print("FAIL")
    sys.exit(0)

history = state.get("history") or []
entry = None
for h in reversed(history):
    if str(h.get("task_id", "")).strip() == task_id:
        entry = h
        break

if entry is None:
    print(f"WARN: no history entry for task_id={task_id}", file=sys.stderr)
    print("FAIL")
    sys.exit(0)

outcome = str(entry.get("outcome", "")).strip()
SUCCESS_OUTCOMES = {"completed_success", "completed_with_warnings"}
BLOCKED_OUTCOMES = {"blocked"}

if outcome in SUCCESS_OUTCOMES:
    print("SUCCESS")
elif outcome in BLOCKED_OUTCOMES:
    print("BLOCKED")
else:
    print("FAIL")
PY
}

# ── File-set extraction + independence check ──────────────────────────────────
extract_file_set() {
  local task_line="$1"
  echo "$task_line" | grep -oE '[a-zA-Z0-9_./-]+\.(py|ts|tsx|sql|yaml|yml|md|sh|json)' | sort -u || true
}

# Returns 0 (independent) or 1 (conflicting / unknown)
tasks_independent() {
  local line_a="$1" line_b="$2"
  local files_a files_b
  files_a=$(extract_file_set "$line_a")
  files_b=$(extract_file_set "$line_b")
  if [[ -z "$files_a" || -z "$files_b" ]]; then return 1; fi
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    if echo "$files_b" | grep -qxF "$f"; then return 1; fi
  done <<< "$files_a"
  return 0
}

# ── Parallel batch runner ─────────────────────────────────────────────────────
# Picks up to PARALLEL independent tasks, spawns concurrently.
# Sets globals LAST_BATCH_TASK_IDS and LAST_BATCH_SIZE.
# Prints one of: SUCCESS | FAIL | BLOCKED | EMPTY | DRY

LAST_BATCH_TASK_IDS=""
LAST_BATCH_SIZE=0
LAST_CLAIM_ID=""
LAST_CLAIM_LANE=""

# ── Queue lane helpers ────────────────────────────────────────────────────────
QUEUE_SCRIPTS_DIR="${PROJECT_ROOT:-$(pwd)}/.claude/scripts"

# Returns the queue directory if it exists, else falls back to legacy QUEUE.md mode
queue_mode() {
  local qdir="${PROJECT_ROOT:-$(pwd)}/${QUEUE_DIR_DEFAULT}"
  [[ -d "$qdir" ]] && echo "lanes" || echo "legacy"
}

# Claim one item across lanes in priority order: recovery > action > intelligence
# Sets LAST_CLAIM_ID and LAST_CLAIM_LANE on success.
# Returns the raw task line (id|title) or empty string.
claim_next_item() {
  local qmode; qmode=$(queue_mode)
  if [[ "$qmode" == "legacy" ]]; then
    LAST_CLAIM_ID=""
    LAST_CLAIM_LANE="legacy"
    return 0
  fi

  local claimer_id="daemon-$$"
  local lanes_ordered=("recovery" "action" "intelligence")
  # human-needed is intentionally skipped

  for lane in "${lanes_ordered[@]}"; do
    local claimed
    claimed=$("${QUEUE_SCRIPTS_DIR}/leadv2-queue-claim.sh" \
      --lane "$lane" --by "$claimer_id" --ttl-min 90 2>/dev/null || true)
    if [[ -n "$claimed" ]]; then
      local item_id
      item_id=$(python3 -c "
import yaml, sys
items = yaml.safe_load(sys.argv[1]) or []
print(items[0].get('id','') if items else '')
" "$claimed" 2>/dev/null || echo "")
      LAST_CLAIM_ID="$item_id"
      LAST_CLAIM_LANE="$lane"
      log "claimed item $item_id from lane=$lane"
      return 0
    fi
  done

  # Nothing claimable in any lane
  LAST_CLAIM_ID=""
  LAST_CLAIM_LANE=""
  return 1
}

# Release the last claimed item
release_claimed_item() {
  local outcome="$1"   # success|fail|poison
  local reason="${2:-}"

  [[ -z "$LAST_CLAIM_ID" || "$LAST_CLAIM_LANE" == "legacy" ]] && return 0

  local extra_args=()
  if [[ -n "$reason" ]]; then
    extra_args=(--reject-reason "$reason")
  elif [[ "$outcome" == "poison" ]]; then
    extra_args=(--reject-reason "daemon: task poisoned")
  fi

  "${QUEUE_SCRIPTS_DIR}/leadv2-queue-release.sh" \
    --lane "$LAST_CLAIM_LANE" \
    --id   "$LAST_CLAIM_ID" \
    --outcome "$outcome" \
    "${extra_args[@]}" 2>/dev/null || true
}

run_batch() {
  local qmode; qmode=$(queue_mode)

  # ── Run sweep at batch start ─────────────────────────────────────────────
  if [[ "$qmode" == "lanes" ]]; then
    "${QUEUE_SCRIPTS_DIR}/leadv2-queue-sweep.sh" \
      --queue-dir "${PROJECT_ROOT:-$(pwd)}/${QUEUE_DIR_DEFAULT}" 2>/dev/null || true
  fi

  # ── Determine pending lines (legacy or lanes) ─────────────────────────────
  local all_pending=""
  if [[ "$qmode" == "lanes" ]]; then
    # Build a synthetic pending-lines list from lane files for independence check
    # Order: recovery > action > intelligence
    all_pending=$(python3 - "${PROJECT_ROOT:-$(pwd)}/${QUEUE_DIR_DEFAULT}" <<'PY'
import sys, os, yaml

queue_dir = sys.argv[1]
LANES = ["recovery", "action", "intelligence"]
PRIORITY_ORDER = {"high": 0, "medium": 1, "low": 2}

lines = []
for lane in LANES:
    lane_file = os.path.join(queue_dir, f"{lane}.yaml")
    if not os.path.exists(lane_file):
        continue
    with open(lane_file) as f:
        items = yaml.safe_load(f) or []
    claimable = [
        it for it in items
        if it.get("status") in ("pending",)
        and (it.get("claim") or {}).get("by") is None
    ]
    claimable.sort(key=lambda it: (
        PRIORITY_ORDER.get(str(it.get("priority","medium")),1),
        str(it.get("created_at","")),
    ))
    for it in claimable:
        tid = str(it.get("id","unknown"))
        title = str(it.get("title",""))
        context = it.get("context") or {}
        files = " ".join(context.get("files") or [])
        lines.append(f"- [ ] [{tid}] {title} {files}")
print("\n".join(lines))
PY
    )
  else
    all_pending=$(grep -E '^- \[ \]' "$QUEUE" | grep -v 'blocked-on-human' || true)
  fi

  if [[ -z "$all_pending" ]]; then
    LAST_BATCH_SIZE=0; LAST_BATCH_TASK_IDS=""
    echo "EMPTY"; return 0
  fi

  local batch_lines=() batch_task_ids=() first_line=""
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    if [[ ${#batch_lines[@]} -eq 0 ]]; then
      first_line="$line"
      batch_lines+=("$line")
      local tid; tid=$(echo "$line" | grep -oE '[A-Z]+-[0-9]+' | head -1 || echo "unknown")
      batch_task_ids+=("$tid")
    elif [[ ${#batch_lines[@]} -lt "$PARALLEL" ]]; then
      if tasks_independent "$first_line" "$line"; then
        batch_lines+=("$line")
        local tid2; tid2=$(echo "$line" | grep -oE '[A-Z]+-[0-9]+' | head -1 || echo "unknown")
        batch_task_ids+=("$tid2")
      fi
    else
      break
    fi
  done <<< "$all_pending"

  LAST_BATCH_SIZE=${#batch_lines[@]}
  LAST_BATCH_TASK_IDS="${batch_task_ids[*]}"

  if [[ "$DRY_RUN" == "1" ]]; then
    for i in "${!batch_lines[@]}"; do
      log "dry-run: would spawn /leadv2 next for ${batch_task_ids[$i]} ('${batch_lines[$i]}')"
    done
    echo "DRY"; return 0
  fi

  # Claim items in lane mode before spawning
  declare -A batch_lanes   # tid → lane
  if [[ "$qmode" == "lanes" ]]; then
    for i in "${!batch_task_ids[@]}"; do
      local tid="${batch_task_ids[$i]}"
      # Determine which lane this tid belongs to
      local item_lane
      item_lane=$(python3 - "${PROJECT_ROOT:-$(pwd)}/${QUEUE_DIR_DEFAULT}" "$tid" <<'PY'
import sys, os, yaml
queue_dir = sys.argv[1]
tid = sys.argv[2]
for lane in ["recovery","action","intelligence"]:
    lf = os.path.join(queue_dir, f"{lane}.yaml")
    if not os.path.exists(lf):
        continue
    items = yaml.safe_load(open(lf)) or []
    for it in items:
        if str(it.get("id","")) == tid:
            print(lane)
            sys.exit(0)
print("")
PY
      )
      if [[ -n "$item_lane" ]]; then
        "${QUEUE_SCRIPTS_DIR}/leadv2-queue-claim.sh" \
          --lane "$item_lane" --by "daemon-$$-${tid}" --ttl-min 90 >/dev/null 2>/dev/null || true
        batch_lanes["$tid"]="$item_lane"
      fi
    done
  fi

  local tmpdir; tmpdir=$(mktemp -d /tmp/leadv2-batch-XXXXXX)
  local pids=()

  for i in "${!batch_lines[@]}"; do
    local tid="${batch_task_ids[$i]}"
    local exit_file="$tmpdir/exit-${tid}"
    log "[${tid}] spawning /leadv2 next ('${batch_lines[$i]}')"
    (
      export LEADV2_DAEMON=1
      export LEADV2_DAEMON_TASK_ID="$tid"
      if LEADV2_SPAWN_WAIT=1 \
          LEADV2_SPAWN_PROVIDER="${LEADV2_DAEMON_PROVIDER:-auto}" \
          LEADV2_SPAWN_PERMISSION_MODE="${LEADV2_DAEMON_PERMISSION_MODE:-acceptEdits}" \
          bash "${_LV2_D}/leadv2-session-spawner.sh" --wait "$tid" \
          >> "$LOGFILE" 2>&1; then
        echo 0 > "$exit_file"
      else
        echo $? > "$exit_file"
      fi
    ) &
    pids+=($!)
  done

  for pid in "${pids[@]}"; do wait "$pid" || true; done

  local any_fail=0 all_blocked=1
  for i in "${!batch_lines[@]}"; do
    local tid="${batch_task_ids[$i]}"
    local exit_file="$tmpdir/exit-${tid}"
    local cli_exit=1
    [[ -f "$exit_file" ]] && cli_exit=$(cat "$exit_file")

    local outcome; outcome=$(parse_task_outcome "$tid")

    local class
    if [[ "$outcome" == "BLOCKED" ]]; then
      class="BLOCKED"
    elif [[ "$outcome" == "SUCCESS" && "$cli_exit" -eq 0 ]]; then
      class="SUCCESS"
    else
      class="FAIL"
    fi

    log "[${tid}] /leadv2 exit=$cli_exit outcome=$outcome classification=$class for $tid"

    # Release lane claim if in lanes mode
    if [[ "$qmode" == "lanes" && -n "${batch_lanes[$tid]+_}" ]]; then
      local rel_outcome="success"
      local rel_reason=""
      if [[ "$class" == "FAIL" ]]; then
        rel_outcome="fail"
        rel_reason="task failed (exit=$cli_exit outcome=$outcome)"
      elif [[ "$class" == "BLOCKED" ]]; then
        rel_outcome="fail"
        rel_reason="task blocked"
      fi
      "${QUEUE_SCRIPTS_DIR}/leadv2-queue-release.sh" \
        --lane "${batch_lanes[$tid]}" \
        --id   "$tid" \
        --outcome "$rel_outcome" \
        ${rel_reason:+--reject-reason "$rel_reason"} 2>/dev/null || true
      LAST_CLAIM_ID="$tid"
      LAST_CLAIM_LANE="${batch_lanes[$tid]}"
    fi

    if [[ "$class" == "SUCCESS" ]]; then   all_blocked=0
    elif [[ "$class" == "FAIL" ]]; then    any_fail=1; all_blocked=0
    fi
  done

  rm -rf "$tmpdir"

  if   [[ "$any_fail"    -eq 1 ]]; then echo "FAIL"
  elif [[ "$all_blocked" -eq 1 ]]; then echo "BLOCKED"
  else                                   echo "SUCCESS"
  fi
}

if [[ "$MODE" == "stop" ]]; then
  if [[ -f "$PIDFILE" ]]; then
    pid=$(cat "$PIDFILE")
    if kill -0 "$pid" 2>/dev/null; then
      kill "$pid"
      echo "stopped PID $pid" >&2
      exit 0
    fi
    rm -f "$PIDFILE"
  fi
  echo "no running daemon" >&2
  exit 1
fi

if [[ "$MODE" == "resume" ]]; then
  if [[ -f "$STATEFILE" ]] && [[ "$(get_state_field paused)" == "true" ]]; then
    current_fails=$(get_state_field consecutive_failures)
    write_state false 0 "$(get_state_field last_success)" "$(get_state_field last_failure)" "$(get_state_field last_task_id)" "" "1"
    echo "resumed (was paused after $current_fails consecutive failures)" >&2
    exit 0
  fi
  echo "nothing to resume — daemon not in paused state" >&2
  exit 1
fi

if [[ -f "$PIDFILE" ]]; then
  OLD=$(cat "$PIDFILE")
  if kill -0 "$OLD" 2>/dev/null; then
    echo "[leadv2-daemon] already running PID=$OLD" >&2
    exit 1
  fi
  rm -f "$PIDFILE"
fi

echo $$ > "$PIDFILE"

if [[ ! -f "$STATEFILE" ]]; then
  write_state false 0 "" "" "" "" "1"
fi

if [[ "$(get_state_field paused)" == "true" ]]; then
  log "REFUSING START: state is paused (previous circuit break). Run --resume to clear."
  rm -f "$PIDFILE"
  exit 3
fi

cleanup() {
  log "shutdown"
  rm -f "$PIDFILE"
  exit 0
}
trap cleanup TERM INT

log "started PID=$$ poll=${POLL}s queue=$QUEUE quiet_hours=$QUIET_HOURS max_fails=$MAX_FAILS parallel=$PARALLEL dry_run=$DRY_RUN"

FIRST=1
_PAUSED_SINCE=0   # epoch when we entered paused state this run

while true; do
  if [[ "$FIRST" == "1" ]]; then
    FIRST=0
  else
    sleep "$POLL"
  fi

  # Process any decisions the founder has answered
  check_answered_decisions

  paused=$(get_state_field paused)
  fails=$(get_state_field consecutive_failures)
  [[ -z "$fails" ]] && fails=0

  if [[ "$paused" == "true" ]]; then
    # Re-ping loop every 60 min while paused
    now_epoch=$(date +%s)
    if [[ "$_PAUSED_SINCE" -eq 0 ]]; then _PAUSED_SINCE="$now_epoch"; fi
    paused_mins=$(( (now_epoch - _PAUSED_SINCE) / 60 ))

    # Emit re-pings for decisions past their re_ping_at
    # W6-fix: changed sentinel from "RE_PING|" to ">>> RE_PING >>> " (impossible in yaml content)
    while IFS='|' read -r rp_task rp_count rp_question; do
      [[ -z "$rp_task" ]] && continue
      push_notify "[leadv2] Escalation #${rp_count}: awaiting decision for ${rp_task} — ${rp_question:0:80}"
    done < <(re_ping_pending_decisions 2>/dev/null | grep '^>>> RE_PING >>> ' | sed 's/^>>> RE_PING >>> //')

    log "paused — waiting for --resume or decision answer (${paused_mins}m elapsed)"
    # Update status file while paused so founder can see current state
    write_status_file "paused" "—" "$(get_state_field last_task_id)" "—" "—" "—"
    sleep 60
    continue
  fi
  _PAUSED_SINCE=0

  if in_quiet_hours; then
    log "quiet hours ($QUIET_HOURS, Kyiv) — skipping tick"
    continue
  fi

  # ── Nightly priors compile (once every 20h) ────────────────────────────────
  # Suggested cron for always-on systems (runs as persona user, SHELL=/bin/bash):
  #   0 3 * * * SHELL=/bin/bash /path/to/.claude/scripts/leadv2-priors-compile.sh >> /tmp/leadv2-priors.log 2>&1
  _PRIORS_COMPILE_SCRIPT="$_LV2_D/leadv2-priors-compile.sh"
  _PRIORS_YAML="${PROJECT_ROOT:-$(pwd)}/docs/leadv2-priors.yaml"
  if [[ -f "$_PRIORS_COMPILE_SCRIPT" ]]; then
    _needs_compile=0
    if [[ ! -f "$_PRIORS_YAML" ]]; then
      _needs_compile=1
    else
      _priors_age_h=$(python3 -c "
import os, time
mtime = os.path.getmtime('$_PRIORS_YAML')
age_h = (time.time() - mtime) / 3600
print('1' if age_h > 20 else '0')
" 2>/dev/null || echo "0")
      [[ "$_priors_age_h" == "1" ]] && _needs_compile=1
    fi
    if [[ "$_needs_compile" -eq 1 ]]; then
      log "priors: recompiling (stale or missing)"
      bash "$_PRIORS_COMPILE_SCRIPT" 2>/dev/null && log "priors: compile OK" || log "WARN: priors compile failed — continuing"
    fi
  fi

  # Queue availability check — prefer lanes directory, fall back to QUEUE.md
  _qmode=$(queue_mode)
  if [[ "$_qmode" == "legacy" ]]; then
    if [[ ! -f "$QUEUE" ]]; then
      log "queue missing: $QUEUE"
      continue
    fi
    NEXT=$(grep -m1 -E '^- \[ \]' "$QUEUE" | grep -v blocked-on-human || true)
    if [[ -z "$NEXT" ]]; then
      log "queue empty / all blocked"
      continue
    fi
    TASK_ID=$(echo "$NEXT" | grep -oE '[A-Z]+-[0-9]+' | head -1 || echo "unknown")
  else
    # Lanes mode — TASK_ID resolved inside run_batch via LAST_CLAIM_ID
    TASK_ID="lanes"
  fi

  # Daily budget check — pause daemon until UTC midnight if exceeded
  _DAILY_BUDGET_SCRIPT="$_LV2_D/leadv2-daily-budget.sh"
  if [[ -f "$_DAILY_BUDGET_SCRIPT" ]]; then
    if ! bash "$_DAILY_BUDGET_SCRIPT" --check 2>/dev/null; then
      # Calculate seconds until next UTC midnight
      _midnight_sleep=$(python3 -c "
import datetime, math
now = datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)
midnight = (now + datetime.timedelta(days=1)).replace(hour=0, minute=0, second=5, microsecond=0)
print(max(60, int((midnight - now).total_seconds())))
" 2>/dev/null || echo "3600")
      push_notify "[leadv2] Daily budget exceeded — daemon pausing until UTC midnight (~${_midnight_sleep}s)"
      log "DAILY BUDGET EXCEEDED — sleeping ${_midnight_sleep}s until UTC midnight"
      sleep "$_midnight_sleep"
      continue
    fi
  fi

  # run_batch handles dry-run internally; DRY prints "DRY" and returns
  BATCH_CLASS=$(run_batch)
  BATCH_SIZE="${LAST_BATCH_SIZE:-1}"

  if [[ "$BATCH_CLASS" == "EMPTY" || "$BATCH_CLASS" == "DRY" ]]; then
    continue
  fi

  # W6-fix: flush any pending async cost markers that weren't recorded at subsession exit
  COST_FLUSH="$_LV2_D/leadv2-cost-flush.sh"
  if [[ -f "$COST_FLUSH" ]]; then
    bash "$COST_FLUSH" 2>/dev/null || true
  fi

  NOW=$(date -u +%FT%TZ)

  # Resolve effective task id (lanes mode sets LAST_CLAIM_ID inside run_batch)
  [[ "$TASK_ID" == "lanes" && -n "$LAST_CLAIM_ID" ]] && TASK_ID="$LAST_CLAIM_ID"

  if [[ "$BATCH_CLASS" == "SUCCESS" ]]; then
    fails=0
    write_state false 0 "$NOW" "$(get_state_field last_failure)" "$TASK_ID" "success" "$BATCH_SIZE" "${LAST_CLAIM_ID:-}" "${LAST_CLAIM_LANE:-}"
    log "/leadv2 OK for $TASK_ID (fails reset) batch_size=$BATCH_SIZE ids=${LAST_BATCH_TASK_IDS}"

  elif [[ "$BATCH_CLASS" == "BLOCKED" ]]; then
    # BLOCKED: do not count as failure, move on
    write_state false "$fails" "$(get_state_field last_success)" "$(get_state_field last_failure)" "$TASK_ID" "blocked" "$BATCH_SIZE" "${LAST_CLAIM_ID:-}" "${LAST_CLAIM_LANE:-}"
    log "/leadv2 BLOCKED for $TASK_ID — skipping (not counted as failure)"

  else
    # FAIL
    fails=$((fails + 1))
    write_state false "$fails" "$(get_state_field last_success)" "$NOW" "$TASK_ID" "fail" "$BATCH_SIZE" "${LAST_CLAIM_ID:-}" "${LAST_CLAIM_LANE:-}"
    log "/leadv2 FAIL for $TASK_ID (consecutive=$fails/$MAX_FAILS) batch_size=$BATCH_SIZE ids=${LAST_BATCH_TASK_IDS}"

    if [[ "$fails" -ge "$MAX_FAILS" ]]; then
      write_state true "$fails" "$(get_state_field last_success)" "$NOW" "$TASK_ID" "fail" "$BATCH_SIZE" "${LAST_CLAIM_ID:-}" "${LAST_CLAIM_LANE:-}"
      # Create a founder-input decision file (only once per circuit-break event)
      if [[ "$_LAST_DECISION_ID" == "" ]]; then
        dec_question="Daemon circuit-break: ${fails} consecutive failures (last: ${TASK_ID}). Last error: see $LOGFILE. What next?"
        _LAST_DECISION_ID=$(create_decision_file \
          "$TASK_ID" "$(get_state_field phase 2>/dev/null || echo daemon)" \
          "circuit-break" "$dec_question" \
          "${fails} consecutive failures — last task: ${TASK_ID}" 2>/dev/null || echo "")
      fi
      push_notify "leadv2-daemon circuit break: ${fails} consecutive failures (last: ${TASK_ID}). Decision needed at docs/leadv2-decisions/${_LAST_DECISION_ID}.yaml — A=retry B=skip C=pause D=rollback"
      log "CIRCUIT BREAK — paused after $fails consecutive failures, decision=${_LAST_DECISION_ID}"
      _PAUSED_SINCE=$(date +%s)
    fi
  fi

  write_status_file "daemon" "—" "$TASK_ID" "—" "—" "$(get_state_field last_success)"
done
