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
#   leadv2-ask.sh <task-id> "<question>" --option "label|desc" [--option "label|desc" ...] [--timeout <sec=1800>]
#
# Writes <control-plane>/questions/<qid>.yaml:
#   task_id: <task-id>
#   question: <question>
#   options: [{label: <label>, text: <desc>}, ...]
#   asked_at: <ISO8601>
#   status: pending
#   answer: null
#
# Behavior: polls every LEADV2_ASK_POLL_INTERVAL seconds (default 3) until
# status becomes 'answered', then prints the chosen option label to stdout
# and exits 0. On timeout (default 1800s / 30min): prints a clear
# LEADV2_ASK_TIMEOUT marker to stderr and exits 2 — caller should fall back
# to its own best-effort default and note the assumption explicitly.
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

QDIR="$("${SCRIPT_DIR}/leadv2-state-path.sh" questions)"
mkdir -p "$QDIR"
LOCK="${QDIR}/.write.lock"

QID="q-$(python3 -c 'import secrets; print(secrets.token_hex(4))')"
QFILE="${QDIR}/${QID}.yaml"
ASKED_AT="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

# V2 schema (SUPERVISE-V2-01 D-a): schema_version, qid, task_id, phase,
# summary_for_lead, question, options[], priority, asked_at, wait_policy,
# status: pending|answered|cancelled, inline answer object
# (selected/decided_by/answered_at — all null until answered).
python3 - "$QFILE" "$LOCK" "$QID" "$TASK_ID" "$QUESTION" "$ASKED_AT" "$PHASE" "$PRIORITY" "$WAIT_POLICY" "${OPTIONS[@]}" <<'PYEOF'
import fcntl, os, sys
import yaml

qfile, lock_path, qid, task_id, question, asked_at, phase, priority, wait_policy = sys.argv[1:10]
raw_options = sys.argv[10:]

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

printf -- '[leadv2-ask] qid=%s task_id=%s file=%s\n' "$QID" "$TASK_ID" "$QFILE" >&2

if [[ "$NO_BLOCK" -eq 1 ]]; then
  printf -- '%s\n' "$QID"
  exit 0
fi

POLL_INTERVAL="${LEADV2_ASK_POLL_INTERVAL:-3}"
DEADLINE=$(( $(date +%s) + TIMEOUT ))

while [[ "$(date +%s)" -lt "$DEADLINE" ]]; do
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
  sleep "$POLL_INTERVAL"
done

printf -- 'LEADV2_ASK_TIMEOUT qid=%s task_id=%s\n' "$QID" "$TASK_ID" >&2
exit 2
