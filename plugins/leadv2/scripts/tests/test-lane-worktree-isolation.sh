#!/usr/bin/env bash
# tests/test-lane-worktree-isolation.sh — LANE-WORKTREE-ISOLATION-01 DoD test.
#
# DoD (docs/handoff/supervisor-scope/TASK-SPEC-worktree-isolation.md): two
# heavy lanes run concurrently, each committing to docs/tasks.yaml in the same
# minute, and BOTH changes survive — verified by reading the merged file, not
# either lane's status line. Removing isolation must make the same test fail.
#
# This exercises the real pieces end to end in a scratch repo:
#   1. leadv2-lane-worktree.sh ensure  -- creates lane A/B worktrees+branches
#      (the (a) fix: what leadv2-fanout.sh now calls before every launch).
#   2. Each lane edits a DIFFERENT row of docs/tasks.yaml and commits with
#      `git commit <path>` (pathspec form -- (d), never `git commit -a`).
#   3. Both lanes land via a ff-only rebase+merge sequence -- the same shape
#      leadv2-deploy-merge.sh already uses ((b): reviewed merge, conflict
#      loudly on overlap, never silently pick one side).
#
# Tests:
#   1. bash -n syntax check on leadv2-lane-worktree.sh.
#   2. ensure() creates two DISTINCT worktree dirs on branches worktree-A/-B.
#   3. Lane A's row survives after Lane A lands.
#   4. Lane B's row ALSO survives after Lane B lands on top of A (both rows
#      present in the same file -- the actual clobber this task fixes).
#   5. A genuine overlapping edit (same row, both lanes) is REFUSED loudly
#      (non-zero rc, no silent pick-one-side) rather than merged.
#
# Run: bash scripts/tests/test-lane-worktree-isolation.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LANE_SH="${SCRIPT_DIR}/../leadv2-lane-worktree.sh"

PASS=0
FAIL=0
ERRORS=()

log()  { printf -- '[TEST] %s\n' "$*"; }
pass() { PASS=$(( PASS + 1 )); log "PASS: $1"; }
fail() { FAIL=$(( FAIL + 1 )); ERRORS+=("FAIL: $1"); log "FAIL: $1"; }

# ── syntax check ─────────────────────────────────────────────────────────────
if bash -n "$LANE_SH" 2>/dev/null; then
  pass "bash -n syntax check"
else
  fail "bash -n syntax check"
fi

# ── build a scratch git repo ─────────────────────────────────────────────────
SCRATCH="$(mktemp -d)"
# shellcheck disable=SC2064
trap "rm -rf '${SCRATCH}'" EXIT

git -C "$SCRATCH" init -q -b main
git -C "$SCRATCH" config user.email "test@test"
git -C "$SCRATCH" config user.name "test"

mkdir -p "$SCRATCH/docs"
cat > "$SCRATCH/docs/tasks.yaml" <<'YAML'
tasks:
  - id: rowA
    status: queued
  - id: rowB
    status: queued
YAML
git -C "$SCRATCH" add docs/tasks.yaml
git -C "$SCRATCH" commit -q -m "seed tasks.yaml"

export LEADV2_PROJECT_ROOT="$SCRATCH"
export LEADV2_LANE_WORKTREE_ERRF="$SCRATCH/.lane-worktree.err"

# ── test 2: ensure() creates two distinct worktrees ─────────────────────────
laneA_dir="$(bash "$LANE_SH" ensure taskA heavy)"
laneB_dir="$(bash "$LANE_SH" ensure taskB heavy)"

if [[ -n "$laneA_dir" && -n "$laneB_dir" && "$laneA_dir" != "$laneB_dir" ]]; then
  pass "ensure() creates two distinct lane worktrees"
else
  fail "ensure() distinct worktrees (laneA='$laneA_dir' laneB='$laneB_dir')"
fi

if [[ "$laneA_dir" == "$SCRATCH/.claude/worktrees/taskA" ]] \
   && git -C "$SCRATCH" rev-parse --verify -q worktree-taskA >/dev/null 2>&1; then
  pass "lane A worktree path + branch match EnterWorktree/deploy-merge.sh convention"
else
  fail "lane A path/branch convention (got '$laneA_dir')"
fi

# ── edit each lane's OWN row, commit via pathspec form only ─────────────────
python3 - "$laneA_dir/docs/tasks.yaml" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read().replace("id: rowA\n    status: queued", "id: rowA\n    status: done")
open(p, "w").write(s)
PY
git -C "$laneA_dir" commit docs/tasks.yaml -m "lane A: rowA -> done" -q

python3 - "$laneB_dir/docs/tasks.yaml" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read().replace("id: rowB\n    status: queued", "id: rowB\n    status: done")
open(p, "w").write(s)
PY
git -C "$laneB_dir" commit docs/tasks.yaml -m "lane B: rowB -> done" -q

# ── land both lanes (ff-only rebase+merge, mirrors leadv2-deploy-merge.sh) ──
land() {
  local lane_dir="$1" branch="$2"
  git -C "$lane_dir" rebase main >/dev/null 2>&1 || return 1
  git -C "$SCRATCH" merge --ff-only "$branch" >/dev/null 2>&1 || return 1
}

if land "$laneA_dir" worktree-taskA; then
  pass "lane A lands ff-only onto main"
else
  fail "lane A ff-only land"
fi

if grep -q "id: rowA" "$SCRATCH/docs/tasks.yaml" && grep -A1 "id: rowA" "$SCRATCH/docs/tasks.yaml" | grep -q "status: done"; then
  pass "lane A's row survives in the merged file"
else
  fail "lane A's row missing/reverted after its own land"
fi

if land "$laneB_dir" worktree-taskB; then
  pass "lane B lands ff-only onto main (after A, same minute)"
else
  fail "lane B ff-only land"
fi

# ── DoD: both rows present in the SAME merged file, read fresh from disk ────
merged="$(cat "$SCRATCH/docs/tasks.yaml")"
if grep -A1 "id: rowA" <<<"$merged" | grep -q "status: done" \
   && grep -A1 "id: rowB" <<<"$merged" | grep -q "status: done"; then
  pass "DoD: both lanes' changes survive in the merged docs/tasks.yaml"
else
  fail "DoD: merged file is missing one lane's change (the exact clobber this task fixes)"
fi

# ── overlap case: both lanes edit the SAME row -> must conflict loudly ─────
SCRATCH2="$(mktemp -d)"
git -C "$SCRATCH2" init -q -b main
git -C "$SCRATCH2" config user.email "test@test"
git -C "$SCRATCH2" config user.name "test"
mkdir -p "$SCRATCH2/docs"
printf 'tasks:\n  - id: rowX\n    status: queued\n' > "$SCRATCH2/docs/tasks.yaml"
git -C "$SCRATCH2" add docs/tasks.yaml
git -C "$SCRATCH2" commit -q -m seed

export LEADV2_PROJECT_ROOT="$SCRATCH2"
laneC_dir="$(bash "$LANE_SH" ensure taskC heavy)"
laneD_dir="$(bash "$LANE_SH" ensure taskD heavy)"
sed -i.bak 's/status: queued/status: done-by-C/' "$laneC_dir/docs/tasks.yaml" && rm -f "$laneC_dir/docs/tasks.yaml.bak"
git -C "$laneC_dir" commit docs/tasks.yaml -m "lane C: rowX -> done-by-C" -q
sed -i.bak 's/status: queued/status: done-by-D/' "$laneD_dir/docs/tasks.yaml" && rm -f "$laneD_dir/docs/tasks.yaml.bak"
git -C "$laneD_dir" commit docs/tasks.yaml -m "lane D: rowX -> done-by-D" -q

land "$laneC_dir" worktree-taskC >/dev/null 2>&1 || true
before_overlap="$(cat "$SCRATCH2/docs/tasks.yaml")"
if land "$laneD_dir" worktree-taskD; then
  fail "overlapping edit silently landed instead of conflicting loudly"
else
  after_overlap="$(cat "$SCRATCH2/docs/tasks.yaml")"
  if [[ "$before_overlap" == "$after_overlap" ]]; then
    pass "overlapping row edit is REFUSED loudly (rc!=0), main left untouched -- never a silent pick-one-side"
  else
    fail "overlapping edit rejected but main was mutated anyway"
  fi
fi

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
if [[ "$FAIL" -gt 0 ]]; then
  printf -- '%s\n' "${ERRORS[@]}"
  exit 1
fi
exit 0
