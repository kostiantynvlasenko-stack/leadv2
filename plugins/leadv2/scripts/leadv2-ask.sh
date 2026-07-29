#!/usr/bin/env bash
# scripts/leadv2-ask.sh — LEAD-ANCHOR-01 async question channel (fanout gap fix).
#
# THE GAP: fanned-out /leadv2 sessions each run in their OWN `git worktree add`
# checkout + own Terminal window. Calling AskUserQuestion there prompts on a
# screen nobody is watching (the founder watches the SUPERVISING lead's
# window; leadv2-supervise.sh only ever reads the control plane, never a
# worktree-private docs/handoff copy — see leadv2-state-path.sh header,
# LEAD-CONTROL-PLANE-01). This script is the fix: it writes the question to
# the TRUE control-plane `questions/` dir — resolved via leadv2-state-path.sh,
# OUTSIDE any worktree, identical from every session of this repo — then
# BLOCKS until answered (via leadv2-answer.sh / `/leadv2 reply`).
#
# Usage:
#   leadv2-ask.sh <task-id> "<question>" --option "label|desc" [--option "label|desc" ...] [--default-option <label>] [--timeout <sec=1800>]
#
# Writes <control-plane>/questions/<qid>.yaml:
#   task_id: <task-id>
#   question: <question>
#   options: [{label: <label>, text: <desc>}, ...]
#   default_option: <label|null>         # reversible timeout choice, if any
#   asked_at: <ISO8601>
#   status: pending
#   answer: null
#
# Behavior: polls every LEADV2_ASK_POLL_INTERVAL seconds (default 3) until
# status becomes 'answered', then prints the chosen option label to stdout
# and exits 0. On timeout, a declared --default-option is recorded in the
# question, journal, and open-threads, then printed to stdout and exited 0.
# Without one, the task is parked human-needed and unclaimed (freeing the
# pump slot), then exits 2. A timeout is never invisible.
#
# DEGRADE (QUESTION-BRIDGE-01): if the control-plane WRITE itself fails — e.g.
# a stricter per-process sandbox denies flock()/open()/os.replace() on the
# control plane (observed for some agent/provider launch paths) — this script
# degrades instead of crashing (set -euo pipefail would otherwise abort the
# whole calling session). Failure is detected by the python process's EXIT
# CODE (D3), never by parsing stderr text. On control-plane failure it falls
# back to the SAME legacy local schema leadv2_ask_async() writes
# (docs/handoff/<task_id>/questions-async/<qid>-pending.yaml — what
# leadv2-reply.sh already answers) and polls that sibling -answered.yaml.
# If even that local write throws, it prints a greppable
# LEADV2_ASK_DEGRADED_TO_DEFAULT marker to stderr, prints the FIRST --option
# label to stdout, and exits 0 — turning a session-killing crash into, at
# worst, a silently-auto-decided default.
#
# Env overrides (test sandboxing — same convention as leadv2-bus.sh):
#   LEADV2_STATE_ROOT / LEADV2_STATE_BASE / PROJECT_ROOT — see leadv2-state-path.sh
#   LEADV2_ASK_POLL_INTERVAL — seconds between polls (tests use small values)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  printf -- 'Usage: leadv2-ask.sh <task-id> "<question>" --option "label|desc" [--option ...] [--timeout <sec=1800>]\n' >&2
  exit 1
}

[[ $# -ge 3 ]] || usage

TASK_ID="$1"; QUESTION="$2"; shift 2

OPTIONS=()
TIMEOUT=1800
PHASE=""
PRIORITY="normal"
WAIT_POLICY="blocking"
NO_BLOCK=0
DEFAULT_OPTION=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --option)
      [[ $# -ge 2 ]] || usage
      OPTIONS+=("$2")
      shift 2
      ;;
    --timeout)
      [[ $# -ge 2 ]] || usage
      TIMEOUT="$2"
      shift 2
      ;;
    --default-option)
      [[ $# -ge 2 ]] || usage
      DEFAULT_OPTION="$2"
      shift 2
      ;;
    --phase)
      [[ $# -ge 2 ]] || usage
      PHASE="$2"
      shift 2
      ;;
    --priority)
      [[ $# -ge 2 ]] || usage
      PRIORITY="$2"
      shift 2
      ;;
    --wait-policy)
      [[ $# -ge 2 ]] || usage
      WAIT_POLICY="$2"
      shift 2
      ;;
    --no-block)
      # Write the V2 record and print the qid immediately — skip the poll
      # loop. Used by leadv2_ask_async's compat wrapper (leadv2-helpers.sh),
      # which owns its own non-blocking/auto-decide semantics and only wants
      # this script's V2 control-plane write for cross-worktree visibility.
      NO_BLOCK=1
      shift
      ;;
    *)
      printf -- '[leadv2-ask] unknown arg: %s\n' "$1" >&2
      usage
      ;;
  esac
done

if [[ "${#OPTIONS[@]}" -lt 1 ]]; then
  printf -- '[leadv2-ask] at least one --option required\n' >&2
  usage
fi

if [[ -n "$DEFAULT_OPTION" ]]; then
  DEFAULT_OPTION="${DEFAULT_OPTION#"${DEFAULT_OPTION%%[![:space:]]*}"}"
  DEFAULT_OPTION="${DEFAULT_OPTION%"${DEFAULT_OPTION##*[![:space:]]}"}"
  _default_found=0
  for _raw_option in "${OPTIONS[@]}"; do
    _option_label="${_raw_option%%|*}"
    _option_label="${_option_label#"${_option_label%%[![:space:]]*}"}"
    _option_label="${_option_label%"${_option_label##*[![:space:]]}"}"
    [[ "$_option_label" == "$DEFAULT_OPTION" ]] && _default_found=1
  done
  [[ "$_default_found" -eq 1 ]] || { printf -- '[leadv2-ask] --default-option must name an --option label\n' >&2; exit 1; }
fi

QDIR="$("${SCRIPT_DIR}/leadv2-state-path.sh" questions)"
LOCK="${QDIR}/.write.lock"

QID="q-$(python3 -c 'import secrets; print(secrets.token_hex(4))')"
QFILE="${QDIR}/${QID}.yaml"
ASKED_AT="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

# Legacy fallback store — the SAME schema leadv2_ask_async() (leadv2-helpers.sh)
# writes and leadv2-reply.sh answers. Resolved with the same PROJECT_ROOT
# precedence leadv2-reply.sh uses (LEADV2_PROJECT_ROOT > PROJECT_ROOT > pwd) so
# a subsequent /leadv2 reply finds exactly what we wrote. Reached only when the
# control-plane write below fails (sandbox EPERM / unwritable control plane).
LEGACY_PROJECT_ROOT="${LEADV2_PROJECT_ROOT:-${PROJECT_ROOT:-$(pwd)}}"
LEGACY_DIR="${LEGACY_PROJECT_ROOT}/docs/handoff/${TASK_ID}/questions-async"
LEGACY_PENDING="${LEGACY_DIR}/${QID}-pending.yaml"
LEGACY_ANSWERED="${LEGACY_DIR}/${QID}-answered.yaml"

STORE="v2"

# V2 control-plane write (SUPERVISE-V2-01 D-a). Detect failure by the python
# process's own exit code (QUESTION-BRIDGE-01 D3) — never by parsing stderr.
# mkdir + write are chained with `&&` inside the `if !` guard so the FIRST
# failure (unwritable control-plane root under sandbox EPERM, or an
# OSError/PermissionError from open()/flock()/os.replace()) jumps to the legacy
# fallback instead of aborting the whole script under `set -euo pipefail`.
if ! {
  mkdir -p "$QDIR" &&
  python3 - "$QFILE" "$LOCK" "$QID" "$TASK_ID" "$QUESTION" "$ASKED_AT" "$PHASE" "$PRIORITY" "$WAIT_POLICY" "$DEFAULT_OPTION" "${OPTIONS[@]}" <<'PYEOF'
import fcntl, os, sys
import yaml

qid, task_id, question, asked_at, phase, priority, wait_policy, default_option = sys.argv[3:11]
qfile, lock_path = sys.argv[1:3]
raw_options = sys.argv[11:]

options = []
for raw in raw_options:
    if "|" in raw:
        label, text = raw.split("|", 1)
    else:
        label, text = raw, raw
    options.append({"label": label.strip(), "text": text.strip()})

doc = {
    "schema_version": 2,
    "qid": qid,
    "task_id": task_id,
    "phase": phase or None,
    "summary_for_lead": question[:60],
    "question": question,
    "options": options,
    "default_option": default_option or None,
    "priority": priority or "normal",
    "asked_at": asked_at,
    "wait_policy": wait_policy or "blocking",
    "status": "pending",
    "answer": {"selected": None, "decided_by": None, "answered_at": None},
}

lockf = open(lock_path, "a+")
try:
    fcntl.flock(lockf, fcntl.LOCK_EX)
    tmp = qfile + f".tmp.{os.getpid()}"
    with open(tmp, "w", encoding="utf-8") as f:
        yaml.safe_dump(doc, f, sort_keys=False)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, qfile)
finally:
    fcntl.flock(lockf, fcntl.LOCK_UN)
    lockf.close()
PYEOF
} ; then
  printf -- '[leadv2-ask] control-plane write failed (sandbox EPERM?); falling back to legacy handoff store\n' >&2

  # Legacy local write — mirrors leadv2_ask_async()'s schema exactly. stderr is
  # captured only to surface the exception CLASS as the degrade reason; the
  # failure SIGNAL is still the exit code (D3), stderr text is informational.
  LEGACY_ERR_FILE="$(mktemp)"
  if ! {
    mkdir -p "$LEGACY_DIR" &&
    python3 - "$LEGACY_PENDING" "$QID" "$TASK_ID" "$PHASE" "$QUESTION" "$ASKED_AT" "$DEFAULT_OPTION" "${OPTIONS[@]}" <<'PYEOF'
import os, sys, yaml

pending, qid, task_id, phase, question, created_at, default_option = sys.argv[1:8]
raw_options = sys.argv[8:]

options = []
for raw in raw_options:
    if "|" in raw:
        label, text = raw.split("|", 1)
    else:
        label, text = raw, raw
    options.append({"label": label.strip(), "text": text.strip()})

doc = {
    "task_id": task_id,
    "phase": phase or None,
    "qid": qid,
    "summary_for_lead": question[:60],
    "question": question,
    "options": options,
    "default_option": default_option or None,
    "auto_decide_after": None,
    "wait_indefinitely": False,
    "priority": "P1",
    "created_at": created_at,
}

try:
    tmp = pending + ".tmp.%d" % os.getpid()
    with open(tmp, "w", encoding="utf-8") as f:
        yaml.safe_dump(doc, f, sort_keys=False, allow_unicode=True)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, pending)
except Exception as e:
    sys.stderr.write("LEADV2_ASK_LEGACY_REASON=%s\n" % type(e).__name__)
    sys.exit(1)
PYEOF
  } 2>"$LEGACY_ERR_FILE" ; then
    # Even the legacy local write threw — do NOT crash. State the first option
    # as the default and exit 0 (stated-default degrade, not a timeout/exit 2).
    FIRST_OPT_LABEL="${OPTIONS[0]%%|*}"
    FIRST_OPT_LABEL="${FIRST_OPT_LABEL#"${FIRST_OPT_LABEL%%[![:space:]]*}"}"
    FIRST_OPT_LABEL="${FIRST_OPT_LABEL%"${FIRST_OPT_LABEL##*[![:space:]]}"}"
    # `|| true`: grep exits 1 on no match (e.g. mkdir failed before python ran,
    # so no LEADV2_ASK_LEGACY_REASON line) — without it `set -o pipefail` would
    # abort the degrade path here. REASON defaults to legacy_write_failed below.
    REASON="$(grep -oE 'LEADV2_ASK_LEGACY_REASON=[A-Za-z0-9_]+' "$LEGACY_ERR_FILE" | tail -1 | cut -d= -f2- || true)"
    [[ -z "${REASON:-}" ]] && REASON="legacy_write_failed"
    rm -f "$LEGACY_ERR_FILE"
    printf -- 'LEADV2_ASK_DEGRADED_TO_DEFAULT task_id=%s qid=%s reason=%s\n' "$TASK_ID" "$QID" "$REASON" >&2
    printf -- '%s\n' "$FIRST_OPT_LABEL"
    exit 0
  fi
  rm -f "$LEGACY_ERR_FILE"
  STORE="legacy"
  printf -- '[leadv2-ask] qid=%s task_id=%s file=%s (legacy fallback)\n' "$QID" "$TASK_ID" "$LEGACY_PENDING" >&2
else
  printf -- '[leadv2-ask] qid=%s task_id=%s file=%s\n' "$QID" "$TASK_ID" "$QFILE" >&2
fi

if [[ "$NO_BLOCK" -eq 1 ]]; then
  printf -- '%s\n' "$QID"
  exit 0
fi

POLL_INTERVAL="${LEADV2_ASK_POLL_INTERVAL:-3}"
DEADLINE=$(( $(date +%s) + TIMEOUT ))

while [[ "$(date +%s)" -lt "$DEADLINE" ]]; do
  if [[ "$STORE" == "legacy" ]]; then
    # Legacy fallback: poll the sibling -answered.yaml leadv2-reply.sh writes
    # and read its `chosen` field (terminal answer for this store).
    if [[ -f "$LEGACY_ANSWERED" ]]; then
      CHOSEN="$(python3 -c '
import sys, yaml
try:
    d = yaml.safe_load(open(sys.argv[1], encoding="utf-8")) or {}
except Exception:
    d = {}
print(d.get("chosen", "") or "")
' "$LEGACY_ANSWERED" 2>/dev/null || true)"
      if [[ -n "$CHOSEN" ]]; then
        printf -- '%s\n' "$CHOSEN"
        exit 0
      fi
    fi
  else
    STATUS_AND_ANSWER="$(python3 - "$QFILE" <<'PYEOF'
import sys
import yaml
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        doc = yaml.safe_load(f) or {}
except FileNotFoundError:
    print("missing|")
    sys.exit(0)
ans = doc.get("answer")
selected = (ans or {}).get("selected") if isinstance(ans, dict) else ans  # tolerate pre-V2 flat scalar
print(f"{doc.get('status', 'pending')}|{selected or ''}")
PYEOF
)"
    STATUS="${STATUS_AND_ANSWER%%|*}"
    ANSWER="${STATUS_AND_ANSWER#*|}"
    if [[ "$STATUS" == "answered" ]]; then
      printf -- '%s\n' "$ANSWER"
      exit 0
    fi
  fi
  sleep "$POLL_INTERVAL"
done

_timeout_record() { # $1=status $2=selected-or-empty $3=decision-text
  local status="$1" selected="$2" decision="$3"
  if [[ "$STORE" == "v2" ]]; then
    python3 - "$QFILE" "$status" "$selected" "$decision" <<'PYEOF' || true
import datetime, os, sys, yaml
p, status, selected, decision = sys.argv[1:]
try:
    with open(p, encoding="utf-8") as f: doc = yaml.safe_load(f) or {}
    doc["status"] = status
    doc["answer"] = {"selected": selected or None, "decided_by": decision,
                     "answered_at": datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")}
    tmp = p + ".timeout.%d" % os.getpid()
    with open(tmp, "w", encoding="utf-8") as f:
        yaml.safe_dump(doc, f, sort_keys=False); f.flush(); os.fsync(f.fileno())
    os.replace(tmp, p)
except Exception:
    pass
PYEOF
  fi
}

_journal_timeout() { # $1=text
  CLAUDE_PROJECT_ROOT="$LEGACY_PROJECT_ROOT" bash "${SCRIPT_DIR}/leadv2-journal.sh" append "$TASK_ID" decision "$1" \
    >/dev/null 2>&1 || true
}

_open_thread_timeout() { # $1=text
  local threads
  threads="$(PROJECT_ROOT="$LEGACY_PROJECT_ROOT" "${SCRIPT_DIR}/leadv2-state-path.sh" open-threads.md 2>/dev/null || true)"
  [[ -n "$threads" ]] || return 0
  printf -- '- [ ] %s — ask-timeout: task %s qid %s %s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$TASK_ID" "$QID" "$1" >>"$threads" 2>/dev/null || true
}

if [[ -n "$DEFAULT_OPTION" ]]; then
  _timeout_record timed_out "$DEFAULT_OPTION" timeout_default
  _journal_timeout "ask-timeout qid=${QID} default_option=${DEFAULT_OPTION}; proceeded on reversible default"
  _open_thread_timeout "timed out; proceeded on default_option=${DEFAULT_OPTION} (follow-up visible)"
  printf -- 'LEADV2_ASK_TIMEOUT_DEFAULT qid=%s task_id=%s default_option=%s\n' "$QID" "$TASK_ID" "$DEFAULT_OPTION" >&2
  printf -- '%s\n' "$DEFAULT_OPTION"
  exit 0
fi

_timeout_record timed_out_human_needed "" timeout_no_default
_journal_timeout "ask-timeout qid=${QID} no default_option; parked human-needed and released slot"
_open_thread_timeout "timed out with no default_option; parked human-needed and released slot"
if [[ -f "${SCRIPT_DIR}/leadv2-tasks-lib.sh" ]]; then
  # shellcheck source=leadv2-tasks-lib.sh
  PROJECT_ROOT="$LEGACY_PROJECT_ROOT" source "${SCRIPT_DIR}/leadv2-tasks-lib.sh"
  leadv2_tasks_update "$TASK_ID" --key lane --value human-needed >/dev/null 2>&1 || true
  leadv2_tasks_unclaim "$TASK_ID" >/dev/null 2>&1 || true
fi
printf -- 'LEADV2_ASK_TIMEOUT_HUMAN_NEEDED qid=%s task_id=%s\n' "$QID" "$TASK_ID" >&2
exit 2
