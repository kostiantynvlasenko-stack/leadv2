#!/usr/bin/env bash
# leadv2-lane-worktree.sh — one git worktree per leadv2 lane, on its own branch.
#
# WHY THIS EXISTS (LANE-WORKTREE-ISOLATION-01, 2026-07-27): every leadv2 lane
# used to run in the ONE shared main checkout with ONE shared git index. That
# single fact clobbered docs/tasks.yaml twice in one day (92763d76 reverted 89
# statuses / deleted 32 rows from a base that never saw the 03:04 reconcile;
# dc22ad79 reverted 47af84254005 done->queued while filing an unrelated task),
# swept one lane's staged code into an unrelated docs commit (b74d70d6,
# SD-SHARED-INDEX-SWEPT-A-COMMIT-01 — explicit `git add <paths>` is not enough,
# only `git commit <paths>` is), and killed a lane that read another lane's
# half-written file (SD-LANES-HAVE-NO-WORKTREE-01).
#
# SD-LANES-HAVE-NO-WORKTREE-01 found the precise gap: Phase 0 of `/leadv2` is
# specified to call the EnterWorktree tool, but headless fanout children never
# reliably do — `git worktree list` showed only the main tree while N lanes
# edited it concurrently. leadv2-fanout.sh's own header claimed isolation "is
# handled by Phase 0 of the spawned session itself"; that assumption is false
# for headless/tmux/windowed children. This script is the deterministic,
# bash-level fix: leadv2-fanout.sh calls `ensure` BEFORE launching a lane and
# runs the child with cwd = the returned worktree, so isolation no longer
# depends on the spawned session's own tool-call judgment.
#
# Reuse, not reinvention: this script only CREATES the lane worktree. It uses
# the SAME path/branch convention EnterWorktree itself uses
# (.claude/worktrees/<name>, branch worktree-<name>), so the machinery that
# already exists downstream applies unchanged:
#   - Landing: Phase 6 `ExitWorktree(action="keep")` + leadv2-deploy-merge.sh,
#     which already does a divergence preflight + rebase + FF-ONLY merge (a
#     real conflict on overlapping docs/tasks.yaml edits is a loud non-zero
#     exit + merge-blocker.flag, never a silent pick-one-side) + `git push`.
#     leadv2-deploy-merge.sh already resolves the task branch as
#     `task/$TASK_ID` or `worktree-$TASK_ID` — this script only ever creates
#     the latter, so no changes were needed there.
#   - Reaping: Phase 8 `leadv2-worktree-cleanup.sh --name "$TASK_ID"` (already
#     called from commands/leadv2.md's Phase 8 step, success path only).
#
# Ops:
#   ensure <task_id> [class]   create the lane worktree+branch if absent
#                              (idempotent), print the ABS worktree path to
#                              stdout. On ANY failure: log loud to stderr and
#                              print PROJECT_ROOT (legacy shared tree) so
#                              dispatch NEVER hard-breaks — isolation degrades
#                              to the old behavior, it does not stop the lane.
#   path-of <task_id>          print the lane's ABS worktree path, or "" if no
#                              worktree exists for that task.
#
# Env:
#   LEADV2_PROJECT_ROOT   repo whose main checkout lanes fork from (required;
#                         falls back to the git toplevel of cwd).
#   LEADV2_WORKTREE_DIR   parent dir for lane worktrees
#                         (default $ROOT/.claude/worktrees — same dir
#                         EnterWorktree and leadv2-worktree-cleanup.sh use).
#   LEADV2_LANE_WORKTREE  on|off (default on). off => ensure prints PROJECT_ROOT
#                         and creates nothing (legacy escape hatch / kill-switch).
#   LEADV2_LANE_BASE      ref to fork the lane from (default: origin/main if it
#                         exists, else main, else HEAD).
#   LEADV2_LANE_WORKTREE_ERRF  stderr capture file (default /tmp/pe-lane-worktree.err).
#
# Branch naming: refs/heads/worktree-<task_id>  (matches EnterWorktree +
#                                                 leadv2-deploy-merge.sh)
# Worktree path:  $LEADV2_WORKTREE_DIR/<task_id>  (== .claude/worktrees/<task_id>)
#
# Exit codes: 0 always (ensure/path-of never block a lane; ensure falls back to
# the shared tree on any git failure instead of failing the dispatch).
set -u

# --- helpers -----------------------------------------------------------------
log()       { printf '[lane-worktree] %s\n' "$*" >&2; }
log_error() { printf '[lane-worktree] ERROR: %s\n' "$*" >&2; }

ERRF="${LEADV2_LANE_WORKTREE_ERRF:-/tmp/pe-lane-worktree.err}"
ROOT=""

resolve_root() {
  [[ -n "$ROOT" ]] && return
  ROOT="${LEADV2_PROJECT_ROOT:-$(git -C "${PWD:-.}" rev-parse --show-toplevel 2>/dev/null || true)}"
  if [[ -z "$ROOT" ]] || ! git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    log_error "could not resolve a git repo root (set LEADV2_PROJECT_ROOT or run inside a repo)"
    ROOT=""
  fi
}

# Latest main-ish ref to fork from: origin/main (saw sibling landings) > main
# > HEAD. Echoes the choice.
pick_base() {
  if git -C "$ROOT" rev-parse --verify -q origin/main >/dev/null 2>&1; then printf 'origin/main'
  elif git -C "$ROOT" rev-parse --verify -q main >/dev/null 2>&1; then printf 'main'
  else printf 'HEAD'; fi
}

# Print the shared tree (legacy cwd) — the safe fallback when isolation cannot
# be created. Dispatch continues; isolation is simply off for this lane.
fallback() {
  resolve_root
  printf '%s\n' "$ROOT"
}

lane_branch() { printf 'worktree-%s' "$1"; }
lane_dir()    { printf '%s/.claude/worktrees' "$ROOT"; }

# Resolve a path to its PHYSICAL form. macOS symlinks /tmp -> /private/tmp and
# /var -> /private/var; git's `worktree list --porcelain` reports the physical
# path, so any equality check against the as-given path mis-matches on macOS
# (production runs on a mac). Falls back to the as-given path if unresolvable.
phys() { ( cd "$1" 2>/dev/null && pwd -P ) 2>/dev/null || printf '%s' "$1"; }

# --- ops ---------------------------------------------------------------------
# ensure <task_id> [class]
cmd_ensure() {
  local task_id="${1:-}"
  # class is accepted for forward-compat (e.g. future per-class worktree dirs);
  # it does not change behavior today.
  local _class="${2:-standard}"
  resolve_root
  if [[ -z "$task_id" ]]; then
    log_error "ensure: <task_id> required"
    fallback; return 0
  fi
  if [[ -z "$ROOT" ]]; then fallback; return 0; fi

  # Kill-switch / explicit opt-out: legacy shared tree.
  if [[ "${LEADV2_LANE_WORKTREE:-on}" == "off" ]]; then
    fallback; return 0
  fi

  local wt_dir="${LEADV2_WORKTREE_DIR:-$(lane_dir)}"
  local lane_path="$wt_dir/$task_id"
  local branch; branch="$(lane_branch "$task_id")"

  # Idempotent: an existing linked worktree is reused as-is. Compare on the
  # PHYSICAL path — git reports /private/var on macOS, not the /var we passed.
  if [[ -d "$lane_path" ]] && git -C "$ROOT" worktree list --porcelain 2>/dev/null | grep -q "^worktree $(phys "$lane_path")\$"; then
    printf '%s\n' "$lane_path"
    return 0
  fi

  local base; base="${LEADV2_LANE_BASE:-$(pick_base)}"
  mkdir -p "$wt_dir"

  # Fresh branch from base + linked worktree.
  if git -C "$ROOT" worktree add -b "$branch" "$lane_path" "$base" >>"$ERRF" 2>&1; then
    printf '%s\n' "$lane_path"
    return 0
  fi
  # Branch may already exist from a prior aborted run — attach the worktree to it.
  if git -C "$ROOT" worktree add "$lane_path" "$branch" >>"$ERRF" 2>&1; then
    printf '%s\n' "$lane_path"
    return 0
  fi
  log_error "ensure: git worktree add failed for task=$task_id base=$base (see $ERRF) — FALLING BACK to shared tree"
  fallback
  return 0
}

# path-of <task_id>  -> ABS path or "" (no output)
cmd_path_of() {
  local task_id="${1:-}"
  resolve_root
  [[ -z "$ROOT" || -z "$task_id" ]] && return 0
  local wt_dir="${LEADV2_WORKTREE_DIR:-$(lane_dir)}"
  local lane_path="$wt_dir/$task_id"
  if [[ -d "$lane_path" ]] && git -C "$ROOT" worktree list --porcelain 2>/dev/null | grep -q "^worktree $(phys "$lane_path")\$"; then
    printf '%s\n' "$lane_path"
  fi
}

# --- dispatch ----------------------------------------------------------------
usage() {
  cat >&2 <<'EOF'
usage: leadv2-lane-worktree.sh <op> <task_id> [class]
  op        ensure | path-of
  task_id   the lane's task id (branch worktree-<task_id>, worktree <task_id>)
  class     optional, forward-compat (ensure only)
env: LEADV2_PROJECT_ROOT, LEADV2_WORKTREE_DIR, LEADV2_LANE_WORKTREE=on|off,
     LEADV2_LANE_BASE, LEADV2_LANE_WORKTREE_ERRF

Landing and reaping a lane are NOT this script's job — reuse the existing
machinery: Phase 6 ExitWorktree(keep) + leadv2-deploy-merge.sh (ff-only merge,
conflicts loudly) lands it; Phase 8 `leadv2-worktree-cleanup.sh --name <id>`
reaps it.
EOF
}

case "${1:-}" in
  ensure)   shift; cmd_ensure "$@" ;;
  path-of)  shift; cmd_path_of "$@" ;;
  -h|--help) usage; exit 0 ;;
  *)        usage; exit 2 ;;
esac
