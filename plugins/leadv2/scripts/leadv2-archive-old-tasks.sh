#!/usr/bin/env bash
# leadv2-archive-old-tasks.sh
#
# Move closed leadv2 task directories to docs/leadv2/archive/<task-id>/
# when their STATE.md is older than MTIME_DAYS days (default: 60) AND
# contains a terminal phase/status marker.
#
# DEFAULT MODE = --dry-run. Prints what WOULD be moved. Nothing is touched.
# Founder reviews output and runs with --apply to actually move.
#
# Usage:
#   bash .claude/scripts/leadv2-archive-old-tasks.sh            # dry-run
#   bash .claude/scripts/leadv2-archive-old-tasks.sh --dry-run  # explicit
#   bash .claude/scripts/leadv2-archive-old-tasks.sh --apply    # move files
#   MTIME_DAYS=90 bash ... --apply                              # override age threshold

set -euo pipefail

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
readonly PROJECT_ROOT
readonly TASKS_DIR="${PROJECT_ROOT}/docs/leadv2/tasks"
readonly ARCHIVE_DIR="${PROJECT_ROOT}/docs/leadv2/archive"
readonly MTIME_DAYS="${MTIME_DAYS:-60}"

# Terminal markers — grep -E pattern applied to each STATE.md
readonly TERMINAL_PATTERN='(^phase:[[:space:]]*(close|closed)|^status:[[:space:]]*(closed|done|complete)|phase:[[:space:]]*(close|closed)|status:[[:space:]]*(closed|done|complete))'

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log()  { printf -- '[leadv2-archive] %s\n' "$*" >&2; }
info() { printf -- '%s\n' "$*"; }

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
DRY_RUN=1  # default: dry-run

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --apply)   DRY_RUN=0 ;;
    *)
      printf -- 'Usage: %s [--dry-run|--apply]\n' "$(basename "$0")" >&2
      exit 1
      ;;
  esac
done

if (( DRY_RUN )); then
  log "DRY-RUN mode (default). Pass --apply to move files."
fi

# ---------------------------------------------------------------------------
# Validate tasks dir exists
# ---------------------------------------------------------------------------
if [[ ! -d "$TASKS_DIR" ]]; then
  log "Tasks directory not found: $TASKS_DIR"
  exit 1
fi

# ---------------------------------------------------------------------------
# Collect candidates
# ---------------------------------------------------------------------------
candidates=()
skipped_no_state=0
skipped_too_recent=0
skipped_no_terminal=0

while IFS= read -r -d '' task_dir; do
  task_id="$(basename "$task_dir")"
  state_file="${task_dir}/STATE.md"

  # Must have STATE.md
  if [[ ! -f "$state_file" ]]; then
    (( skipped_no_state++ )) || true
    continue
  fi

  # mtime check — macOS stat uses -f %m, Linux uses -c %Y
  mtime=$(stat -f %m "$state_file" 2>/dev/null || stat -c %Y "$state_file" 2>/dev/null || echo 0)
  now=$(date +%s)
  age_days=$(( (now - mtime) / 86400 ))

  if (( age_days < MTIME_DAYS )); then
    (( skipped_too_recent++ )) || true
    continue
  fi

  # Terminal marker check
  if ! grep -qE "$TERMINAL_PATTERN" "$state_file" 2>/dev/null; then
    (( skipped_no_terminal++ )) || true
    continue
  fi

  candidates+=("$task_id:$age_days")
done < <(find "$TASKS_DIR" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)

# ---------------------------------------------------------------------------
# Report / Act
# ---------------------------------------------------------------------------
info "--- leadv2 archive scan ---"
info "Tasks dir:    ${TASKS_DIR}"
info "Archive dir:  ${ARCHIVE_DIR}"
info "Age threshold: ${MTIME_DAYS} days"
info "Mode: $([ "$DRY_RUN" -eq 1 ] && echo 'DRY-RUN (no files moved)' || echo 'APPLY (moving files)')"
info ""

if (( ${#candidates[@]} == 0 )); then
  info "No tasks qualify for archiving."
  info "  skipped (no STATE.md):      $skipped_no_state"
  info "  skipped (too recent):       $skipped_too_recent"
  info "  skipped (no terminal mark): $skipped_no_terminal"
  exit 0
fi

info "Tasks that WOULD be archived (${#candidates[@]}):"
for entry in "${candidates[@]}"; do
  task_id="${entry%%:*}"
  age_days="${entry##*:}"
  printf -- '  %-40s  (%d days old)\n' "$task_id" "$age_days"
done

info ""
info "Skipped:"
info "  no STATE.md:        $skipped_no_state"
info "  too recent (<${MTIME_DAYS}d):  $skipped_too_recent"
info "  no terminal marker: $skipped_no_terminal"

if (( DRY_RUN )); then
  info ""
  info "To apply: bash .claude/scripts/leadv2-archive-old-tasks.sh --apply"
  exit 0
fi

# ---------------------------------------------------------------------------
# Apply: move each candidate to archive/
# ---------------------------------------------------------------------------
if [[ ! -d "$ARCHIVE_DIR" ]]; then
  mkdir -p "$ARCHIVE_DIR"
  log "Created archive dir: $ARCHIVE_DIR"
fi

moved=0
failed=0

for entry in "${candidates[@]}"; do
  task_id="${entry%%:*}"
  src="${TASKS_DIR}/${task_id}"
  dst="${ARCHIVE_DIR}/${task_id}"

  if [[ -d "$dst" ]]; then
    log "SKIP ${task_id}: already exists in archive (${dst})"
    (( failed++ )) || true
    continue
  fi

  mv "$src" "$dst"
  log "Moved ${task_id} → archive/"
  (( moved++ )) || true
done

info ""
info "Done. Moved: $moved  Failed/skipped: $failed"
