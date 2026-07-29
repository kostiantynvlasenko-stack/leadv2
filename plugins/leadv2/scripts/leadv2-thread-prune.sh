#!/usr/bin/env bash
# leadv2-thread-prune.sh — resolution path for open-threads.md (OPEN-THREADS-HYGIENE-01).
#
# Problem this fixes: open-threads.md's "## Captured asks (auto)" section
# (leadv2-task-anchor.sh's capture_ask) only ever grew — entries were never
# marked handled, so the file accumulated hundreds of stale one-liners
# (several answered the same session they were captured in) until the
# hard 40-entry cap silently dropped the oldest ones. That's forgetting on
# a timer, not resolution.
#
# Fix: an item belongs in open-threads.md only while it is genuinely open —
# a question awaiting an answer, a promised action not yet taken, or a live
# background job. This script is the resolution path: `resolve` removes a
# matching entry immediately (no intermediate "- [x]" state to reaccumulate,
# no separate cleanup pass required). `prune` is a defensive belt-and-braces
# pass for any "- [x]" line that got in some other way (e.g. a human
# hand-checked a box in an editor instead of using `resolve`).
#
# Path resolution deliberately mirrors leadv2-task-anchor.sh's capture_ask
# (git toplevel + .claude/leadv2-overrides/state-paths.yaml's leadv2_dir,
# default docs/leadv2) rather than the LEAD-CONTROL-PLANE-01 state root
# (leadv2-state-path.sh) — capture_ask writes to the worktree-local path
# today, so resolving against a different root would silently diverge from
# the file the hook actually edits.
#
# Usage:
#   leadv2-thread-prune.sh list                # print open entries
#   leadv2-thread-prune.sh resolve <substring>  # remove entries containing <substring>; prints what was removed
#   leadv2-thread-prune.sh prune                # defensive: strip any lingering "- [x]" lines
#
# This is an explicit CLI tool, not a fail-open hook — a real error surfaces
# as a non-zero exit, it is not swallowed.

set -euo pipefail

HEADING='## Captured asks (auto)'

resolve_root() {
  git rev-parse --show-toplevel 2>/dev/null || pwd
}

resolve_leadv2_dir() {
  local root="$1" sp val
  sp="${root}/.claude/leadv2-overrides/state-paths.yaml"
  if [[ -f "$sp" ]]; then
    val="$(grep -E '^[[:space:]]*leadv2_dir[[:space:]]*:' "$sp" 2>/dev/null | head -1 \
      | sed -E 's/^[[:space:]]*leadv2_dir[[:space:]]*:[[:space:]]*//' \
      | sed -E "s/^['\"]//; s/['\"][[:space:]]*\$//" \
      | xargs 2>/dev/null || true)"
    if [[ -n "$val" && "$val" != "null" && "$val" != "~" ]]; then
      printf '%s\n' "$val"
      return 0
    fi
  fi
  printf 'docs/leadv2\n'
}

usage() {
  echo "Usage: $(basename "$0") {list|resolve <substring>|prune}" >&2
  exit 2
}

[[ $# -ge 1 ]] || usage
CMD="$1"; shift || true

ROOT="$(resolve_root)"
LEADV2_DIR="$(resolve_leadv2_dir "$ROOT")"
OT_PATH="${ROOT}/${LEADV2_DIR}/open-threads.md"

if [[ ! -f "$OT_PATH" ]]; then
  echo "no open-threads.md at ${OT_PATH} — nothing to do" >&2
  exit 0
fi

case "$CMD" in
  list)
    awk -v h="$HEADING" '
      $0 == h { inblock=1; next }
      inblock && /^- \[ \] / { print; next }
      inblock && /^## / { inblock=0 }
    ' "$OT_PATH"
    ;;

  resolve)
    [[ $# -ge 1 ]] || { echo "resolve requires a substring to match" >&2; exit 2; }
    NEEDLE="$1"
    TMP="$(mktemp "${OT_PATH}.tmp.XXXXXX")"
    trap 'rm -f "$TMP"' EXIT
    REMOVED=0
    while IFS= read -r line || [[ -n "$line" ]]; do
      if [[ "$line" == "- [ ] "* && "$line" == *"$NEEDLE"* ]]; then
        printf 'resolved: %s\n' "$line" >&2
        REMOVED=$((REMOVED + 1))
        continue
      fi
      printf '%s\n' "$line"
    done < "$OT_PATH" > "$TMP"
    if [[ "$REMOVED" -eq 0 ]]; then
      echo "no open entry matched: ${NEEDLE}" >&2
      exit 1
    fi
    mv "$TMP" "$OT_PATH"
    trap - EXIT
    if [[ "$REMOVED" -eq 1 ]]; then
      echo "removed 1 entry"
    else
      echo "removed ${REMOVED} entries"
    fi
    ;;

  prune)
    TMP="$(mktemp "${OT_PATH}.tmp.XXXXXX")"
    trap 'rm -f "$TMP"' EXIT
    REMOVED=0
    while IFS= read -r line || [[ -n "$line" ]]; do
      if [[ "$line" == "- [x] "* ]]; then
        REMOVED=$((REMOVED + 1))
        continue
      fi
      printf '%s\n' "$line"
    done < "$OT_PATH" > "$TMP"
    mv "$TMP" "$OT_PATH"
    trap - EXIT
    echo "pruned ${REMOVED} resolved entries"
    ;;

  *)
    usage
    ;;
esac
