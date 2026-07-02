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

# ── Cap pulse.md to last N lines (LEADV2_PULSE_MAX_LINES, default 200) ────────
# Pruned head is archived to pulse-archive.md rather than discarded.
try:
    pulse_max = max(1, int(os.environ.get('LEADV2_PULSE_MAX_LINES', '200') or '200'))
except (ValueError, TypeError):
    pulse_max = 200
with open(pulse_file, 'r', encoding='utf-8') as pf:
    pulse_lines = pf.readlines()
if len(pulse_lines) > pulse_max:
    head_lines = pulse_lines[: len(pulse_lines) - pulse_max]
    keep_lines = pulse_lines[len(pulse_lines) - pulse_max :]
    archive_file = os.path.join(os.path.dirname(pulse_file), 'pulse-archive.md')
    # Read existing archive content, then write combined (existing + new head_lines) atomically.
    # Atomic archive write prevents duplicate archive entries when the process is killed after
    # a partial append but before pulse.md is truncated (on next run head_lines re-archived).
    existing_archive: list[str] = []
    if os.path.exists(archive_file):
        with open(archive_file, 'r', encoding='utf-8') as _af:
            existing_archive = _af.readlines()
    archive_dir = os.path.dirname(archive_file)
    fd_arch, tmp_arch = tempfile.mkstemp(dir=archive_dir, suffix='.archive.tmp')
    try:
        with os.fdopen(fd_arch, 'w', encoding='utf-8') as tf_arch:
            tf_arch.writelines(existing_archive + head_lines)
            tf_arch.flush()
            os.fsync(tf_arch.fileno())
        os.replace(tmp_arch, archive_file)
    except Exception:
        try:
            os.unlink(tmp_arch)
        except OSError:
            pass
        raise
    # Rewrite pulse.md with kept lines only
    pulse_dir = os.path.dirname(pulse_file)
    fd2, tmp2 = tempfile.mkstemp(dir=pulse_dir, suffix='.pulse.tmp')
    try:
        with os.fdopen(fd2, 'w', encoding='utf-8') as tf2:
            tf2.writelines(keep_lines)
            tf2.flush()
            os.fsync(tf2.fileno())
        os.replace(tmp2, pulse_file)
    except Exception:
        try:
            os.unlink(tmp2)
        except OSError:
            pass
        raise


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

# ── [PHASE-SYNC-01] Best-effort active.yaml phase update ─────────────────────
# When the atomic write records a "phase" field, mirror it into active.yaml so
# the session row's phase stays current (not frozen at "intake" all session).
# Non-fatal: runs in a subshell; errors emit WARN to stderr; never changes the
# parent script's exit code or stdout (script has no stdout output).
if [[ "$FIELD" == "phase" ]]; then
  (
    _PHASE_REGISTRY="$(dirname "${BASH_SOURCE[0]}")/leadv2-active-registry.sh"
    if [[ ! -f "$_PHASE_REGISTRY" ]]; then
      printf -- '[%s] WARN: registry not found at %s — phase not mirrored to active.yaml\n' \
        "$SCRIPT_NAME" "$_PHASE_REGISTRY" >&2
      exit 0
    fi
    LEADV2_PROJECT_ROOT="$REPO"
    # shellcheck source=/dev/null
    source "$_PHASE_REGISTRY"
    leadv2_active_update_phase "$TASK_ID" "$VALUE"
  ) || printf -- '[%s] WARN: active.yaml phase update failed (non-fatal)\n' "$SCRIPT_NAME" >&2
fi
# ── end phase sync ────────────────────────────────────────────────────────────
