#!/usr/bin/env bash
# leadv2-negative-memory-compile.sh — Auto-generate negative-memory candidate entries.
#
# Runs nightly (cron) or after Close phase (lead-reflect).
# Scans LEAD_V2_STATE.md history + docs/ops/LEAD_HISTORY.md for:
#   - Signatures with outcome=rolled_back or failed
#   - Same approach attempted >=2 times and failed both times
# Emits candidate entries (status: candidate) to docs/leadv2-negative-memory.yaml.
# Founder approval required (Tier B default-timeout) before status -> active.
# Also runs TTL decay: expired entries -> docs/leadv2-negative-memory-archive.yaml.
#
# Usage:
#   leadv2-negative-memory-compile.sh [--dry-run] [--ttl-only] [--task-id <id>]
#
# Options:
#   --dry-run     Print candidates/expirations without writing
#   --ttl-only    Only run TTL sweep, skip candidate generation
#   --task-id     Restrict scan to one task ID
#
# SHELL=/bin/bash (required for cron)
# Exit codes:
#   0 = no changes needed
#   1 = candidates generated (founder approval pending)
#   2 = entries expired

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Durable-root (fix round 1, item 7): the old "$SCRIPT_DIR/../.." climbed
# two HARDCODED directory levels regardless of where this script actually
# lives and ignored LEADV2_PROJECT_ROOT entirely -- worse than the T1
# ephemeral-worktree bug, it wasn't git-aware at all. Matches the durable-
# root pattern + override convention already used by sibling scripts
# (leadv2-immune-lookup.sh, this diff's own leadv2-immune-aggregate.sh fix).
PROJECT_ROOT="${LEADV2_PROJECT_ROOT:-$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null | xargs dirname 2>/dev/null || pwd)}"

NM_FILE="${PROJECT_ROOT}/docs/leadv2-negative-memory.yaml"
NM_ARCHIVE="${PROJECT_ROOT}/docs/leadv2-negative-memory-archive.yaml"
LEAD_STATE="${PROJECT_ROOT}/docs/LEAD_V2_STATE.md"
LEAD_HISTORY="${PROJECT_ROOT}/docs/ops/LEAD_HISTORY.md"
DECISIONS_DIR="${PROJECT_ROOT}/docs/leadv2-decisions"

# MEM-BACKUP-RESTORE-01: flag-gated backup+integrity+restore around writes to
# NM_FILE / NM_ARCHIVE below. Byte-identical no-op when LEADV2_MEM_BACKUP is
# unset/0 (see scripts/leadv2-mem-backup.sh header for the full contract).
_MEM_BACKUP_HELPER="${SCRIPT_DIR}/leadv2-mem-backup.sh"
if [[ -f "$_MEM_BACKUP_HELPER" ]]; then
  # shellcheck source=/dev/null
  source "$_MEM_BACKUP_HELPER"
fi

DRY_RUN=0
TTL_ONLY=0
TASK_ID_FILTER=""

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }
log_error() { log "ERROR: $*"; }
log_info() { log "INFO: $*"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)   DRY_RUN=1; shift ;;
    --ttl-only)  TTL_ONLY=1; shift ;;
    --task-id)   TASK_ID_FILTER="$2"; shift 2 ;;
    -h|--help)
      printf 'Usage: %s [--dry-run] [--ttl-only] [--task-id <id>]\n' "$(basename "$0")" >&2
      exit 0 ;;
    *) log_error "Unknown arg: $1"; exit 1 ;;
  esac
done

# Ensure NM files exist
if [[ ! -f "$NM_FILE" ]]; then
  log_info "No negative-memory file found at $NM_FILE — nothing to do."
  exit 0
fi

TODAY=$(date '+%Y-%m-%d')

# ── TTL sweep ──────────────────────────────────────────────────────────────────

run_ttl_sweep() {
  log_info "Running TTL sweep (today=$TODAY)..."
  python3 - "$NM_FILE" "$NM_ARCHIVE" "$TODAY" "$DRY_RUN" "$PROJECT_ROOT" <<'PY'
import sys, yaml, pathlib, datetime, re

nm_path      = pathlib.Path(sys.argv[1])
archive_path = pathlib.Path(sys.argv[2])
today        = datetime.date.fromisoformat(sys.argv[3])
dry_run      = sys.argv[4] == "1"
project_root = pathlib.Path(sys.argv[5])

data = yaml.safe_load(nm_path.read_text()) or {}
entries = data.get("entries") or []

archive_data = yaml.safe_load(archive_path.read_text()) if archive_path.exists() else {}
if not isinstance(archive_data, dict):
    archive_data = {}
archive_entries = archive_data.get("entries") or []

kept = []
expired_count = 0
for entry in entries:
    status = entry.get("status", "active")
    ttl_str = entry.get("ttl_expires", "")
    if status in ("active", "candidate") and ttl_str:
        try:
            ttl_date = datetime.date.fromisoformat(str(ttl_str))
            if ttl_date < today:
                entry["status"] = "expired"
                entry["archived_at"] = str(today)
                entry["archive_reason"] = "expired"
                if not dry_run:
                    archive_entries.append(entry)
                expired_count += 1
                print(f"EXPIRE: {entry.get('id')} (ttl={ttl_str})", flush=True)
                continue
        except ValueError:
            pass
    kept.append(entry)

if expired_count > 0 and not dry_run:
    data["entries"] = kept
    nm_path.write_text(yaml.dump(data, allow_unicode=True, sort_keys=False))
    archive_data["entries"] = archive_entries
    archive_path.write_text(yaml.dump(archive_data, allow_unicode=True, sort_keys=False))
    print(f"TTL_SWEEP_DONE: {expired_count} entries expired", flush=True)
elif expired_count > 0:
    print(f"TTL_SWEEP_DRY: {expired_count} would expire", flush=True)
else:
    print("TTL_SWEEP_DONE: 0 entries expired", flush=True)

# Contradiction detection: if a task succeeded using an approach
# that matches an EXPIRED entry -> log contradiction candidate.
# (Contradiction checking happens in compile phase below, not here.)
sys.exit(2 if expired_count > 0 else 0)
PY
  return $?
}

# fix round 1, item 2: trailing `|| true` is load-bearing (see
# leadv2-mem-backup.sh header) -- prevents a real internal failure in the
# FINAL command of this `&&`/`{ }` chain from aborting this set -e script.
command -v mem_backup_snapshot >/dev/null 2>&1 && { mem_backup_snapshot "$NM_FILE" "entries"; mem_backup_snapshot "$NM_ARCHIVE" "entries"; } || true

TTL_EXIT=0
run_ttl_sweep || TTL_EXIT=$?

# NM_ARCHIVE legitimately does not exist until the FIRST entry ever expires
# (fix round: T6 own test caught this) -- only verify/restore it when it's
# actually present, else "never created yet" false-positives as corruption
# on every normal run and spams a restore attempt for nothing to restore.
command -v mem_backup_verify_or_restore >/dev/null 2>&1 && {
  mem_backup_verify_or_restore "$NM_FILE" "entries"
  [[ -f "$NM_ARCHIVE" ]] && mem_backup_verify_or_restore "$NM_ARCHIVE" "entries"
  true
} || true

[[ "$TTL_ONLY" -eq 1 ]] && exit "$TTL_EXIT"

# ── Candidate generation ───────────────────────────────────────────────────────

log_info "Scanning history for failed approaches..."

CANDIDATES_GENERATED=0

command -v mem_backup_snapshot >/dev/null 2>&1 && mem_backup_snapshot "$NM_FILE" "entries" || true

# fix round 1, item 1 (CRITICAL): this writer intentionally `sys.exit(1)`
# (candidates pending) / can fail non-zero for real reasons too. As a bare
# top-level command under set -e, an exit-1 here ABORTS THE SCRIPT
# immediately -- the old `COMPILE_EXIT=$?` line below never ran, so
# mem_backup_verify_or_restore never fired on exactly the runs where the
# writer did something (or crashed). Capturing the exit code via `||`
# keeps this in the errexit-exempt position (any command of an AND-OR list
# OTHER than the last is exempt) so the script always reaches the
# unconditional restore call after it, regardless of the writer's outcome.
COMPILE_EXIT=0
python3 - \
  "$NM_FILE" \
  "${NM_ARCHIVE}" \
  "${LEAD_STATE}" \
  "${LEAD_HISTORY}" \
  "$TODAY" \
  "$DRY_RUN" \
  "${TASK_ID_FILTER}" \
  "${DECISIONS_DIR}" \
  <<'PY' || COMPILE_EXIT=$?
import sys, yaml, pathlib, datetime, re, json, hashlib

nm_path        = pathlib.Path(sys.argv[1])
archive_path   = pathlib.Path(sys.argv[2])
state_path     = pathlib.Path(sys.argv[3])
history_path   = pathlib.Path(sys.argv[4])
today          = sys.argv[5]
dry_run        = sys.argv[6] == "1"
task_id_filter = sys.argv[7]   # may be empty string
decisions_dir  = pathlib.Path(sys.argv[8])

# ── Load existing NM entries ──────────────────────────────────────────────────
data = yaml.safe_load(nm_path.read_text()) or {}
existing_entries = data.get("entries") or []
# Build set of (phase, change_kind, approach_hash) for dedup
def _approach_hash(phase: str, change_kind: str, approach: str) -> str:
    key = f"{phase}||{change_kind}||{approach.strip().lower()}"
    return hashlib.md5(key.encode()).hexdigest()[:12]

existing_hashes = set()
for e in existing_entries:
    sig = e.get("signature") or {}
    h = _approach_hash(
        sig.get("phase", ""),
        sig.get("change_kind", ""),
        sig.get("approach", ""),
    )
    existing_hashes.add(h)

# ── Parse history files ───────────────────────────────────────────────────────
def parse_history_blocks(text: str) -> list[dict]:
    """Extract yaml blocks between ```yaml fences that contain 'signature:' key."""
    blocks = []
    fence_re = re.compile(r'```(?:yaml)?\n(.*?)```', re.DOTALL)
    for m in fence_re.finditer(text):
        body = m.group(1)
        if 'signature:' not in body and 'outcome:' not in body:
            continue
        try:
            obj = yaml.safe_load(body)
            if isinstance(obj, dict):
                blocks.append(obj)
        except Exception:
            pass
    return blocks

history_blocks: list[dict] = []
for path in (state_path, history_path):
    if path.exists():
        text = path.read_text()
        history_blocks.extend(parse_history_blocks(text))

# Filter by task_id if provided
if task_id_filter:
    history_blocks = [b for b in history_blocks if b.get("task") == task_id_filter
                      or (b.get("task_id") == task_id_filter)]

# ── Find failed approaches ────────────────────────────────────────────────────
# A "failed approach" is:
#   1. Any block with outcome in (rolled_back, failed)
#      AND signature.approach is present (free-text)
#   2. Same (phase, change_kind, approach_hash) seen >=2 times with bad outcome

from collections import defaultdict

# approach_key -> list of {task_id, outcome, phase, change_kind, approach, failure_class}
approach_failures: dict[str, list[dict]] = defaultdict(list)

for block in history_blocks:
    sig = block.get("signature") or {}
    outcome = sig.get("outcome") or block.get("outcome") or ""
    if outcome not in ("rolled_back", "failed"):
        continue
    phase       = sig.get("phase", "")
    change_kind = sig.get("change_kind", "")
    approach    = sig.get("approach", "")    # may be missing in older entries
    failure_class = sig.get("failure_class", "")
    task_id     = block.get("task") or block.get("task_id") or ""

    if not approach:
        # No approach text — cannot generate useful negative-memory entry
        continue

    key = _approach_hash(phase, change_kind, approach)
    approach_failures[key].append({
        "task_id": task_id,
        "outcome": outcome,
        "phase": phase,
        "change_kind": change_kind,
        "approach": approach,
        "failure_class": failure_class,
    })

# ── Emit candidates for approaches with >=2 failures ─────────────────────────
candidates_added = 0
now_date = today
ttl_date = (datetime.date.fromisoformat(today) + datetime.timedelta(days=90)).isoformat()

new_entries = []
for key, failures in approach_failures.items():
    if len(failures) < 2:
        continue
    if key in existing_hashes:
        continue

    # Representative failure
    rep = failures[0]
    task_ids = list({f["task_id"] for f in failures if f["task_id"]})

    # Generate a conservative failure_mode description
    failure_modes = list({f["failure_class"] for f in failures if f["failure_class"]})
    failure_mode_text = f"repeated {', '.join(failure_modes)} failures" if failure_modes else "repeated failures"

    candidate = {
        "id": f"NM-CANDIDATE-{key[:8]}",
        "signature": {
            "phase": rep["phase"],
            "change_kind": rep["change_kind"] or None,
            "approach": rep["approach"],
        },
        "failure_mode": failure_mode_text,
        "added_at": now_date,
        "ttl_expires": ttl_date,
        "unblock_criteria": [],
        "cites": {"source_tasks": task_ids},
        "status": "candidate",
        "auto_generated": True,
    }

    print(f"CANDIDATE: {candidate['id']} — phase={rep['phase']} approach=\"{rep['approach'][:60]}\"", flush=True)
    new_entries.append(candidate)
    candidates_added += 1

if candidates_added == 0:
    print("COMPILE_DONE: 0 candidates generated", flush=True)
    sys.exit(0)

if dry_run:
    print(f"COMPILE_DRY: {candidates_added} candidates would be added", flush=True)
    sys.exit(1)

# ── Write candidates + emit Tier B decisions ──────────────────────────────────
data["entries"] = existing_entries + new_entries
nm_path.write_text(yaml.dump(data, allow_unicode=True, sort_keys=False))
print(f"COMPILE_DONE: {candidates_added} candidates written", flush=True)

# Emit one Tier B decision per candidate
decisions_dir.mkdir(parents=True, exist_ok=True)
for entry in new_entries:
    dec_id = f"nm-approve-{entry['id'].lower()}"
    dec_file = decisions_dir / f"{dec_id}.yaml"
    summary = entry["signature"]["approach"][:80]
    dec = {
        "id": dec_id,
        "type": "tier-b",
        "trigger": "negative-memory-candidate",
        "question": (
            f"Negative memory candidate {entry['id']}: approach \"{summary}\" "
            f"failed {len(approach_failures[_approach_hash(entry['signature']['phase'], entry['signature'].get('change_kind',''), entry['signature']['approach'])]):d} times "
            f"({entry['failure_mode']}). Approve as active don't-retry prior? [default: yes in 10 min]"
        ),
        "options": {
            "A": {
                "label": "Approve — mark entry active",
                "description": "Entry will block this approach until unblock criteria are defined and met",
                "default": True,
            },
            "B": {
                "label": "Reject — discard candidate",
                "description": "Entry removed; failures considered coincidence",
            },
            "C": {
                "label": "Approve with edit — open entry for manual refinement",
                "description": "Mark active but add a note that unblock_criteria need founder input",
            },
        },
        "status": "pending",
        "expires_at": f"{ttl_date}T00:00:00Z",
        "default_option": "A",
        "nm_id": entry["id"],
        "cites": entry["cites"],
    }
    dec_file.write_text(yaml.dump(dec, allow_unicode=True, sort_keys=False))
    print(f"DECISION_WRITTEN: {dec_file}", flush=True)

sys.exit(1)   # exit 1 = candidates generated (founder approval pending)
PY

[[ "$COMPILE_EXIT" -eq 1 ]] && CANDIDATES_GENERATED=1

# Unconditional: runs regardless of COMPILE_EXIT (0, 1, 2, or a real crash).
command -v mem_backup_verify_or_restore >/dev/null 2>&1 && mem_backup_verify_or_restore "$NM_FILE" "entries" || true

# MEM-SEMANTIC-RECALL-01 fix round (H3): re-sync the semantic index on every
# compile run (TTL sweeps + Tier-B-approved status flips both change which
# entries are "active" — backfill is idempotent/re-runnable and content_hash
# gated, so this is cheap when nothing changed). Best-effort only — never
# affects this script's own exit code.
if [[ -f "${SCRIPT_DIR}/leadv2-semantic-backfill.sh" ]]; then
  bash "${SCRIPT_DIR}/leadv2-semantic-backfill.sh" "$PROJECT_ROOT" >/dev/null 2>&1 || true
fi

# Final exit code
if [[ "$CANDIDATES_GENERATED" -eq 1 && "$TTL_EXIT" -eq 2 ]]; then
  exit 3   # both changes
elif [[ "$CANDIDATES_GENERATED" -eq 1 ]]; then
  exit 1
elif [[ "$TTL_EXIT" -eq 2 ]]; then
  exit 2
else
  exit 0
fi
