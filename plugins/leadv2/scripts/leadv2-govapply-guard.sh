#!/usr/bin/env bash
# leadv2-govapply-guard.sh — SHA256 drift guard + auto-backup for governance-proposal applies.
#
# Called by leadv2-shadow-apply.sh (--promote) and leadv2-migration-apply.sh before any write
# to a governance-proposal target file. Given --target (and optionally --expected-sha256
# recorded on the proposal at generation time), it:
#   (a) refuses (exit 3) if the LIVE file's sha256 no longer matches --expected-sha256 --
#       i.e. the target changed since the proposal was generated (drift);
#   (b) otherwise writes a timestamped backup (<target>.bak.<UTC-ts>) and allows the caller
#       to proceed.
#
# --expected-sha256 is OPTIONAL: a caller with no proposal-recorded baseline (e.g.
# leadv2-migration-apply.sh, which applies migration files via git diff-tree rather than a
# governance proposal record) may omit it entirely -- the drift check is skipped and only the
# backup runs. This keeps the guard reusable across both apply flows without inventing a fake
# baseline for callers that have none.
#
# USAGE:
#   leadv2-govapply-guard.sh --target <path> [--expected-sha256 <hex64>]
#
# EXIT CODES:
#   0  OK -- backup written (or bypassed via LEADV2_GOVAPPLY_NOGUARD=1); caller may proceed
#   1  usage/argument error, or no sha256 tool available
#   2  target file not found
#   3  drift detected -- live sha256 != --expected-sha256 (refuse; no backup written)
#
# ENV:
#   LEADV2_GOVAPPLY_NOGUARD=1   bypass ALL checks (warns to stderr); no backup performed
#   LEADV2_PROJECT_ROOT         used only to resolve a non-absolute --target; falls back to
#                                git toplevel, then pwd (matches sibling appliers' resolution)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LEADV2_PROJECT_ROOT="${LEADV2_PROJECT_ROOT:-${CLAUDE_PROJECT_DIR:-${PROJECT_ROOT:-$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || pwd)}}}"

log()       { printf -- '[govapply-guard] %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
log_error() { log "ERROR: $*"; }
log_warn()  { log "WARN: $*"; }
log_ok()    { log "OK: $*"; }

TARGET=""
EXPECTED_SHA256=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)          TARGET="${2:-}"; shift 2 ;;
    --expected-sha256) EXPECTED_SHA256="${2:-}"; shift 2 ;;
    -h|--help)
      printf -- 'Usage: %s --target <path> [--expected-sha256 <hex64>]\n' "$(basename "$0")" >&2
      exit 0
      ;;
    *) log_error "unknown arg: $1"; exit 1 ;;
  esac
done

if [[ -z "$TARGET" ]]; then
  log_error "--target is required"
  exit 1
fi

# Resolve repo-relative paths against LEADV2_PROJECT_ROOT; leave absolute paths untouched.
if [[ "$TARGET" != /* ]]; then
  TARGET="${LEADV2_PROJECT_ROOT}/${TARGET}"
fi

if [[ "${LEADV2_GOVAPPLY_NOGUARD:-0}" == "1" ]]; then
  log_warn "LEADV2_GOVAPPLY_NOGUARD=1 -- bypassing drift-check and backup for ${TARGET}"
  exit 0
fi

if [[ ! -f "$TARGET" ]]; then
  log_error "target file not found: ${TARGET}"
  exit 2
fi

# Portable sha256: prefer shasum -a 256 (macOS + Linux with libdigest-sha-perl), fall back to
# sha256sum (GNU coreutils, ubiquitous on the VPS/Linux side).
compute_sha256() {
  local f="$1"
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$f" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$f" | awk '{print $1}'
  else
    log_error "no sha256 tool available (need shasum or sha256sum)"
    exit 1
  fi
}

LIVE_SHA256="$(compute_sha256 "$TARGET")"

if [[ -n "$EXPECTED_SHA256" ]]; then
  if [[ "$LIVE_SHA256" != "$EXPECTED_SHA256" ]]; then
    log_error "drift detected: ${TARGET} changed since proposal generation (expected=${EXPECTED_SHA256} live=${LIVE_SHA256}) -- refusing apply"
    exit 3
  fi
  log "drift-check OK: ${TARGET} matches recorded target_sha256"
else
  log "no --expected-sha256 given -- skipping drift-check (backup only) for ${TARGET}"
fi

BACKUP_PATH="${TARGET}.bak.$(date -u +%Y%m%dT%H%M%SZ)"
cp -p "$TARGET" "$BACKUP_PATH"
log_ok "backup written: ${BACKUP_PATH}"
exit 0
