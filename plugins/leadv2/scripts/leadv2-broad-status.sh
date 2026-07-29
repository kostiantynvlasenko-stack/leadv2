#!/usr/bin/env bash
# leadv2-broad-status.sh — compose the 30-minute founder status outside the
# supervisor context.  One collector run + exactly one Haiku call per beat.
# Rollback: LEADV2_SUPERVISE_BROAD_STATUS_S=0 disables the loop beat.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${LEADV2_PROJECT_ROOT:-${CLAUDE_PROJECT_DIR:-$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || true)}}"
if [[ -z "$PROJECT_ROOT" ]]; then
  printf '[broad-status] root_error: set LEADV2_PROJECT_ROOT or run inside a git worktree\n' >&2
  exit 1
fi
export LEADV2_PROJECT_ROOT="$PROJECT_ROOT"

STATE_PATH_SH="$SCRIPT_DIR/leadv2-state-path.sh"
LOG_FILE="$(PROJECT_ROOT="$PROJECT_ROOT" "$STATE_PATH_SH" supervise-loop.log)"
SNAPSHOT_PATH="${LEADV2_BROAD_STATUS_SNAPSHOT_PATH:-$PROJECT_ROOT/docs/leadv2/status-snapshot.json}"
COLLECTOR_SH="${LEADV2_STATUS_COLLECTOR_BIN:-$SCRIPT_DIR/leadv2-status-collector.sh}"
CLAUDE_BIN="${LEADV2_BROAD_STATUS_CLAUDE_BIN:-claude}"

mkdir -p "$(dirname "$LOG_FILE")"

if ! bash "$COLLECTOR_SH" --project-root "$PROJECT_ROOT" --out "$SNAPSHOT_PATH" >/dev/null 2>&1; then
  printf '%s [BROAD_STATUS] collection failure: quality read unavailable\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$LOG_FILE"
  exit 0
fi

PROMPT="$(python3 - "$SNAPSHOT_PATH" <<'PY'
import json, sys
snapshot = json.load(open(sys.argv[1], encoding='utf-8'))
print('''Ты пишешь готовый 30-минутный статус для основателя. Верни только простой русский текст, без Markdown-заголовков, JSON, идентификаторов задач, названий файлов и технического жаргона.\n\nСкажи по каждой активной работе: что она решает для продукта, состояние (идёт/готово/упало), кто и в каком формате работает. Укажи вопросы, требующие решения, дословно и с рекомендацией. Дай честный раздел о сегодняшнем опубликованном тексте и качестве выбранных целей, используя только предоставленные сырые факты; если данных нет или секция неуспешна, прямо скажи, что качество недоступно. Отдельно укажи долю выполненных уже наступивших слотов. Не придумывай сравнение с прошлым статусом, если его нет в фактах.\n\nСтоимость разрешено описывать ТОЛЬКО как использование лимитов 5-часового и недельного окна. Никогда не упоминай деньги, валюту или доллары.\n\nФакты:\n''' + json.dumps(snapshot, ensure_ascii=False))
PY
)"

RAW="$("$CLAUDE_BIN" -p "$PROMPT" --model haiku --max-turns 1 --permission-mode bypassPermissions --output-format json 2>/dev/null)" || RAW=""
STATUS="$(python3 - "$RAW" <<'PY'
import json, sys
try:
    d = json.loads(sys.argv[1])
    text = d.get('result') if isinstance(d, dict) else None
    if isinstance(text, str) and text.strip():
        print(text.strip())
except Exception:
    pass
PY
)"

if [[ -z "$STATUS" ]]; then
  STATUS="$(python3 - "$SNAPSHOT_PATH" <<'PY'
import json, sys
s = json.load(open(sys.argv[1], encoding='utf-8')).get('sections', {})
lanes = s.get('lanes', {})
facts = s.get('repo_facts', {})
print('Сводка собрана, но текстовый обзор качества недоступен. '
      f"Рабочие линии: {'доступны' if lanes.get('ok') else 'недоступны'}. "
      f"Данные продукта: {'доступны' if facts.get('ok') else 'недоступны'}.")
PY
)"
fi

{
  printf '%s [BROAD_STATUS]\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '%s\n' "$STATUS"
  printf '[BROAD_STATUS_END]\n'
} >>"$LOG_FILE"
