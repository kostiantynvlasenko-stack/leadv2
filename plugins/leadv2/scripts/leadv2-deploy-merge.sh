#!/usr/bin/env bash
# leadv2-deploy-merge.sh — Phase 6 fast-forward merge + migration apply + deploy override dispatch.
# Extracted verbatim from commands/leadv2.md Phase 6 bash block (src lines 270-296).
# Run from main repo dir (after ExitWorktree). Requires LEADV2_TASK_ID env var.
# Circuit-breakers: ff-only fail, migration fail, deploy-rc fail — all exit 1.
set -euo pipefail

: "${LEADV2_TASK_ID:?LEADV2_TASK_ID must be set}"
CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-}"

git fetch origin main

# --- Step 0: divergence preflight (FIX #7) ---
BEHIND=$(git rev-list --count HEAD..origin/main 2>/dev/null || echo "0")
if [[ "$BEHIND" -gt 5 ]]; then
  printf '[DIVERGENCE_BLOCK] task branch is %s commits behind origin/main — manual rebase required before deploy\n' "$BEHIND" >&2
  exit 1
elif [[ "$BEHIND" -gt 0 ]]; then
  printf '[DIVERGENCE] task branch is %s commit(s) behind origin/main — attempting auto-rebase\n' "$BEHIND" >&2
  git rebase origin/main || {
    printf '[DIVERGENCE] rebase conflict — resolve manually then re-run deploy\n' >&2
    exit 1
  }
  printf '[DIVERGENCE] rebase succeeded — proceeding\n' >&2
fi

# Resolve the actual task branch (EnterWorktree makes worktree-<id>; legacy task/<id>)
TASK_BRANCH=""
for _b in "task/$LEADV2_TASK_ID" "worktree-$LEADV2_TASK_ID"; do
  git show-ref --verify --quiet "refs/heads/$_b" && { TASK_BRANCH="$_b"; break; }
done
[[ -z "$TASK_BRANCH" ]] && { echo "no task branch (task/ or worktree-) for $LEADV2_TASK_ID" >&2; exit 1; }
# Rebase the task branch onto origin/main if it is not already a fast-forward (handles stale local main)
if ! git merge-base --is-ancestor origin/main "$TASK_BRANCH"; then
  git rebase origin/main "$TASK_BRANCH" || { echo "rebase onto origin/main conflict — resolve manually" >&2; exit 1; }
fi
git checkout main 2>/dev/null || true
git pull --ff-only origin main || { echo "main moved during task — manual rebase needed"; exit 1; }
git merge --ff-only "$TASK_BRANCH" || { echo "ff-only merge failed — rebase task branch first"; exit 1; }
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
  deploy_rc=0
  LEAD_V2_TASK_ID="$LEADV2_TASK_ID" LEAD_V2_COMMIT="$COMMIT" bash "$OVERRIDE" || deploy_rc=$?
else
  echo "BLOCK: .claude/leadv2-overrides/deploy.sh not found — run leadv2-init or create it" >&2
  exit 1
fi
[[ $deploy_rc -eq 0 ]] || { echo "Deploy failed (exit $deploy_rc)" >&2; exit 1; }
echo "Deploy complete (commit $COMMIT)"
