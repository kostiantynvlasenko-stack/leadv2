#!/usr/bin/env bash
# leadv2-backfill-history.sh — synthesize LEAD_V2_STATE history entries from
# archived handoff dirs.
#
# Usage:
#   leadv2-backfill-history.sh             # adds new entries, skips existing
#   leadv2-backfill-history.sh --dry-run   # prints what would be added
#
# For each handoff dir found under docs/handoff/ and docs/handoff/archive/:
#   - Reads context.yaml (if present): task class, decisions, off_limits, agents
#   - Reads *.summary.md (if present): heuristics for codex_rounds, parallel_win,
#     involved_agents, change_kind, files_touched
#   - Constructs a synthetic history entry with backfilled: true (low-trust flag)
#   - Appends to docs/LEAD_V2_STATE.md if no entry already exists for that task-id
#
# backfilled: true signals to leadv2-priors-compile.sh and leadv2-rag-intake
# to downweight these entries (0.5x confidence vs real reflections).
#
# Env vars:
#   LEADV2_STATE_FILE — override path to LEAD_V2_STATE.md (default: docs/LEAD_V2_STATE.md)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
STATE_FILE="${LEADV2_STATE_FILE:-${REPO_ROOT}/docs/LEAD_V2_STATE.md}"
HELPER_PY="${SCRIPT_DIR}/leadv2-backfill-entry.py"

DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=true
fi

log() { printf -- '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }
log_info() { log "INFO: $*"; }
log_warn() { log "WARN: $*"; }

# ---------------------------------------------------------------------------
# Validate state file exists
# ---------------------------------------------------------------------------
if [[ ! -f "${STATE_FILE}" ]]; then
    log_warn "STATE_FILE not found: ${STATE_FILE} — nothing to backfill into"
    exit 0
fi

if [[ ! -f "${HELPER_PY}" ]]; then
    log_warn "Helper not found: ${HELPER_PY} — cannot parse entries"
    exit 1
fi

# ---------------------------------------------------------------------------
# Counter side-channel via tmpfile (avoids subshell counter-loss)
# ---------------------------------------------------------------------------
COUNTER_FILE="$(mktemp)"
printf -- '0\n0\n' > "${COUNTER_FILE}"   # line1=added, line2=skipped

# H4: track failed dirs separately (written via tmpfile to survive subshells)
FAILED_DIRS_FILE="$(mktemp)"

# K1 fix: do NOT remove the lock file in EXIT trap.
# The lock-file inode is the flock synchronization primitive — unlinking it
# allows the next process to create a fresh inode that no longer synchronizes
# with any process holding the old inode. Lock cleanup is limited to temp
# counter files only. The .backfill.lock file must persist across invocations.
cleanup() { rm -f "${COUNTER_FILE}" "${COUNTER_FILE}.tmp" "${FAILED_DIRS_FILE}" "${FAILED_DIRS_FILE}.tmp"; }
trap cleanup EXIT

append_failed_dir() {
    printf -- '%s\n' "$1" >> "${FAILED_DIRS_FILE}"
}

incr_added() {
    awk 'NR==1{print $1+1} NR!=1{print}' "${COUNTER_FILE}" > "${COUNTER_FILE}.tmp"
    mv "${COUNTER_FILE}.tmp" "${COUNTER_FILE}"
}
incr_skipped() {
    awk 'NR==2{print $1+1} NR!=2{print}' "${COUNTER_FILE}" > "${COUNTER_FILE}.tmp"
    mv "${COUNTER_FILE}.tmp" "${COUNTER_FILE}"
}

# ---------------------------------------------------------------------------
# process_dir: parse one handoff dir, append entry to STATE_FILE if new
# ---------------------------------------------------------------------------
process_dir() {
    local dir="$1"
    local task_name
    task_name="$(basename "${dir}")"

    # Call Python helper — emits YAML block or exits 0 with empty output (skip)
    # H4: on non-zero exit, record dir as failed rather than silently returning 0.
    local entry
    if ! entry="$(python3 "${HELPER_PY}" "${dir}" "${STATE_FILE}")"; then
        printf -- 'WARN F-LEARN: helper failed for %s\n' "${dir}" >&2
        append_failed_dir "${dir}"
        return 0
    fi

    if [[ -z "${entry}" ]]; then
        incr_skipped
        return 0
    fi

    incr_added

    if [[ "${DRY_RUN}" == "true" ]]; then
        printf -- '--- WOULD ADD: %s ---\n' "${task_name}"
        printf -- '%s\n' "${entry}"
        return 0
    fi

    # Append atomically under flock; re-check idempotency inside lock.
    # H1: use the Python helper's exact normalized matcher instead of a raw
    # substring grep so the in-lock check is consistent with the pre-check.
    # H3: differentiate exit codes — 0=present, 1=absent, 2+=error.
    local task_upper
    task_upper="$(printf -- '%s' "${task_name}" | tr '[:lower:]' '[:upper:]')"

    (
        flock -x 9

        check_rc=0
        python3 "${HELPER_PY}" --check-only "${task_upper}" "${STATE_FILE}" || check_rc=$?
        case "${check_rc}" in
            0)
                # task PRESENT — skip append (idempotent)
                ;;
            1)
                # task ABSENT — safe to append
                printf -- '\n%s\n' "${entry}" >> "${STATE_FILE}"
                ;;
            *)
                # MATCHER ERROR (rc>=2) — do NOT append; log and skip
                printf -- 'WARN F-LEARN: matcher failed for %s rc=%s — skipping append\n' \
                    "${task_upper}" "${check_rc}" >&2
                ;;
        esac

    ) 9>"${STATE_FILE}.backfill.lock"
}

# ---------------------------------------------------------------------------
# Walk handoff directories
# ---------------------------------------------------------------------------
HANDOFF_BASE="${REPO_ROOT}/docs/handoff"

for dir in "${HANDOFF_BASE}"/*/; do
    [[ -d "${dir}" ]] || continue
    process_dir "${dir}"
done

# Walk archive subdir
if [[ -d "${HANDOFF_BASE}/archive" ]]; then
    for dir in "${HANDOFF_BASE}/archive/"/*/; do
        [[ -d "${dir}" ]] || continue
        process_dir "${dir}"
    done
fi

# ---------------------------------------------------------------------------
# Summary + H4 fail-loud on aggregate failure
# ---------------------------------------------------------------------------
added="$(awk 'NR==1' "${COUNTER_FILE}")"
skipped="$(awk 'NR==2' "${COUNTER_FILE}")"

# Build failed-dirs list
failed_count=0
failed_list=""
if [[ -s "${FAILED_DIRS_FILE}" ]]; then
    failed_count="$(wc -l < "${FAILED_DIRS_FILE}" | tr -d ' ')"
    failed_list="$(cat "${FAILED_DIRS_FILE}")"
fi

if [[ "${DRY_RUN}" == "true" ]]; then
    printf -- '\n[DRY-RUN] Would add %s entries, skip %s.\n' "${added}" "${skipped}" >&2
else
    log_info "Backfill complete: added=${added} skipped=${skipped} failed=${failed_count}"
fi

# H4: emit failed-dir warnings; exit non-zero when systemic failure detected
if [[ "${failed_count}" -gt 0 ]]; then
    printf -- 'WARN F-LEARN: %s dir(s) failed during backfill:\n' "${failed_count}" >&2
    printf -- '%s\n' "${failed_list}" >&2
    # If ALL dirs failed (zero entries added) and not dry-run → hard failure
    if [[ "${added}" -eq 0 && "${DRY_RUN}" != "true" ]]; then
        printf -- 'ERROR F-LEARN: no entries added and %s failure(s) — backfill produced nothing\n' \
            "${failed_count}" >&2
        exit 2
    fi
    # Partial success (some added, some failed) → still exit 0 but list emitted above
fi
