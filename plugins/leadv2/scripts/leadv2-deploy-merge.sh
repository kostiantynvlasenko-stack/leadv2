#!/usr/bin/env bash
# leadv2-deploy-merge.sh — Phase 6 fast-forward merge + migration apply + deploy override dispatch.
# Extracted verbatim from commands/leadv2.md Phase 6 bash block (src lines 270-296).
# Run from main repo dir (after ExitWorktree). Requires LEADV2_TASK_ID env var.
# Circuit-breakers: ff-only fail, migration fail, deploy-rc fail — all exit 1.
set -euo pipefail

: "${LEADV2_TASK_ID:?LEADV2_TASK_ID must be set}"
CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-}"

git fetch origin main
git checkout main 2>/dev/null || true
git pull --ff-only origin main || { echo "main moved during task — manual rebase needed"; exit 1; }
git merge --ff-only "task/$LEADV2_TASK_ID" || { echo "ff-only merge failed — rebase task branch first"; exit 1; }
git push origin main
COMMIT=$(git rev-parse HEAD)

# Apply + register any new migrations introduced by this commit.
bash "${CLAUDE_PLUGIN_ROOT}/scripts/leadv2-migration-apply.sh" --commit "$COMMIT" || {
  echo "BLOCK: migration apply/register failed — manual /migrate repair before deploy" >&2
  exit 1
}

# Deploy via project override (required — configure in .claude/leadv2-overrides/deploy.sh)
OVERRIDE="${CLAUDE_PROJECT_ROOT:-$PWD}/.claude/leadv2-overrides/deploy.sh"
if [[ -f "$OVERRIDE" ]]; then
  LEAD_V2_TASK_ID="$LEADV2_TASK_ID" LEAD_V2_COMMIT="$COMMIT" bash "$OVERRIDE"
  deploy_rc=$?
else
  echo "BLOCK: .claude/leadv2-overrides/deploy.sh not found — run leadv2-init or create it" >&2
  exit 1
fi
[[ $deploy_rc -eq 0 ]] || { echo "Deploy failed (exit $deploy_rc)" >&2; exit 1; }
echo "Deploy complete (commit $COMMIT)"
