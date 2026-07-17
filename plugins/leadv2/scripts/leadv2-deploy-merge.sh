#!/usr/bin/env bash
# leadv2-deploy-merge.sh — Phase 6 fast-forward merge + migration apply + deploy override dispatch.
# Extracted verbatim from commands/leadv2.md Phase 6 bash block (src lines 270-296).
# Run from main repo dir (after ExitWorktree). Requires LEADV2_TASK_ID env var.
# Circuit-breakers: ff-only fail, migration fail, deploy-rc fail — all exit 1.
#
# RISK-7-PERSIST-MERGE-RACE-01: this script runs inside a per-task
# Agent(devops-engineer) tool call — an `exit 1` here only kills that
# subprocess, it does NOT halt the calling lead session before Phase 8. Two
# things close that gap:
#   1. Merge serialization: the FIFO leadv2-merge-queue.sh lock is acquired
#      before the divergence/rebase/push section and released right after
#      COMMIT is captured (NOT held through the slow migration/deploy calls
#      below) — so two concurrent children never both fast-forward main.
#   2. Durable blocker: on any of the 7 ff-only-MERGE-path failure sites
#      (divergence preflight, rebase, ff-only pull/merge — NOT migration-apply
#      or deploy-override failures below, which remain a separate follow-up),
#      merge-blocker.flag is written under docs/handoff/<task>/ before
#      exiting, so Phase 8's A6 check (leadv2-phase8-assert.sh) and every
#      status=done writer (leadv2-tasks-lib.sh::leadv2_tasks_release, reached
#      by render-close.sh AND the daemon/lane-queue release path) see it even
#      in a fresh process/session — a failed ff-only merge can no longer be
#      lying-green closed.
set -euo pipefail

: "${LEADV2_TASK_ID:?LEADV2_TASK_ID must be set}"
CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-}"

# ── path resolution (same as the rest of the plugin — leadv2-helpers.sh) ────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=leadv2-helpers.sh
source "${SCRIPT_DIR}/leadv2-helpers.sh"
_lv2_load_paths

# ── merge-blocker.flag helper ────────────────────────────────────────────────
BLOCKER="${LEADV2_HANDOFF_DIR}/${LEADV2_TASK_ID}/merge-blocker.flag"
write_blocker() {
  local reason="$1"
  mkdir -p "$(dirname "$BLOCKER")"
  printf -- 'merge_blocked: true\nreason: %s\nfailed_at: %s\ntask_id: %s\n' \
    "$reason" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$LEADV2_TASK_ID" > "$BLOCKER"
}

# ── merge-queue lock: serialize concurrent Phase-6 children ─────────────────
# leadv2-merge-queue.sh already exists (FIFO, python fcntl, dead-holder
# reclaim, 1800s acquire timeout -> exit 2). Not flock(1) — absent on macOS.
MQ="${CLAUDE_PLUGIN_ROOT}/scripts/leadv2-merge-queue.sh"
"$MQ" acquire "$LEADV2_TASK_ID" || exit 2
trap '"$MQ" release "$LEADV2_TASK_ID" 2>/dev/null||true' EXIT

git fetch origin main

# --- Step 0: divergence preflight (FIX #7) ---
BEHIND=$(git rev-list --count HEAD..origin/main 2>/dev/null || echo "0")
if [[ "$BEHIND" -gt 5 ]]; then
  printf '[DIVERGENCE_BLOCK] task branch is %s commits behind origin/main — manual rebase required before deploy\n' "$BEHIND" >&2
  write_blocker "task branch is ${BEHIND} commits behind origin/main — manual rebase required before deploy"
  exit 1
elif [[ "$BEHIND" -gt 0 ]]; then
  printf '[DIVERGENCE] task branch is %s commit(s) behind origin/main — attempting auto-rebase\n' "$BEHIND" >&2
  git rebase origin/main || {
    printf '[DIVERGENCE] rebase conflict — resolve manually then re-run deploy\n' >&2
    write_blocker "rebase conflict — resolve manually then re-run deploy"
    exit 1
  }
  printf '[DIVERGENCE] rebase succeeded — proceeding\n' >&2
fi

# Resolve the actual task branch (EnterWorktree makes worktree-<id>; legacy task/<id>)
TASK_BRANCH=""
for _b in "task/$LEADV2_TASK_ID" "worktree-$LEADV2_TASK_ID"; do
  git show-ref --verify --quiet "refs/heads/$_b" && { TASK_BRANCH="$_b"; break; }
done
if [[ -z "$TASK_BRANCH" ]]; then
  echo "no task branch (task/ or worktree-) for $LEADV2_TASK_ID" >&2
  write_blocker "no task branch (task/ or worktree-) for ${LEADV2_TASK_ID}"
  exit 1
fi
# Rebase the task branch onto origin/main if it is not already a fast-forward (handles stale local main)
if ! git merge-base --is-ancestor origin/main "$TASK_BRANCH"; then
  # Phase 6 ExitWorktree keeps the task branch checked out in a worktree ->
  # `git rebase origin/main "$TASK_BRANCH"` from this (main) checkout fails with
  # "already checked out". Detect that worktree and rebase in-place instead.
  WT_PATH=""
  while IFS= read -r _line; do
    case "$_line" in
      "worktree "*) _cur="${_line#worktree }" ;;
      "branch refs/heads/$TASK_BRANCH") WT_PATH="$_cur" ;;
    esac
  done < <(git worktree list --porcelain)
  if [[ -n "$WT_PATH" ]]; then
    git -C "$WT_PATH" rebase origin/main || {
      echo "rebase onto origin/main conflict — resolve manually" >&2
      write_blocker "rebase onto origin/main conflict — resolve manually"
      exit 1
    }
  else
    git rebase origin/main "$TASK_BRANCH" || {
      echo "rebase onto origin/main conflict — resolve manually" >&2
      write_blocker "rebase onto origin/main conflict — resolve manually"
      exit 1
    }
  fi
fi
git checkout main 2>/dev/null || true
git pull --ff-only origin main || {
  echo "main moved during task — manual rebase needed"
  write_blocker "main moved during task — manual rebase needed"
  exit 1
}
git merge --ff-only "$TASK_BRANCH" || {
  echo "ff-only merge failed — rebase task branch first"
  write_blocker "ff-only merge failed — rebase task branch first"
  exit 1
}
git push origin main
COMMIT=$(git rev-parse HEAD)

# Merge succeeded — clear any stale blocker from a prior failed attempt, and
# release the lock now (NOT held through the slow migration/deploy section
# below).
rm -f "$BLOCKER"
"$MQ" release "$LEADV2_TASK_ID" || {
  write_blocker "post-merge release failed — main advanced but deploy did not run"
  exit 1
}
trap - EXIT

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
