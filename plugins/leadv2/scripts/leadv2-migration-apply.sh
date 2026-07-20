#!/usr/bin/env bash
set -euo pipefail
COMMIT=""
while [[ $# -gt 0 ]]; do case "$1" in --commit) COMMIT="${2:-}"; shift 2;; *) shift;; esac; done
[[ -z "$COMMIT" ]] && COMMIT="$(git rev-parse HEAD)"
MIG_DIR="${LEADV2_MIGRATION_DIR:-supabase/migrations}"
CHANGED="$(git diff-tree --no-commit-id --name-only -r "$COMMIT" -- "$MIG_DIR" 2>/dev/null || true)"
if [[ -z "$CHANGED" ]]; then echo "[migration-apply] no migrations in $COMMIT — no-op"; exit 0; fi
echo "[migration-apply] migrations changed:"; echo "$CHANGED"

# GOVAPPLY-GUARD-01: auto-backup each changed migration file before delegating to the override.
# No proposal-recorded baseline exists for migrations (they're derived from git diff-tree, not a
# governance proposal record), so the drift-check half of the guard is skipped -- backup only.
# LEADV2_GOVAPPLY_NOGUARD=1 bypasses entirely (guard warns to stderr). Best-effort: a backup
# failure warns but never blocks the migration apply itself.
PROJ_ROOT="${CLAUDE_PROJECT_ROOT:-${CLAUDE_PROJECT_DIR:-$PWD}}"
GOVAPPLY_GUARD="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/leadv2-govapply-guard.sh"
if [[ -f "$GOVAPPLY_GUARD" ]]; then
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    FABS="${PROJ_ROOT}/${f}"
    [[ -f "$FABS" ]] || continue
    bash "$GOVAPPLY_GUARD" --target "$FABS" || echo "[migration-apply] WARN: govapply-guard backup failed for $f" >&2
  done <<< "$CHANGED"
else
  echo "[migration-apply] WARN: govapply-guard script not found (${GOVAPPLY_GUARD}) -- skipping backup" >&2
fi

OVERRIDE="${CLAUDE_PROJECT_ROOT:-${CLAUDE_PROJECT_DIR:-$PWD}}/.claude/leadv2-overrides/migrate.sh"
if [[ -x "$OVERRIDE" ]]; then bash "$OVERRIDE" --commit "$COMMIT" || { echo "[migration-apply] override failed" >&2; exit 1; }; exit 0; fi
echo "[migration-apply] BLOCK: migrations present but no .claude/leadv2-overrides/migrate.sh — run /migrate manually" >&2
exit 1
