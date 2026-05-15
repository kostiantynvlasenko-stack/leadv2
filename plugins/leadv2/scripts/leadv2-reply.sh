#!/usr/bin/env bash
# leadv2-reply.sh — handles /leadv2 reply command.
# Usage: leadv2-reply.sh --task-id <id> <qid> <option>
# Writes docs/handoff/<task_id>/questions-async/<qid>-answered.yaml atomically.
# Uses ln sentinel for atomic write (mv -n is NOT atomic on macOS).
#
# Exit codes:
#   0 — answer recorded successfully
#   3 — invalid option (not ^[a-z]$ or not in pending YAML options list)
#   4 — question already answered (concurrent write or duplicate call)
#   5 — pending question file not found

set -uo pipefail

usage() {
  printf -- 'Usage: leadv2-reply.sh --task-id <id> <qid> <option>\n' >&2
  exit 1
}

# Parse --task-id flag + positional args
TASK_ID=""
QID=""
OPTION=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --task-id)
      [[ $# -ge 2 ]] || { printf -- 'Ошибка: --task-id требует значение\n' >&2; exit 1; }
      TASK_ID="$2"
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

# Validate required args
if [[ -z "$TASK_ID" ]]; then
  printf -- 'Ошибка: --task-id обязателен\n' >&2
  usage
fi
if [[ -z "$QID" ]] || [[ -z "$OPTION" ]]; then
  printf -- 'Ошибка: qid и option обязательны\n' >&2
  usage
fi

# Validate option: must be single lowercase letter ^[a-z]$
if [[ ! "$OPTION" =~ ^[a-z]$ ]]; then
  printf -- 'Ошибка: опция должна быть одной буквой (a-z)\n' >&2
  exit 3
fi

# Resolve paths
PROJECT_ROOT="${LEADV2_PROJECT_ROOT:-${PROJECT_ROOT:-$(pwd)}}"
ASYNC_DIR="$PROJECT_ROOT/docs/handoff/$TASK_ID/questions-async"
PENDING="$ASYNC_DIR/${QID}-pending.yaml"
ANSWERED="$ASYNC_DIR/${QID}-answered.yaml"

# Check pending file exists
if [[ ! -f "$PENDING" ]]; then
  printf -- 'Ошибка: вопрос %s не найден (файл %s отсутствует)\n' "$QID" "$PENDING" >&2
  exit 5
fi

# Check already answered
if [[ -f "$ANSWERED" ]]; then
  printf -- 'Ошибка: вопрос %s уже отвечен\n' "$QID" >&2
  exit 4
fi

# Validate option exists in pending YAML options[] array
# Try yq first, fall back to python3, then grep
_option_valid=0

if command -v yq >/dev/null 2>&1; then
  # yq v4 style: .options[].label
  valid_opts="$(yq e '.options[].label' "$PENDING" 2>/dev/null || true)"
  if printf -- '%s\n' "$valid_opts" | grep -qx "$OPTION"; then
    _option_valid=1
  else
    # yq v3 style fallback
    valid_opts="$(yq r "$PENDING" 'options[*].label' 2>/dev/null || true)"
    if printf -- '%s\n' "$valid_opts" | grep -qx "$OPTION"; then
      _option_valid=1
    fi
  fi
elif command -v python3 >/dev/null 2>&1; then
  _option_valid="$(python3 - "$PENDING" "$OPTION" <<'PYEOF'
import sys, yaml
data = yaml.safe_load(open(sys.argv[1]))
opts = data.get("options", [])
labels = [str(o.get("label","")) for o in opts] if isinstance(opts, list) else []
print("1" if sys.argv[2] in labels else "0")
PYEOF
  )"
else
  # Fallback: grep for "label: <option>" pattern — less precise but safe
  if grep -qE "^\s*label:\s*['\"]?${OPTION}['\"]?\s*$" "$PENDING" 2>/dev/null; then
    _option_valid=1
  fi
fi

if [[ "$_option_valid" != "1" ]]; then
  # Build list of valid options for the error message
  valid_list=""
  if command -v yq >/dev/null 2>&1; then
    valid_list="$(yq e '.options[].label' "$PENDING" 2>/dev/null | tr '\n' ',' | sed 's/,$//' || true)"
  elif command -v python3 >/dev/null 2>&1; then
    valid_list="$(python3 - "$PENDING" <<'PYEOF'
import sys, yaml
data = yaml.safe_load(open(sys.argv[1]))
opts = data.get("options", [])
labels = [str(o.get("label","")) for o in opts] if isinstance(opts, list) else []
print(", ".join(labels))
PYEOF
    )"
  else
    valid_list="(не удалось определить)"
  fi
  printf -- 'Ошибка: опция "%s" не найдена в вопросе %s. Допустимые варианты: %s\n' \
    "$OPTION" "$QID" "$valid_list" >&2
  exit 3
fi

# Atomic write via ln sentinel
LOCK_FILE="${ANSWERED}.lock"
TMP="$(mktemp)"

# Write answered YAML to temp file
ANSWERED_AT="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
cat > "$TMP" << YAML_EOF
task_id: ${TASK_ID}
qid: ${QID}
chosen: ${OPTION}
decided_by: founder
answered_at: "${ANSWERED_AT}"
YAML_EOF

# Atomic move via ln sentinel (ln is atomic on POSIX; mv -n is NOT on macOS)
if ln "$TMP" "$LOCK_FILE" 2>/dev/null; then
  mv "$TMP" "$ANSWERED"
  rm -f "$LOCK_FILE"
else
  rm -f "$TMP"
  printf -- 'Ошибка: вопрос уже отвечен (concurrent write)\n' >&2
  exit 4
fi

printf -- 'Ответ записан: вариант %s\n' "$OPTION"
exit 0
