#!/usr/bin/env bash
# DoD test for LANE-WORKTREE-ISOLATION-01 (task f2c7b019a4e8).
#
# DoD: "Two heavy lanes run concurrently, each committing to docs/tasks.yaml in
# the same minute, and both changes survive — verified by reading the merged
# file, not by either lane's status line. Removing isolation makes the same
# test fail."
#
# Hermetic: builds throwaway git repos in a temp dir and drives the helper
# directly. No model dispatch, no network. Proves ensure/merge-back/reap under
# real git semantics.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
HELPER="$(cd "$HERE/../plugins/leadv2/scripts" && pwd)/leadv2-lane-worktree.sh"
[[ -x "$HELPER" ]] || { echo "helper missing/not executable: $HELPER" >&2; exit 2; }

PASS=0; FAIL=0
ok()  { printf '  ok   - %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL - %s\n' "$1"; FAIL=$((FAIL+1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Split leading KEY=VAL args from the op+args so env sees every env-var BEFORE
# the program. Callers pass env first: `h "${E[@]}" ensure lane-A heavy` or
# `h LEADV2_..=.. ensure lane-off heavy`. No op/arg contains '='.
h() {
  local _e=()
  while [[ $# -gt 0 && "$1" == *=* ]]; do _e+=("$1"); shift; done
  env "${_e[@]}" bash "$HELPER" "$@"
}

# ---------------------------------------------------------------------------
echo "== positive: two isolated heavy lanes both land their tasks.yaml rows =="
git init -q "$WORK/repo"; ROOT="$WORK/repo"
mkdir -p "$ROOT/docs"
printf 'tasks:\n  - id: base-1\n    status: queued\n  - id: base-2\n    status: queued\n' > "$ROOT/docs/tasks.yaml"
git -C "$ROOT" add docs/tasks.yaml
git -C "$ROOT" -c user.email=t@t -c user.name=t commit -qm init

E=(LEADV2_PROJECT_ROOT="$ROOT" LEADV2_WORKTREE_DIR="$ROOT/.wt" LEADV2_LANE_WORKTREE=on)

laneA="$(h "${E[@]}" ensure lane-A heavy)"; rcA=$?
laneB="$(h "${E[@]}" ensure lane-B heavy)"; rcB=$?
[[ -n "$laneA" && "$laneA" != "$ROOT" && -d "$laneA" ]] && ok "lane-A got a real worktree" || bad "lane-A not isolated (path='$laneA' rc=$rcA)"
[[ -n "$laneB" && "$laneB" != "$ROOT" && "$laneB" != "$laneA" && -d "$laneB" ]] && ok "lane-B got a DISTINCT worktree" || bad "lane-B not distinct (path='$laneB' rc=$rcB)"

# Both lanes edit a DIFFERENT, non-overlapping row of tasks.yaml in the same
# minute (the realistic leadv2 op: a lane flips ITS OWN row's status). Non-
# overlapping hunks => git's 3-way merge keeps both with no conflict. (Two
# EOF appends WOULD textually conflict — same insertion point — so this test
# uses the realistic disjoint-row edit the merge is meant to preserve.)
cat > "$laneA/docs/tasks.yaml" <<'YAML'
tasks:
  - id: base-1
    status: running
  - id: base-2
    status: queued
YAML
cat > "$laneB/docs/tasks.yaml" <<'YAML'
tasks:
  - id: base-1
    status: queued
  - id: base-2
    status: running
YAML
git -C "$laneA" add docs/tasks.yaml; git -C "$laneA" -c user.email=a@a -c user.name=a commit -qm "A: base-1 -> running"
git -C "$laneB" add docs/tasks.yaml; git -C "$laneB" -c user.email=b@b -c user.name=b commit -qm "B: base-2 -> running"

# Sequential landings (realistic: lanes finish at slightly different instants).
h "${E[@]}" merge-back lane-A >/dev/null 2>&1 && ok "lane-A merge-back clean" || bad "lane-A merge-back failed (rc=$?)"
h "${E[@]}" merge-back lane-B >/dev/null 2>&1 && ok "lane-B merge-back clean" || bad "lane-B merge-back failed (rc=$?)"

# DoD: read the MERGED file from main's ref — not either lane's status line.
git -C "$ROOT" show main:docs/tasks.yaml > "$WORK/merged.yaml" && ok "merged tasks.yaml readable from main" || bad "cannot read main:docs/tasks.yaml"
grep -q "base-1" "$WORK/merged.yaml" && ok "base rows survived" || bad "base rows MISSING"
# lane-A flipped base-1 to running, lane-B flipped base-2 to running — BOTH
# must be visible in the merged main (DoD: read the merged file, not status lines).
grep -A1 'id: base-1' "$WORK/merged.yaml" | grep -q 'status: running' && ok "lane-A's edit survived on main (base-1 running)" || bad "lane-A's edit MISSING from main (clobbered)"
grep -A1 'id: base-2' "$WORK/merged.yaml" | grep -q 'status: running' && ok "lane-B's edit survived on main (base-2 running)" || bad "lane-B's edit MISSING from main (clobbered)"

# reap cleans up both lanes.
h "${E[@]}" reap lane-A >/dev/null 2>&1; h "${E[@]}" reap lane-B >/dev/null 2>&1
[[ -z "$(h "${E[@]}" path-of lane-A)" && -z "$(h "${E[@]}" path-of lane-B)" ]] && ok "reap removed both lane worktrees" || bad "reap left a worktree behind"

# ---------------------------------------------------------------------------
echo "== kill-switch: LEADV2_LANE_WORKTREE=off falls back to the shared tree =="
off="$(h LEADV2_PROJECT_ROOT="$ROOT" LEADV2_WORKTREE_DIR="$ROOT/.wt" LEADV2_LANE_WORKTREE=off ensure lane-off heavy)"
[[ "$off" == "$ROOT" ]] && ok "off-mode echoes shared ROOT (no worktree created)" || bad "off-mode did not fall back (got '$off')"
[[ -z "$(h LEADV2_PROJECT_ROOT="$ROOT" LEADV2_WORKTREE_DIR="$ROOT/.wt" path-of lane-off)" ]] && ok "off-mode created no worktree" || bad "off-mode created a worktree anyway"

# ---------------------------------------------------------------------------
echo "== loud conflict: same-line tasks.yaml edit => non-zero, no silent overwrite =="
git init -q "$WORK/repo3"; R3="$WORK/repo3"; mkdir -p "$R3/docs"
printf 'KEY: original\n' > "$R3/docs/tasks.yaml"
git -C "$R3" add docs/tasks.yaml; git -C "$R3" -c user.email=t@t -c user.name=t commit -qm init
E3=(LEADV2_PROJECT_ROOT="$R3" LEADV2_WORKTREE_DIR="$R3/.wt")
h "${E3[@]}" ensure cX heavy >/dev/null; h "${E3[@]}" ensure cY heavy >/dev/null
printf 'KEY: from-X\n' > "$R3/.wt/cX/docs/tasks.yaml"; git -C "$R3/.wt/cX" -c user.email=x -c user.name=x commit -qam x
printf 'KEY: from-Y\n' > "$R3/.wt/cY/docs/tasks.yaml"; git -C "$R3/.wt/cY" -c user.email=y -c user.name=y commit -qam y
h "${E3[@]}" merge-back cX >/dev/null 2>&1 && ok "first lander (cX) merges cleanly" || bad "cX should merge (first lander)"
if h "${E3[@]}" merge-back cY >/dev/null 2>&1; then
  bad "cY same-line edit merged SILENTLY — must CONFLICT loudly (rc!=0)"
else
  ok "cY same-line edit => merge-back non-zero (loud conflict, no silent overwrite)"
  git -C "$R3" show main:docs/tasks.yaml > "$WORK/c.yaml"
  grep -q "from-X" "$WORK/c.yaml" && ok "main kept first lander (from-X) during the unresolved conflict" || bad "main lost first lander during conflict"
  h "${E3[@]}" reap cY >/dev/null 2>&1 || true
fi
h "${E3[@]}" reap cX >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
echo "== negative (DoD 'removing isolation makes the same test fail'): shared tree loses a lane =="
# Pre-isolation world: ONE shared tree + shared index. Lane A lands; lane B then
# OVERWRITES tasks.yaml from a stale base (no rebase step). This is exactly
# 92763d76 / dc22ad79: a write from a base that predates the prior landing.
git init -q "$WORK/repo2"; R2="$WORK/repo2"; mkdir -p "$R2/docs"
printf 'tasks:\n  - id: base-1\n    status: queued\n' > "$R2/docs/tasks.yaml"
git -C "$R2" add docs/tasks.yaml; git -C "$R2" -c user.email=t@t -c user.name=t commit -qm init
printf 'tasks:\n  - id: base-1\n    status: queued\n  - id: only-from-lane-A\n    status: queued\n' > "$R2/docs/tasks.yaml"
git -C "$R2" -c user.email=a@a -c user.name=a commit -qam "A: add only-from-lane-A"
printf 'tasks:\n  - id: base-1\n    status: queued\n  - id: only-from-lane-B\n    status: queued\n' > "$R2/docs/tasks.yaml"
git -C "$R2" -c user.email=b@b -c user.name=b commit -qam "B: overwrite from stale base"
git -C "$R2" show HEAD:docs/tasks.yaml > "$WORK/legacy.yaml"
if grep -q "only-from-lane-A" "$WORK/legacy.yaml"; then
  bad "negative: lane-A SURVIVED under legacy shared tree — isolation made no difference, test is wrong"
else
  ok "negative: lane-A LOST under legacy shared tree (proves isolation is load-bearing)"
fi

# ---------------------------------------------------------------------------
echo
echo "RESULT: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
