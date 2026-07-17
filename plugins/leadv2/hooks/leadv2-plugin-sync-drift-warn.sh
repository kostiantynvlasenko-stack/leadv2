#!/usr/bin/env bash
# leadv2-plugin-sync-drift-warn.sh — PostToolUse:Bash diagnostic hook
# (PLUGIN-CACHE-THIRD-COPY-REVERTS-FIXES-01).
#
# Fires after any Bash command invoking leadv2-plugin-sync.sh. Runs the
# 5-way drift-guard and WARNS (never blocks — continueOnBlock: true in
# hooks.json) if the copies still diverge after a sync. This is a
# diagnostic-only surface: today's incident (4 fixes silently reverted)
# was invisible for an hour precisely because nothing surfaced drift after
# a sync ran. A loud warning here is strictly better than silence, even
# though it cannot itself fix anything.
#
# Silent exit 0 when:
#   - stdin is empty / malformed
#   - the Bash command didn't invoke leadv2-plugin-sync.sh
#   - leadv2-drift-guard.sh is not found (older canonical checkout)

set -euo pipefail
trap 'exit 0' ERR

INPUT="$(cat 2>/dev/null || true)"
[[ -z "$INPUT" ]] && exit 0

CMD="$(printf '%s' "$INPUT" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('tool_input', {}).get('command', ''))
except Exception:
    print('')
" 2>/dev/null || true)"

case "$CMD" in
  *leadv2-plugin-sync.sh*) ;;  # match
  *) exit 0 ;;
esac

CANONICAL_ROOT="${LEADV2_CANONICAL_ROOT:-${HOME}/Projects/leadv2}"
_DRIFT_GUARD="${CANONICAL_ROOT}/plugins/leadv2/scripts/leadv2-drift-guard.sh"
[[ -f "${_DRIFT_GUARD}" ]] || exit 0

if ! bash "${_DRIFT_GUARD}" --quiet 2>/tmp/leadv2-drift-warn-detail.log; then
  printf -- '[leadv2-plugin-sync-drift-warn] WARNING: leadv2-plugin-sync.sh just ran but the 5 script copies still diverge. Details: /tmp/leadv2-drift-warn-detail.log (re-run: bash %s)\n' "${_DRIFT_GUARD}" >&2
fi

exit 0
