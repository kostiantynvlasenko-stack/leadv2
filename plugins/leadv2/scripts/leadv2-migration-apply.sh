#!/usr/bin/env bash
set -euo pipefail
COMMIT=""
while [[ $# -gt 0 ]]; do case "$1" in --commit) COMMIT="${2:-}"; shift 2;; *) shift;; esac; done
[[ -z "$COMMIT" ]] && COMMIT="$(git rev-parse HEAD)"
MIG_DIR="${LEADV2_MIGRATION_DIR:-supabase/migrations}"
CHANGED="$(git diff-tree --no-commit-id --name-only -r "$COMMIT" -- "$MIG_DIR" 2>/dev/null || true)"
if [[ -z "$CHANGED" ]]; then echo "[migration-apply] no migrations in $COMMIT — no-op"; exit 0; fi
echo "[migration-apply] migrations changed:"; echo "$CHANGED"
OVERRIDE="${CLAUDE_PROJECT_ROOT:-$PWD}/.claude/leadv2-overrides/migrate.sh"
if [[ -x "$OVERRIDE" ]]; then bash "$OVERRIDE" --commit "$COMMIT" || { echo "[migration-apply] override failed" >&2; exit 1; }; exit 0; fi
echo "[migration-apply] BLOCK: migrations present but no .claude/leadv2-overrides/migrate.sh — run /migrate manually" >&2
exit 1
