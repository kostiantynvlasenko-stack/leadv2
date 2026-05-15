#!/usr/bin/env bash
# Stop hook: prompt for /clear when a leadv2 task just closed.
# Detects via phase11-passed.flag (m3) or phase8-passed.flag (persona-engine).
set -euo pipefail
trap 'echo "[$(basename "$0")] error at line $LINENO" >&2; exit 0' ERR

INPUT="$(cat 2>/dev/null || true)"
CWD="$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || echo "")"
[[ -z "$CWD" ]] && CWD="$PWD"

# Find any phase{8,11}-passed.flag younger than 5 minutes
FOUND=""
for flag in $(find "$CWD/.claude/leadv2-tasks" "$CWD/docs/handoff" "$CWD/docs/leadv2/tasks" -maxdepth 3 -name 'phase11-passed.flag' -o -name 'phase8-passed.flag' 2>/dev/null); do
  if [[ -n "$flag" ]]; then
    AGE=$(( $(date +%s) - $(stat -f %m "$flag" 2>/dev/null || stat -c %Y "$flag" 2>/dev/null || echo 0) ))
    if [[ "$AGE" -lt 300 ]]; then
      FOUND="$flag"
      break
    fi
  fi
done

[[ -z "$FOUND" ]] && exit 0

# Already prompted for this flag?
SEEN_MARKER="${FOUND}.prompted"
[[ -f "$SEEN_MARKER" ]] && exit 0
touch "$SEEN_MARKER"

cat >&2 <<MSG

╔══════════════════════════════════════════════════════════════════╗
║  leadv2 task closed                                              ║
║                                                                  ║
║  STRONGLY RECOMMENDED: type /clear before starting next task.    ║
║                                                                  ║
║  Per-task fresh sessions = 5-10x token savings (verified by      ║
║  session analysis: 28/30 recent sessions had >100 turns due      ║
║  to running multiple tasks in one conversation).                 ║
║                                                                  ║
║  STATE.md and active.yaml persist across sessions —              ║
║  /clear loses NOTHING that matters.                              ║
╚══════════════════════════════════════════════════════════════════╝
MSG
exit 0
