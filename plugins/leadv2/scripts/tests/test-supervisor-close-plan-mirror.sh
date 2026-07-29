#!/usr/bin/env bash
# ST-7: close announcements mirror an intent close into both truth surfaces.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TASKS_LIB="${SCRIPT_DIR}/../leadv2-tasks-lib.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$TMP_DIR/docs/leadv2"
cat >"$TMP_DIR/docs/tasks.yaml" <<'YAML'
tasks:
  - id: ST7-SIM
    title: Simulated lane close
    lane: action
    status: in_progress
    claim: {by: lane-st7, lease_expires: null}
YAML
cat >"$TMP_DIR/docs/leadv2/CURRENT-PLAN.md" <<'MD'
| Intent | State |
| --- | --- |
| ST7-SIM | In progress |
MD

# This is the close-announcement turn: queue first through the only permitted
# writer, then the supervisor-owned State cell, then the announcement evidence.
PROJECT_ROOT="$TMP_DIR" source "$TASKS_LIB"
PROJECT_ROOT="$TMP_DIR" leadv2_tasks_update ST7-SIM --key status --value done
python3 - "$TMP_DIR/docs/leadv2/CURRENT-PLAN.md" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
p.write_text(p.read_text().replace("| ST7-SIM | In progress |", "| ST7-SIM | Closed |"))
PY
printf 'lane ST7-SIM closed\n' >"$TMP_DIR/announcement.txt"

grep -A5 -F 'id: ST7-SIM' "$TMP_DIR/docs/tasks.yaml" | grep -q 'status: done'
grep -qF '| ST7-SIM | Closed |' "$TMP_DIR/docs/leadv2/CURRENT-PLAN.md"
grep -qF 'lane ST7-SIM closed' "$TMP_DIR/announcement.txt"
printf 'PASS: close turn updated tasks.yaml via tasks-lib and CURRENT-PLAN before announcement\n'
