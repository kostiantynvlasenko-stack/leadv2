#!/usr/bin/env bash
# tests/test-leadv2-worktree-sweep.sh — Unit tests for leadv2-worktree-cleanup.sh --sweep-merged
#
# Tests:
#   1. Merged agent-<hex> worktree is removed; its branch is deleted.
#   2. Unmerged agent-<hex> worktree is kept.
#   3. CWD worktree is never removed even if its branch is merged.
#   4. Non-agent worktrees (e.g. named task worktrees) are ignored.
#   5. bash -n syntax check on the cleanup script.
#
# Run: bash scripts/tests/test-leadv2-worktree-sweep.sh
# Exit 0 = all pass; non-zero = failures found.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLEANUP_SH="${SCRIPT_DIR}/../leadv2-worktree-cleanup.sh"

PASS=0
FAIL=0
ERRORS=()

log()  { printf -- '[TEST] %s\n' "$*"; }
pass() { PASS=$(( PASS + 1 )); log "PASS: $1"; }
fail() { FAIL=$(( FAIL + 1 )); ERRORS+=("FAIL: $1"); log "FAIL: $1"; }

# ── syntax check ──────────────────────────────────────────────────────────────
if bash -n "$CLEANUP_SH" 2>/dev/null; then
  pass "bash -n syntax check"
else
  fail "bash -n syntax check"
fi

# ── build a scratch git repo ──────────────────────────────────────────────────
SCRATCH="$(mktemp -d)"
# shellcheck disable=SC2064
trap "rm -rf '${SCRATCH}'" EXIT

git -C "$SCRATCH" init -q
git -C "$SCRATCH" config user.email "test@test"
git -C "$SCRATCH" config user.name  "Test"
printf 'init\n' > "${SCRATCH}/README"
git -C "$SCRATCH" add README
git -C "$SCRATCH" commit -q -m "init"

# Helper: create a worktree under .claude/worktrees/<name> on a new branch
make_agent_wt() {
  local name="$1"
  local branch="agent-${name}"
  local wt_path="${SCRATCH}/.claude/worktrees/${name}"
  mkdir -p "$(dirname "$wt_path")"
  git -C "$SCRATCH" worktree add -q -b "$branch" "$wt_path"
  printf '%s\n' "$name" > "${wt_path}/file-${name}.txt"
  git -C "$wt_path" add .
  git -C "$wt_path" commit -q -m "work in ${name}"
  printf -- '%s\n' "$wt_path"
}

# ── Test 1: merged agent worktree is removed ──────────────────────────────────
WT_MERGED=$(make_agent_wt "agent-aabbccdd")
BRANCH_MERGED="agent-agent-aabbccdd"
git -C "$SCRATCH" merge -q --no-ff "$BRANCH_MERGED" -m "merge agent-aabbccdd"

(cd "$SCRATCH" && bash "$CLEANUP_SH" --sweep-merged) >/dev/null 2>&1
if [[ ! -d "$WT_MERGED" ]]; then
  pass "merged agent worktree removed"
else
  fail "merged agent worktree still present after sweep"
fi
if ! git -C "$SCRATCH" branch --list "$BRANCH_MERGED" | grep -q .; then
  pass "merged agent branch deleted"
else
  fail "merged agent branch still exists after sweep"
fi

# ── Test 2: unmerged agent worktree is kept ───────────────────────────────────
WT_UNMERGED=$(make_agent_wt "agent-deadbeef")
# Do NOT merge — branch is ahead of default

(cd "$SCRATCH" && bash "$CLEANUP_SH" --sweep-merged) >/dev/null 2>&1
if [[ -d "$WT_UNMERGED" ]]; then
  pass "unmerged agent worktree kept"
else
  fail "unmerged agent worktree was incorrectly removed"
fi

# ── Test 3: CWD worktree is never removed ────────────────────────────────────
MAIN_WT_PATH="$(git -C "$SCRATCH" rev-parse --show-toplevel)"
(cd "$SCRATCH" && bash "$CLEANUP_SH" --sweep-merged) >/dev/null 2>&1
if [[ -d "$MAIN_WT_PATH" ]]; then
  pass "CWD (main) worktree not removed"
else
  fail "CWD (main) worktree was removed — critical bug"
fi

# ── Test 4: non-agent worktree is ignored ─────────────────────────────────────
TASK_WT="${SCRATCH}/.claude/worktrees/MY-TASK-01"
mkdir -p "$(dirname "$TASK_WT")"
git -C "$SCRATCH" worktree add -q -b "worktree-MY-TASK-01" "$TASK_WT"
git -C "$SCRATCH" merge -q --no-ff "worktree-MY-TASK-01" -m "merge task wt" || true

(cd "$SCRATCH" && bash "$CLEANUP_SH" --sweep-merged) >/dev/null 2>&1
if [[ -d "$TASK_WT" ]]; then
  pass "non-agent task worktree not touched by sweep"
else
  fail "non-agent task worktree was incorrectly removed"
fi

# ── summary ───────────────────────────────────────────────────────────────────
printf -- '\n'
printf -- 'Results: %d passed, %d failed\n' "$PASS" "$FAIL"
if [[ "${#ERRORS[@]}" -gt 0 ]]; then
  printf -- '%s\n' "${ERRORS[@]}"
  exit 1
fi
exit 0
