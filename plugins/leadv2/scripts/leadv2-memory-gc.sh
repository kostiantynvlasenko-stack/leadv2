#!/usr/bin/env bash
# SHELL=/bin/bash
# leadv2-memory-gc.sh - Memory GC for leadv2 memory stores.
# Args: --project-root <path>  --apply  --max-age-days N
# Checks: (a) stale paths  (b) duplicates  (c) archive candidates
# Output: docs/leadv2/memory-gc-report.md  docs/leadv2/.memory-gc-last
# Exit: 0=ok 1=fatal. SHELL=/bin/bash required for cron.

set -euo pipefail

log()      { printf -- '[%s] %s\n' "$(date +'%Y-%m-%d %H:%M:%S')" "$*" >&2; }
log_info() { log "INFO:  $*"; }
log_error(){ log "ERROR: $*"; }

PROJECT_ROOT="${PWD}"
APPLY=0
MAX_AGE_DAYS=90

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-root) PROJECT_ROOT="$2"; shift 2 ;;
    --apply)        APPLY=1;           shift   ;;
    --max-age-days) MAX_AGE_DAYS="$2"; shift 2 ;;
    -h|--help) printf -- 'Usage: %s [--project-root <path>] [--apply] [--max-age-days N]\n' "$(basename "$0")" >&2; exit 0 ;;
    *) log_error "Unknown arg: $1"; exit 1 ;;
  esac
done

PROJECT_ROOT="$(cd "$PROJECT_ROOT" 2>/dev/null && pwd)" || { log_error "project-root not accessible"; exit 1; }
command -v python3 &>/dev/null || { log_error "python3 required"; exit 1; }

LEADV2_DIR="${PROJECT_ROOT}/docs/leadv2"
REPORT_FILE="${LEADV2_DIR}/memory-gc-report.md"
STAMP_FILE="${LEADV2_DIR}/.memory-gc-last"
ARCHIVE_FILE="${LEADV2_DIR}/memory-gc-archive.yaml"
mkdir -p "$LEADV2_DIR"

log_info "Memory GC starting (project-root=${PROJECT_ROOT} apply=${APPLY} max-age-days=${MAX_AGE_DAYS})"

# ── copy bundled python scripts from plugin dir ────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GC_LOGIC="${SCRIPT_DIR}/leadv2-memory-gc-logic.py"
GC_RENDER="${SCRIPT_DIR}/leadv2-memory-gc-render.py"

if [[ ! -f "$GC_LOGIC" || ! -f "$GC_RENDER" ]]; then
  log_error "Missing bundled python helpers: $GC_LOGIC / $GC_RENDER"
  exit 1
fi

# ── run GC logic ─────────────────────────────────────────────────────────────
GC_OUTPUT="$(
  IMMUNE_FILE="${PROJECT_ROOT}/docs/leadv2/immune-patterns.yaml" \
  NM_FILE="${PROJECT_ROOT}/docs/leadv2-negative-memory.yaml" \
  PRIORS_FILE="${PROJECT_ROOT}/docs/leadv2-priors.yaml" \
  PATTERNS_MD="${PROJECT_ROOT}/.claude/ref/lead-patterns.md" \
  PROJECT_ROOT="$PROJECT_ROOT" \
  APPLY="$APPLY" \
  MAX_AGE_DAYS="$MAX_AGE_DAYS" \
  ARCHIVE_FILE="$ARCHIVE_FILE" \
  python3 "$GC_LOGIC"
)"

# ── parse counts ─────────────────────────────────────────────────────────────
COUNT_STALE=$(printf -- '%s' "$GC_OUTPUT" | python3 -c 'import sys,json; print(json.load(sys.stdin)["counts"]["stale"])' 2>/dev/null || printf -- '?')
COUNT_DUPES=$(printf -- '%s' "$GC_OUTPUT" | python3 -c 'import sys,json; print(json.load(sys.stdin)["counts"]["duplicates"])' 2>/dev/null || printf -- '?')
COUNT_ARCH=$(printf -- '%s' "$GC_OUTPUT" | python3 -c 'import sys,json; print(json.load(sys.stdin)["counts"]["archive"])' 2>/dev/null || printf -- '?')
log_info "Counts — stale:${COUNT_STALE} duplicates:${COUNT_DUPES} archive-candidates:${COUNT_ARCH}"

# ── write report ─────────────────────────────────────────────────────────────
REPORT_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
APPLY_NOTE="report-only"
[[ "$APPLY" == "1" ]] && APPLY_NOTE="--apply (dedupes written; stale+archive-candidates are report-only)"

GC_OUTPUT_ESC="$GC_OUTPUT" \
REPORT_TS="$REPORT_TS" \
APPLY_NOTE="$APPLY_NOTE" \
PR_LABEL="$PROJECT_ROOT" \
MA_LABEL="$MAX_AGE_DAYS" \
COUNT_STALE="$COUNT_STALE" \
COUNT_DUPES="$COUNT_DUPES" \
COUNT_ARCH="$COUNT_ARCH" \
python3 "$GC_RENDER" > "$REPORT_FILE"

log_info "Report written to ${REPORT_FILE}"
date +%s > "$STAMP_FILE" 2>/dev/null || true
log_info "Memory GC complete."
exit 0
