#!/usr/bin/env bash
# leadv2-session-note.sh <task-id> "<note>"
# Appends a one-liner to ## History notes in STATE.md.
# Called by lead at end of session OR at start of resume.
#
# STATE.md at docs/leadv2/tasks/<id>/STATE.md
set -euo pipefail

# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/leadv2-helpers.sh"

TASK_ID="${1:-}"
NOTE="${2:-}"
[[ -z "$TASK_ID" || -z "$NOTE" ]] && { echo "usage: $0 <task-id> <note>" >&2; exit 1; }

# STATE.md lives in docs/leadv2/tasks/<id>/STATE.md
STATE="$LEADV2_PROJECT_ROOT/docs/leadv2/tasks/$TASK_ID/STATE.md"
[[ -f "$STATE" ]] || { echo "ERR: STATE.md not found for $TASK_ID at $STATE" >&2; exit 1; }

NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
LINE="- $NOW: $NOTE"

# Insert after the ## History notes header
python3 - "$STATE" "$LINE" <<'PY'
import sys, pathlib
path, line = sys.argv[1], sys.argv[2]
content = pathlib.Path(path).read_text()
marker = '## History notes'
if marker not in content:
    content += f'\n{marker}\n{line}\n'
else:
    content = content.replace(
        marker,
        f'{marker}\n{line}'
    )
pathlib.Path(path).write_text(content)
PY

echo "noted: $TASK_ID"
