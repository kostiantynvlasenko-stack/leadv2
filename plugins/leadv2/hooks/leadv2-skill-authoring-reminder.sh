#!/usr/bin/env bash
# leadv2-skill-authoring-reminder.sh — PreToolUse:Write|Edit advisory hook.
#
# Fires when a Write/Edit targets a */skills/*/SKILL.md path. Prints a
# stderr reminder to consult the `writing-great-skills` skill before
# shipping a new/changed skill file. Advisory only — NEVER blocks.
#
# Modeled on leadv2-plugin-sync-drift-warn.sh (diagnostic PostToolUse hook)
# and the file_path-extraction pattern from leadv2-verdict-format-guard.sh.
#
# Silent exit 0 when:
#   - stdin is empty / malformed
#   - tool_input.file_path is empty or doesn't match */skills/*/SKILL.md

set -euo pipefail
trap 'exit 0' ERR

INPUT="$(cat 2>/dev/null || true)"
[[ -z "$INPUT" ]] && exit 0

FILE_PATH="$(printf '%s' "$INPUT" | python3 -c "
import sys, json
try:
    r = json.loads(sys.stdin.read())
    print(r.get('tool_input', {}).get('file_path', ''))
except Exception:
    pass
" 2>/dev/null || true)"

[[ -z "$FILE_PATH" ]] && exit 0

case "$FILE_PATH" in
  */skills/*/SKILL.md) ;;
  *) exit 0 ;;
esac

printf -- '[leadv2-skill-authoring-reminder] Editing a SKILL.md (%s). Consult the "writing-great-skills" skill first -- determinism/vocabulary/model-vs-user-invocation checklist. Advisory only, not blocking.\n' "${FILE_PATH}" >&2

exit 0
