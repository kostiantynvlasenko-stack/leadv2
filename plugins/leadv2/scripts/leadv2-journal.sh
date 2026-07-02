#!/usr/bin/env bash
# leadv2-journal.sh — durable per-task journal ("context is cache, disk is truth").
# Usage:
#   leadv2-journal.sh append <task-id> <type> <text...>
#   leadv2-journal.sh tail   <task-id> [N]   (N default 10)
#
# Journal path: ${PROJECT_ROOT}/${leadv2_dir}/tasks/<task-id>/journal.md
# Single-writer, plain-append design — no locking needed.

set -euo pipefail
trap 'exit 0' ERR

SCRIPT_NAME="leadv2-journal"
PROJECT_ROOT="${CLAUDE_PROJECT_ROOT:-${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}}"

log_err() {
  printf -- '[%s] ERROR: %s\n' "$SCRIPT_NAME" "$*" >&2
}

# ── resolve leadv2_dir from state-paths.yaml (mirrors leadv2-pre-compact-checkpoint.sh) ──
_lv2_sp_yaml="${PROJECT_ROOT}/.claude/leadv2-overrides/state-paths.yaml"
_lv2_leadv2_dir=$(grep -E "^[[:space:]]*leadv2_dir[[:space:]]*:" "$_lv2_sp_yaml" 2>/dev/null | head -1 | sed -E "s/^[[:space:]]*leadv2_dir[[:space:]]*:[[:space:]]*//" | sed -E "s/^['\"']//; s/['\"'][[:space:]]*$//" | tr -d '\r' || true)
[[ -z "$_lv2_leadv2_dir" || "$_lv2_leadv2_dir" == "null" || "$_lv2_leadv2_dir" == "~" ]] && _lv2_leadv2_dir="docs/leadv2"

# ── argument validation ────────────────────────────────────────────────────────
if [[ $# -lt 2 ]]; then
  log_err "Usage: $0 append <task-id> <type> <text...> | $0 tail <task-id> [N]"
  exit 1
fi

MODE="$1"
RAW_TASK_ID="$2"
shift 2

# Sanitize task-id: keep only [A-Za-z0-9._-] (strips slashes, spaces, etc.)
TASK_ID="$(printf -- '%s' "$RAW_TASK_ID" | tr -cd 'A-Za-z0-9._-')"
if [[ -z "$TASK_ID" ]]; then
  log_err "task-id must not be empty after sanitization"
  exit 1
fi

TASK_DIR="${PROJECT_ROOT}/${_lv2_leadv2_dir}/tasks/${TASK_ID}"
JOURNAL_FILE="${TASK_DIR}/journal.md"

case "$MODE" in
  append)
    if [[ $# -lt 2 ]]; then
      log_err "Usage: $0 append <task-id> <type> <text...>"
      exit 1
    fi
    TYPE="$1"
    shift
    TEXT="$*"

    # Type whitelist: phase decision finding error note; anything else -> note.
    case "$TYPE" in
      phase|decision|finding|error|note) ;;
      *) TYPE="note" ;;
    esac

    mkdir -p "$TASK_DIR"
    UTC_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf -- '- %s [%s] %s\n' "$UTC_ISO" "$TYPE" "$TEXT" >> "$JOURNAL_FILE"
    ;;
  tail)
    N="${1:-10}"
    [[ "$N" =~ ^[0-9]+$ ]] || N=10
    if [[ ! -f "$JOURNAL_FILE" ]]; then
      exit 0
    fi
    tail -n "$N" "$JOURNAL_FILE"
    ;;
  *)
    log_err "Unknown mode: $MODE (expected 'append' or 'tail')"
    exit 1
    ;;
esac
