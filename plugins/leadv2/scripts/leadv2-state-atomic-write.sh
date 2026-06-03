#!/usr/bin/env bash
# leadv2-state-atomic-write.sh
# Atomic update of STATE.md field + pulse.md append.
# Prevents STATE.md <-> pulse.md drift (PO-046: state=build but pulse=plan).
#
# Usage: bash leadv2-state-atomic-write.sh <task-id> <field> <value>
#
# - Updates docs/leadv2/tasks/<task-id>/STATE.md: sets "Field: value"
# - Appends docs/leadv2/tasks/<task-id>/pulse.md: "<utc-iso> field=value"
# - Uses flock on STATE.md.lock — both writes succeed or both rollback.

set -euo pipefail
trap 'exit 0' ERR

SCRIPT_NAME="leadv2-state-atomic-write"
REPO="${CLAUDE_PROJECT_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"

log_err() {
  printf -- '[%s] ERROR: %s\n' "$SCRIPT_NAME" "$*" >&2
}

# ── argument validation ────────────────────────────────────────────────────────

if [[ $# -lt 3 ]]; then
  log_err "Usage: $0 <task-id> <field> <value>"
  exit 1
fi

TASK_ID="$1"
FIELD="$2"
VALUE="$3"

if [[ -z "$TASK_ID" ]]; then
  log_err "task-id must not be empty"
  exit 1
fi

if [[ -z "$FIELD" ]]; then
  log_err "field must not be empty"
  exit 1
fi

# ── paths ──────────────────────────────────────────────────────────────────────

TASK_DIR="$REPO/docs/leadv2/tasks/$TASK_ID"
STATE_FILE="$TASK_DIR/STATE.md"
PULSE_FILE="$TASK_DIR/pulse.md"
LOCK_FILE="$TASK_DIR/STATE.md.lock"

if [[ ! -d "$TASK_DIR" ]]; then
  log_err "Task directory not found: $TASK_DIR"
  exit 1
fi

if [[ ! -f "$STATE_FILE" ]]; then
  log_err "STATE.md not found: $STATE_FILE"
  exit 1
fi

# ── inline Python for atomic field update ─────────────────────────────────────

PYTHON_UPDATE=$(cat <<'PYEOF'
import sys
import os
import tempfile
import time

state_file = sys.argv[1]
field = sys.argv[2]
value = sys.argv[3]
pulse_file = sys.argv[4]

# ── Read STATE.md ──────────────────────────────────────────────────────────────
with open(state_file, 'r', encoding='utf-8') as f:
    lines = f.readlines()

# ── Update or append field ─────────────────────────────────────────────────────
# Matches YAML frontmatter "Field: value" or plain "Field: value" lines.
# Case-insensitive field match.
field_lower = field.lower()
updated = False
new_lines = []
for line in lines:
    # Match "Field: ..." at start of line (optional leading spaces)
    stripped = line.lstrip()
    colon_pos = stripped.find(':')
    if colon_pos > 0:
        candidate = stripped[:colon_pos].strip().lower()
        if candidate == field_lower:
            indent = line[: len(line) - len(stripped)]
            new_lines.append(f"{indent}{field}: {value}\n")
            updated = True
            continue
    new_lines.append(line)

if not updated:
    # Append field before final YAML fence "---" if present, else at end
    fence_idx = None
    for i in range(len(new_lines) - 1, -1, -1):
        if new_lines[i].strip() == '---':
            fence_idx = i
            break
    if fence_idx is not None:
        new_lines.insert(fence_idx, f"{field}: {value}\n")
    else:
        # Ensure trailing newline
        if new_lines and not new_lines[-1].endswith('\n'):
            new_lines[-1] += '\n'
        new_lines.append(f"{field}: {value}\n")

# ── Write STATE.md atomically (tmp + fsync + rename) ──────────────────────────
state_dir = os.path.dirname(state_file)
fd, tmp_path = tempfile.mkstemp(dir=state_dir, suffix='.tmp')
try:
    with os.fdopen(fd, 'w', encoding='utf-8') as tf:
        tf.writelines(new_lines)
        tf.flush()
        os.fsync(tf.fileno())
    os.replace(tmp_path, state_file)
except Exception:
    try:
        os.unlink(tmp_path)
    except OSError:
        pass
    raise

# ── Append pulse.md ────────────────────────────────────────────────────────────
utc_iso = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())
pulse_line = f"{utc_iso} {field}={value}\n"

with open(pulse_file, 'a', encoding='utf-8') as pf:
    pf.write(pulse_line)
    pf.flush()
    os.fsync(pf.fileno())

print(f"OK: {field}={value}")
PYEOF
)

# ── acquire lock and run ───────────────────────────────────────────────────────

# Create lock file if it doesn't exist
touch "$LOCK_FILE"

# Use flock for atomic access; timeout after 10s to avoid infinite wait
RESULT=$(
  flock --exclusive --timeout 10 "$LOCK_FILE" \
    python3 - "$STATE_FILE" "$FIELD" "$VALUE" "$PULSE_FILE" <<< "$PYTHON_UPDATE"
) && RC=0 || RC=$?

if [[ $RC -ne 0 ]]; then
  log_err "Atomic write failed for task=$TASK_ID field=$FIELD — both STATE.md and pulse.md unchanged"
  exit 1
fi

printf -- '[%s] %s (task=%s)\n' "$SCRIPT_NAME" "$RESULT" "$TASK_ID" >&2
