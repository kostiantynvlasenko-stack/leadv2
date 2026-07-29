#!/usr/bin/env bash
# scripts/leadv2-reply-router.sh — single entry point for `/leadv2 reply
# <q-id> <option>`. LANE-QUESTION-DELIVERY-01.
#
# THE GAP this closes: the question channel has always had TWO stores (see
# leadv2-ask.sh / leadv2-answer.sh header comments, and the leadv2-supervise
# SKILL.md "Async question channel" section):
#   - control-plane  <state-root>/questions/<qid>.yaml   — canonical for
#     fanned-out/adopted lanes (leadv2-ask.sh writes, leadv2-answer.sh answers)
#   - legacy-handoff docs/handoff/<task_id>/questions-async/<qid>-pending.yaml
#     — worktree-local, embedded same-session subagents (leadv2-reply.sh)
# But the documented `/leadv2 reply` PROCEDURE (docs/phases.md §Invocation)
# only ever looked in the legacy-handoff store. A control-plane q-id — which
# is what every fanned-out lane actually uses — had no path to an answer at
# all: the lead would grep docs/handoff/*/questions-async/*-pending.yaml,
# find nothing, and hard-fail "not found", even though the question was
# sitting right there in the control-plane store waiting. This script
# resolves BOTH stores and dispatches to whichever one actually holds the
# qid, so `/leadv2 reply` works regardless of which store asked the question.
#
# Usage:
#   leadv2-reply-router.sh <q-id> <option> [--task-id <id>]
#
# --task-id is optional: only needed as a disambiguation hint for the
# legacy-handoff store if the same qid string were ever found under more
# than one task-id directory (should not happen — qids are random per
# leadv2_ask_async, but this keeps the caller's existing --task-id knowledge
# useful instead of discarding it).
#
# Exit codes (mirrors the underlying scripts so callers need no new cases):
#   0 — answer recorded successfully
#   3 — invalid option (not in the question's options[] list)
#   4 — question already answered
#   5 — question id not found in either store
#   1 — usage / unexpected error

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  printf -- 'Usage: leadv2-reply-router.sh <q-id> <option> [--task-id <id>]\n' >&2
  exit 1
}

QID=""
OPTION=""
TASK_ID_HINT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --task-id)
      [[ $# -ge 2 ]] || { printf -- 'Ошибка: --task-id требует значение\n' >&2; exit 1; }
      TASK_ID_HINT="$2"
      shift 2
      ;;
    --*)
      printf -- 'Ошибка: неизвестный флаг %s\n' "$1" >&2
      usage
      ;;
    *)
      if [[ -z "$QID" ]]; then
        QID="$1"
      elif [[ -z "$OPTION" ]]; then
        OPTION="$1"
      else
        printf -- 'Ошибка: лишний аргумент %s\n' "$1" >&2
        usage
      fi
      shift
      ;;
  esac
done

[[ -n "$QID" && -n "$OPTION" ]] || usage

PROJECT_ROOT="${LEADV2_PROJECT_ROOT:-${PROJECT_ROOT:-$(pwd)}}"

# ── Try control-plane store first (canonical for fanned-out/adopted lanes) ──
CP_QUESTIONS_DIR="$(bash "${SCRIPT_DIR}/leadv2-state-path.sh" questions 2>/dev/null || true)"
CP_FILE=""
if [[ -n "$CP_QUESTIONS_DIR" && -f "${CP_QUESTIONS_DIR}/${QID}.yaml" ]]; then
  CP_FILE="${CP_QUESTIONS_DIR}/${QID}.yaml"
fi

# ── Try legacy-handoff store (worktree-local, embedded same-session subagents) ──
LEGACY_MATCHES=()
if [[ -n "$TASK_ID_HINT" ]]; then
  cand="${PROJECT_ROOT}/docs/handoff/${TASK_ID_HINT}/questions-async/${QID}-pending.yaml"
  [[ -f "$cand" ]] && LEGACY_MATCHES+=("$cand")
else
  while IFS= read -r -d '' f; do
    LEGACY_MATCHES+=("$f")
  done < <(find "${PROJECT_ROOT}/docs/handoff" -maxdepth 3 -type f \
              -path "*/questions-async/${QID}-pending.yaml" -print0 2>/dev/null)
fi

if [[ -n "$CP_FILE" && ${#LEGACY_MATCHES[@]} -gt 0 ]]; then
  printf -- 'Ошибка: qid %s найден в ОБОИХ хранилищах (control-plane: %s; legacy: %s) — это не должно происходить, коллизия id. Прекращаю без ответа.\n' \
    "$QID" "$CP_FILE" "${LEGACY_MATCHES[0]}" >&2
  exit 1
fi

if [[ -n "$CP_FILE" ]]; then
  exec bash "${SCRIPT_DIR}/leadv2-answer.sh" "$QID" "$OPTION"
fi

if [[ ${#LEGACY_MATCHES[@]} -eq 1 ]]; then
  legacy_file="${LEGACY_MATCHES[0]}"
  # .../docs/handoff/<task_id>/questions-async/<qid>-pending.yaml
  task_id="$(basename "$(dirname "$(dirname "$legacy_file")")")"
  exec bash "${SCRIPT_DIR}/leadv2-reply.sh" --task-id "$task_id" "$QID" "$OPTION"
fi

if [[ ${#LEGACY_MATCHES[@]} -gt 1 ]]; then
  printf -- 'Ошибка: qid %s найден в НЕСКОЛЬКИХ legacy-задачах (%s) — укажите --task-id.\n' \
    "$QID" "$(IFS=,; echo "${LEGACY_MATCHES[*]}")" >&2
  exit 1
fi

printf -- 'Ошибка: вопрос %s не найден ни в control-plane хранилище (%s/%s.yaml), ни в legacy-хранилище (docs/handoff/*/questions-async/%s-pending.yaml). Возможно, id указан неверно, вопрос уже отвечен и архивирован, или его задающая сессия давно завершилась и он был поглощён при абсорбции orphan-состояния.\n' \
  "$QID" "${CP_QUESTIONS_DIR:-<control-plane unresolved>}" "$QID" "$QID" >&2
exit 5
