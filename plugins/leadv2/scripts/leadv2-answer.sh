#!/usr/bin/env bash
# scripts/leadv2-answer.sh — answers a control-plane async question written by
# leadv2-ask.sh (LEAD-ANCHOR-01). Wired to `/leadv2 reply <q-id> <option>` and
# `/leadv2 questions` for control-plane q-ids (format `q-<8 hex chars>`,
# resolved via leadv2-state-path.sh questions — outside any worktree, same
# path from every /leadv2 session of this repo).
#
# NOTE: this is a DIFFERENT store from the older per-task
# `docs/handoff/<task-id>/questions-async/` convention (leadv2-helpers.sh
# leadv2_ask_async / leadv2-reply.sh, needs --task-id) — that one lives
# inside a single worktree and is fine for embedded same-session subagents.
# leadv2-answer.sh is for questions raised by leadv2-ask.sh only. If a q-id
# is not found here, fall back to leadv2-reply.sh --task-id <id> <qid> <opt>.
#
# Usage: leadv2-answer.sh <q-id> <option-label>
#
# Exit codes:
#   0 — answer recorded
#   3 — option not in the question's options[] list
#   4 — already answered
#   5 — question file not found

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  printf -- 'Usage: leadv2-answer.sh <q-id> <option-label>\n' >&2
  exit 1
}

[[ $# -eq 2 ]] || usage
QID="$1"; OPTION="$2"

QDIR="$("${SCRIPT_DIR}/leadv2-state-path.sh" questions)"
QFILE="${QDIR}/${QID}.yaml"
LOCK="${QDIR}/.write.lock"

if [[ ! -f "$QFILE" ]]; then
  printf -- 'Ошибка: вопрос %s не найден (%s)\n' "$QID" "$QFILE" >&2
  exit 5
fi

RESULT="$(python3 - "$QFILE" "$LOCK" "$OPTION" <<'PYEOF'
import datetime
import fcntl, os, sys
import yaml

qfile, lock_path, option = sys.argv[1:4]

lockf = open(lock_path, "a+")
try:
    fcntl.flock(lockf, fcntl.LOCK_EX)
    with open(qfile, encoding="utf-8") as f:
        doc = yaml.safe_load(f) or {}
    if doc.get("status") == "answered":
        print("ALREADY_ANSWERED")
        sys.exit(0)
    labels = [o.get("label") for o in (doc.get("options") or []) if isinstance(o, dict)]
    if option not in labels:
        print("INVALID_OPTION|" + ",".join(str(label) for label in labels))
        sys.exit(0)
    doc["status"] = "answered"
    doc["answer"] = option
    doc["answered_at"] = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    tmp = qfile + f".tmp.{os.getpid()}"
    with open(tmp, "w", encoding="utf-8") as f:
        yaml.safe_dump(doc, f, sort_keys=False)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, qfile)
    print("OK")
finally:
    fcntl.flock(lockf, fcntl.LOCK_UN)
    lockf.close()
PYEOF
)"

case "$RESULT" in
  OK)
    printf -- 'Ответ записан: %s -> %s\n' "$QID" "$OPTION"
    exit 0
    ;;
  ALREADY_ANSWERED)
    printf -- 'Ошибка: вопрос %s уже отвечен\n' "$QID" >&2
    exit 4
    ;;
  INVALID_OPTION*)
    VALID="${RESULT#INVALID_OPTION|}"
    printf -- 'Ошибка: опция "%s" не найдена в вопросе %s. Допустимые: %s\n' "$OPTION" "$QID" "$VALID" >&2
    exit 3
    ;;
  *)
    printf -- 'Ошибка: неожиданный результат: %s\n' "$RESULT" >&2
    exit 1
    ;;
esac
