#!/usr/bin/env bash
# leadv2-po-queue.sh — Atomic claim/release/peek/validate for PO QUEUE.md
#
# Subcommands:
#   claim  --task-id <id> [--prefer <regex>]   → stdout: claimed item id; exit 2 if none
#   release --task-id <id> --item <id> [--status done|failed]
#   peek                                        → list current claims
#   validate                                    → parse QUEUE.md, exit 0 if valid
#
# QUEUE.md item format (markdown checkbox list):
#   - [ ] **ITEM-ID: Title** — description
#   owner: <task-id>        ← optional inline metadata lines (no leading whitespace)
#   claimed_at: <ISO8601>   ← must immediately follow owner: line (adjacent or
#                             within same item block; non-adjacent = malformed)
#
# Exit codes (all subcommands):
#   0 = success
#   1 = generic error
#   2 = queue empty / no eligible item
#   3 = ownership_violation (caller tried to release/claim a row owned by someone else)
#   4 = invalid_claim (row doesn't exist or is malformed)
#
# All write paths use flock (via Python fcntl) + temp+rename for atomicity.

set -euo pipefail

# ── Constants ──────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${LEADV2_PROJECT_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

QUEUE_FILE="${PROJECT_ROOT}/docs/agents/product-owner/QUEUE.md"
QUEUE_LOCK="${PROJECT_ROOT}/docs/agents/product-owner/QUEUE.md.lock"
STOLEN_LOG="${PROJECT_ROOT}/docs/leadv2/po-queue-stolen.log"

# Default claim timeout: 4 hours in seconds
CLAIM_TIMEOUT_SECONDS="${LEADV2_CLAIM_TIMEOUT_SECONDS:-14400}"

# ── Logging ────────────────────────────────────────────────────────────────
log()  { printf '[%s] %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$*" >&2; }
die()  { log "ERROR: $*"; exit 1; }

# ── Usage ──────────────────────────────────────────────────────────────────
usage() {
  cat >&2 <<'EOF'
Usage:
  leadv2-po-queue.sh claim   --task-id <id> [--prefer <regex>]
  leadv2-po-queue.sh release --task-id <id> --item <id> [--status done|failed]
  leadv2-po-queue.sh peek
  leadv2-po-queue.sh validate

Exit codes:
  0 = success
  1 = generic error
  2 = queue empty / no eligible item
  3 = ownership_violation
  4 = invalid_claim (row not found or malformed)
EOF
  exit 1
}

# ── Unified parser (J2) — used by validate/claim/peek/release ─────────────
# _leadv2_po_parse_queue is embedded in every Python block via PYEOF heredoc.
# Defined as a Python function literal embedded in each subprocess; all four
# consumers reference _parse_queue() which returns structured per-row data.

_PARSE_QUEUE_PY='
import re, datetime

ITEM_RE = re.compile(r"^(- \[[ x~]\] \*\*)([A-Z]+-\d+[a-z]?)(:.*)")
OPEN_RE = re.compile(r"^- \[ \] \*\*[A-Z]+-\d+[a-z]?:")

# ── ISO-8601 normalizer: Python 3.10 fromisoformat does not accept "+00:00"
# suffix. Normalize "+00:00" → "Z", then handle "Z" → "+00:00" for 3.10.
def _parse_iso(s: str):
    """Parse ISO-8601 datetime string; returns timezone-aware datetime or raises ValueError."""
    if not s:
        raise ValueError("empty timestamp")
    # Normalize trailing Z  (Python 3.11+ handles Z natively; 3.10 does not)
    normalized = s
    if normalized.endswith("Z"):
        normalized = normalized[:-1] + "+00:00"
    # Replace space separator with T
    normalized = normalized.replace(" ", "T")
    try:
        dt = datetime.datetime.fromisoformat(normalized)
    except ValueError:
        raise ValueError(f"cannot parse datetime: {s!r}")
    if dt.tzinfo is None:
        # Assume UTC for naive datetimes
        dt = dt.replace(tzinfo=datetime.timezone.utc)
    return dt

def _parse_queue(lines: list, timeout_s: int = 14400) -> list:
    """
    Parse QUEUE.md lines into structured item dicts. Returns list of dicts:
      id, status, owner, claimed_at_str, body,
      line_idx, owner_line_idx, ca_line_idx, next_item_line,
      malformed, malformed_reason
    J2: handles non-adjacent metadata (gap >= 1 blank line → malformed),
        future claimed_at (>1h future → malformed), Python 3.10 fromisoformat quirks.
    """
    items = []
    i = 0
    now = datetime.datetime.now(datetime.timezone.utc)

    while i < len(lines):
        m = ITEM_RE.match(lines[i])
        if not m:
            i += 1
            continue

        item_id     = m.group(2)
        item_line   = i
        owner       = ""
        ca_str      = ""
        owner_line_idx = None
        ca_line_idx    = None
        last_meta_line = i  # last line that is part of this item block (for adjacency check)
        malformed      = False
        malformed_reason = ""

        # Scan forward for metadata lines — stop at next item or section header
        j = i + 1
        while j < len(lines):
            raw = lines[j]
            stripped = raw.rstrip("\n").rstrip()
            if ITEM_RE.match(stripped) or (stripped.startswith("##") and j > i + 1):
                break

            if stripped.startswith("owner:"):
                # J2: adjacency check — gap means non-adjacent metadata
                if owner == "" and ca_str == "":
                    gap = j - last_meta_line - 1
                    if gap > 0:
                        malformed = True
                        malformed_reason = (
                            f"non-adjacent owner: found at line {j+1} "
                            f"(gap={gap} lines from item at line {i+1})"
                        )
                owner = stripped[len("owner:"):].strip()
                owner_line_idx = j
                last_meta_line = j

            elif stripped.startswith("claimed_at:"):
                # J2: adjacency check for claimed_at
                if owner_line_idx is not None:
                    gap = j - owner_line_idx - 1
                    if gap > 0:
                        malformed = True
                        malformed_reason = (
                            f"non-adjacent claimed_at: found at line {j+1} "
                            f"(gap={gap} lines from owner: at line {owner_line_idx+1})"
                        )
                else:
                    malformed = True
                    malformed_reason = f"claimed_at: at line {j+1} without preceding owner:"
                ca_str = stripped[len("claimed_at:"):].strip()
                ca_line_idx = j
                last_meta_line = j

            j += 1

        # J2: future-dated claimed_at check
        if ca_str and not malformed:
            try:
                ca_dt = _parse_iso(ca_str)
                future_delta = (ca_dt - now).total_seconds()
                if future_delta > 3600:  # >1h in future is suspicious
                    malformed = True
                    malformed_reason = (
                        f"claimed_at is {future_delta/3600:.1f}h in the future: {ca_str!r}"
                    )
            except ValueError as e:
                malformed = True
                malformed_reason = f"unparseable claimed_at: {e}"

        items.append({
            "id":             item_id,
            "owner":          owner,
            "claimed_at_str": ca_str,
            "line_idx":       item_line,
            "owner_line_idx": owner_line_idx,
            "ca_line_idx":    ca_line_idx,
            "next_item_line": j,
            "malformed":      malformed,
            "malformed_reason": malformed_reason,
        })
        i = j

    return items
'

# ── Subcommand: validate ───────────────────────────────────────────────────
cmd_validate() {
  [[ -f "$QUEUE_FILE" ]] || die "QUEUE.md not found: $QUEUE_FILE"

  # J3: scan .claims/ for dead-PID sidecars and auto-release them
  local claims_dir="${PROJECT_ROOT}/docs/agents/product-owner/.claims"
  if [[ -d "$claims_dir" ]]; then
    local sidecar
    while IFS= read -r -d '' sidecar; do
      local sidecar_pid
      sidecar_pid=$(grep '^pid=' "$sidecar" 2>/dev/null | cut -d= -f2 || true)
      if [[ -n "$sidecar_pid" ]] && ! kill -0 "$sidecar_pid" 2>/dev/null; then
        local tid
        tid=$(basename "$sidecar" .claim)
        log "validate: dead-PID sidecar for $tid (pid=$sidecar_pid) — auto-releasing"
        # Call release logic inline via Python to clear owner in QUEUE.md
        if _py_auto_release_dead_sidecar "$tid"; then
          rm -f "$sidecar"
        else
          log "validate: auto-release failed for $tid (continuing)"
        fi
      fi
    done < <(find "$claims_dir" -maxdepth 1 -name '*.claim' -print0 2>/dev/null)
  fi

  python3 - "$QUEUE_FILE" <<PYEOF
${_PARSE_QUEUE_PY}
import sys
from pathlib import Path

queue_path = Path(sys.argv[1])
text = queue_path.read_text(encoding="utf-8")
lines = text.splitlines(keepends=True)

items = _parse_queue(lines)
errors = [
    f"item {it['id']} line {it['line_idx']+1}: {it['malformed_reason']}"
    for it in items if it["malformed"]
]

if errors:
    for e in errors:
        print(f"INVALID: {e}", file=sys.stderr)
    sys.exit(1)

print(f"VALID: {queue_path.name} parsed OK ({len(items)} items)", file=sys.stderr)
sys.exit(0)
PYEOF
}

# ── Helper: auto-release an item owned by a dead-PID task ─────────────────
_py_auto_release_dead_sidecar() {
  local dead_task_id="$1"
  python3 - "$QUEUE_FILE" "$QUEUE_LOCK" "$dead_task_id" <<'PYEOF'
import sys, os, fcntl, tempfile
from pathlib import Path

queue_path   = Path(sys.argv[1])
lock_path    = Path(sys.argv[2])
dead_task_id = sys.argv[3]

import re
ITEM_RE = re.compile(r"^(- \[[ x~]\] \*\*)([A-Z]+-\d+[a-z]?)(:.*)")

if not queue_path.exists():
    sys.exit(0)

lock_path.parent.mkdir(parents=True, exist_ok=True)
lock_fd = open(str(lock_path), "a+")
try:
    fcntl.flock(lock_fd, fcntl.LOCK_EX)
    text = queue_path.read_text(encoding="utf-8")
    lines = text.splitlines(keepends=True)

    # Find any item owned by dead_task_id and clear owner/claimed_at
    modified = False
    for i, line in enumerate(lines):
        stripped = line.rstrip("\n")
        if stripped == f"owner: {dead_task_id}":
            lines[i] = "owner:\n"
            modified = True
        elif stripped == f"claimed_at:" or (modified and stripped.startswith("claimed_at:")):
            # clear adjacent claimed_at if we just cleared the owner above
            pass  # will be covered by claimed_at: being empty already

    # Second pass: clear claimed_at for lines right after an "owner:\n" we just wrote
    # (find blank owner lines and if next substantive line is claimed_at, clear it)
    i = 0
    while i < len(lines):
        if lines[i].rstrip("\n") == "owner:":
            j = i + 1
            while j < len(lines) and not ITEM_RE.match(lines[j].rstrip("\n")):
                stripped = lines[j].rstrip("\n")
                if stripped.startswith("claimed_at:"):
                    lines[j] = "claimed_at:\n"
                    break
                j += 1
        i += 1

    if not modified:
        sys.exit(0)

    dir_ = str(queue_path.parent)
    tmp_fd, tmp_path = tempfile.mkstemp(dir=dir_, suffix=".tmp")
    try:
        with os.fdopen(tmp_fd, "w", encoding="utf-8") as tf:
            tf.writelines(lines)
        os.replace(tmp_path, str(queue_path))
    except Exception:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise

    print(f"[po-queue] auto-released rows for dead task {dead_task_id}", file=sys.stderr)
    sys.exit(0)
finally:
    fcntl.flock(lock_fd, fcntl.LOCK_UN)
    lock_fd.close()
PYEOF
}

# ── Subcommand: peek ───────────────────────────────────────────────────────
cmd_peek() {
  [[ -f "$QUEUE_FILE" ]] || { log "QUEUE.md not found"; exit 0; }
  python3 - "$QUEUE_FILE" "$CLAIM_TIMEOUT_SECONDS" <<PYEOF
${_PARSE_QUEUE_PY}
import sys
from pathlib import Path

queue_path = Path(sys.argv[1])
timeout_s  = int(sys.argv[2])
text = queue_path.read_text(encoding="utf-8")
lines = text.splitlines(keepends=True)

items = _parse_queue(lines, timeout_s)
claims = []
import datetime
now = datetime.datetime.now(datetime.timezone.utc)

for it in items:
    if not it["owner"]:
        continue
    ca_str = it["claimed_at_str"]
    age_str = "unknown"
    stale = False
    if ca_str:
        try:
            ca_dt = _parse_iso(ca_str)
            age_s = (now - ca_dt).total_seconds()
            age_str = f"{age_s/3600:.1f}h"
            stale = age_s > timeout_s
        except ValueError:
            age_str = f"invalid({ca_str})"
    stale_mark = " [STALE]" if stale else ""
    malformed_mark = " [MALFORMED]" if it["malformed"] else ""
    claims.append(f"{it['id']}\t{it['owner']}\t{age_str}{stale_mark}{malformed_mark}")

if not claims:
    print("(no active claims)")
else:
    print("item_id\towner\tage")
    for c in claims:
        print(c)
PYEOF
}

# ── Core Python: claim ─────────────────────────────────────────────────────
# J1: if a row is already owned by someone else (not stale) → exit 3.
# J2: uses unified _parse_queue.
_py_claim() {
  local task_id="$1"
  local prefer="$2"   # regex or empty string

  python3 - "$QUEUE_FILE" "$QUEUE_LOCK" "$STOLEN_LOG" \
             "$task_id" "$prefer" "$CLAIM_TIMEOUT_SECONDS" \
             "$PROJECT_ROOT" <<PYEOF
${_PARSE_QUEUE_PY}
import sys, os, re, fcntl, tempfile, datetime
from pathlib import Path

queue_path   = Path(sys.argv[1])
lock_path    = Path(sys.argv[2])
stolen_log   = Path(sys.argv[3])
task_id      = sys.argv[4]
prefer_regex = sys.argv[5]   # may be empty
timeout_s    = int(sys.argv[6])
project_root = sys.argv[7]

now = datetime.datetime.now(datetime.timezone.utc)

# Ensure lock dir exists
lock_path.parent.mkdir(parents=True, exist_ok=True)

lock_fd = open(str(lock_path), "a+")
try:
    fcntl.flock(lock_fd, fcntl.LOCK_EX)

    # ── Re-read fresh ──────────────────────────────────────────────────────
    if not queue_path.exists():
        print("QUEUE.md not found", file=sys.stderr)
        sys.exit(1)

    text = queue_path.read_text(encoding="utf-8")
    lines = text.splitlines(keepends=True)

    # ── Unified parse (J2) ─────────────────────────────────────────────────
    items = _parse_queue(lines, timeout_s)

    # ── Filter by --prefer if given ────────────────────────────────────────
    candidates = items
    if prefer_regex:
        try:
            pat = re.compile(prefer_regex, re.IGNORECASE)
        except re.error as e:
            print(f"Invalid --prefer regex: {e}", file=sys.stderr)
            sys.exit(1)
        preferred = [it for it in items if pat.search(it["id"])]
        if preferred:
            candidates = preferred

    # ── Scan in document order ─────────────────────────────────────────────
    ts_str = now.strftime("%Y-%m-%dT%H:%M:%SZ")
    claimed_item = None
    stolen_from  = None
    stolen_at    = None
    stolen_age_h = 0.0

    for item in candidates:
        if item["malformed"]:
            # Skip malformed rows (they will be flagged by validate)
            continue

        if not item["owner"]:
            # Free — claim it
            claimed_item = item
            break
        else:
            # J1: check if already owned by THIS task (idempotent re-claim)
            if item["owner"] == task_id:
                # Already claimed by us — idempotent success
                claimed_item = item
                break

            # Evaluate staleness
            ca_str = item["claimed_at_str"]
            if ca_str:
                try:
                    claimed_dt = _parse_iso(ca_str)
                    age_s = (now - claimed_dt).total_seconds()
                except ValueError:
                    age_s = timeout_s + 1  # treat unparseable as stale
            else:
                age_s = timeout_s + 1  # no claimed_at → treat as stale

            if age_s > timeout_s:
                stolen_from  = item["owner"]
                stolen_at    = ca_str
                stolen_age_h = age_s / 3600
                claimed_item = item
                break
            # Owned by someone else AND not stale → J1: ownership_violation
            # We do NOT exit 3 here in claim path — we skip to next candidate
            # (stealing only if stale; ownership_violation is for explicit
            #  release of another task's item, see _py_release)

    if claimed_item is None:
        # Nothing available
        sys.exit(2)

    # ── Write claim into lines ─────────────────────────────────────────────
    item = claimed_item
    new_owner_line = f"owner: {task_id}\n"
    new_ca_line    = f"claimed_at: {ts_str}\n"

    if item["owner_line_idx"] is not None:
        lines[item["owner_line_idx"]] = new_owner_line
    else:
        # Insert after item line
        lines.insert(item["line_idx"] + 1, new_owner_line)
        # Adjust ca_line index if it was after insertion point
        if item["ca_line_idx"] is not None and item["ca_line_idx"] >= item["line_idx"] + 1:
            item = dict(item)
            item["ca_line_idx"] += 1

    # Refresh ca_line after possible insertion
    if item["owner_line_idx"] is not None:
        if item["ca_line_idx"] is not None:
            lines[item["ca_line_idx"]] = new_ca_line
        else:
            owner_idx = item["owner_line_idx"]
            lines.insert(owner_idx + 1, new_ca_line)
    else:
        # We just inserted owner_line at item["line_idx"]+1
        if item["ca_line_idx"] is not None:
            lines[item["ca_line_idx"]] = new_ca_line
        else:
            lines.insert(item["line_idx"] + 2, new_ca_line)

    # ── Atomic write ───────────────────────────────────────────────────────
    dir_ = str(queue_path.parent)
    tmp_fd, tmp_path = tempfile.mkstemp(dir=dir_, suffix=".tmp")
    try:
        with os.fdopen(tmp_fd, "w", encoding="utf-8") as tf:
            tf.writelines(lines)
        os.replace(tmp_path, str(queue_path))
    except Exception:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise

    # ── Stolen item logging ────────────────────────────────────────────────
    if stolen_from is not None:
        age_h = round(stolen_age_h, 2)
        steal_entry = (
            f"[po-queue] stolen item={item['id']} from={stolen_from} "
            f"claimed_at={stolen_at} age_hours={age_h} new_owner={task_id} ts={ts_str}\n"
        )
        stolen_log.parent.mkdir(parents=True, exist_ok=True)
        with open(str(stolen_log), "a", encoding="utf-8") as slg:
            slg.write(steal_entry)

        live_candidates = []
        task_live   = Path(project_root) / "docs" / "leadv2" / "tasks" / task_id / "LIVE.md"
        global_live = Path(project_root) / "docs" / "LEAD_V2_LIVE.md"
        if task_live.exists():
            live_candidates.append(task_live)
        elif global_live.exists():
            live_candidates.append(global_live)
        for live in live_candidates:
            with open(str(live), "a", encoding="utf-8") as lf:
                lf.write(steal_entry)

        print(f"[po-queue] STOLEN {item['id']} from {stolen_from} (age {age_h}h)", file=sys.stderr)

    # ── Output claimed item id ─────────────────────────────────────────────
    print(item["id"])
    sys.exit(0)

finally:
    fcntl.flock(lock_fd, fcntl.LOCK_UN)
    lock_fd.close()
PYEOF
}

# ── Core Python: release ───────────────────────────────────────────────────
# J1: verify row's owner matches caller's task_id before mutation.
#     Mismatch → exit 3 (ownership_violation).
#     Row not found → exit 4 (invalid_claim).
# J2: uses unified _parse_queue.
_py_release() {
  local task_id="$1"
  local item_id="$2"
  local status="$3"   # done | failed

  python3 - "$QUEUE_FILE" "$QUEUE_LOCK" \
             "$task_id" "$item_id" "$status" <<PYEOF
${_PARSE_QUEUE_PY}
import sys, os, re, fcntl, tempfile
from pathlib import Path

queue_path = Path(sys.argv[1])
lock_path  = Path(sys.argv[2])
task_id    = sys.argv[3]
item_id    = sys.argv[4]
status     = sys.argv[5]   # done | failed

if not queue_path.exists():
    print("QUEUE.md not found", file=sys.stderr)
    sys.exit(1)

lock_path.parent.mkdir(parents=True, exist_ok=True)

lock_fd = open(str(lock_path), "a+")
try:
    fcntl.flock(lock_fd, fcntl.LOCK_EX)

    text = queue_path.read_text(encoding="utf-8")
    lines = text.splitlines(keepends=True)

    # ── Unified parse (J2) ─────────────────────────────────────────────────
    items = _parse_queue(lines)
    target = None
    for it in items:
        if it["id"] == item_id:
            target = it
            break

    # J1/J2: item not found → exit 4 (invalid_claim)
    if target is None:
        print(f"[po-queue] invalid_claim: item {item_id!r} not found in QUEUE.md", file=sys.stderr)
        sys.exit(4)

    # J2: malformed row → exit 4 (invalid_claim)
    if target["malformed"]:
        print(
            f"[po-queue] invalid_claim: item {item_id!r} is malformed — "
            f"{target['malformed_reason']}",
            file=sys.stderr,
        )
        sys.exit(4)

    # J1: ownership check — must match caller's task_id (or be unclaimed)
    row_owner = target["owner"]
    if row_owner and row_owner != task_id:
        print(
            f"[po-queue] ownership_violation: {item_id!r} is owned by {row_owner!r}, "
            f"caller is {task_id!r}",
            file=sys.stderr,
        )
        sys.exit(3)

    target_line = target["line_idx"]
    owner_line  = target["owner_line_idx"]
    ca_line     = target["ca_line_idx"]

    if status == "done":
        to_remove = set()
        to_remove.add(target_line)
        if owner_line is not None:
            to_remove.add(owner_line)
        if ca_line is not None:
            to_remove.add(ca_line)
        new_lines = [ln for idx, ln in enumerate(lines) if idx not in to_remove]
    else:
        # status == failed: clear owner/claimed_at (item stays for rerun)
        new_lines = list(lines)
        if owner_line is not None:
            new_lines[owner_line] = "owner:\n"
        if ca_line is not None:
            new_lines[ca_line] = "claimed_at:\n"

    # ── Atomic write ───────────────────────────────────────────────────────
    dir_ = str(queue_path.parent)
    tmp_fd, tmp_path = tempfile.mkstemp(dir=dir_, suffix=".tmp")
    try:
        with os.fdopen(tmp_fd, "w", encoding="utf-8") as tf:
            tf.writelines(new_lines)
        os.replace(tmp_path, str(queue_path))
    except Exception:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise

    print(f"[po-queue] released {item_id} status={status}", file=sys.stderr)
    sys.exit(0)

finally:
    fcntl.flock(lock_fd, fcntl.LOCK_UN)
    lock_fd.close()
PYEOF
}

# ── Argument parsing ───────────────────────────────────────────────────────
[[ $# -ge 1 ]] || usage

SUBCMD="$1"
shift

case "$SUBCMD" in
  claim)
    printf -- '[po-queue] DEPRECATED: leadv2-po-queue.sh is deprecated — use leadv2-queue-claim.sh / leadv2-queue-release.sh against queue/*.yaml\n' >&2
    exit 2
    ;;

  release)
    printf -- '[po-queue] DEPRECATED: leadv2-po-queue.sh is deprecated — use leadv2-queue-claim.sh / leadv2-queue-release.sh against queue/*.yaml\n' >&2
    exit 2
    ;;

  peek)
    printf -- '[po-queue] DEPRECATED: leadv2-po-queue.sh is deprecated — use leadv2-queue-claim.sh / leadv2-queue-release.sh against queue/*.yaml\n' >&2
    exit 2
    ;;

  validate)
    printf -- '[po-queue] DEPRECATED: leadv2-po-queue.sh is deprecated — use leadv2-queue-claim.sh / leadv2-queue-release.sh against queue/*.yaml\n' >&2
    exit 2
    ;;

  *)
    printf -- '[po-queue] DEPRECATED: leadv2-po-queue.sh is deprecated — use leadv2-queue-claim.sh / leadv2-queue-release.sh against queue/*.yaml\n' >&2
    exit 2
    ;;
esac
