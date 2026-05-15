#!/usr/bin/env bash
set -euo pipefail
# leadv2-worktree-cleanup.sh — safely remove a /leadv2 worktree and its branch.
# Usage: leadv2-worktree-cleanup.sh --name <worktree-name> [--force]

readonly SCRIPT_NAME="leadv2-worktree-cleanup.sh"

log()       { printf -- '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }
log_error() { log "ERROR: $*"; }
log_info()  { log "INFO: $*"; }

usage() {
  cat >&2 <<EOF
Usage: $SCRIPT_NAME --name <worktree-name> [--force]

  --name <name>   Name of the worktree under .claude/worktrees/<name>
  --force         Remove even if worktree has uncommitted or untracked changes
EOF
  exit 1
}

NAME=""; FORCE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)  NAME="$2"; shift 2 ;;
    --force) FORCE=1;   shift ;;
    *) log_error "Unknown argument: $1"; usage ;;
  esac
done

[[ -z "$NAME" ]] && { log_error "--name is required"; usage; }

# Resolve repo root — must run from inside the repo (main or worktree).
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || {
  log_error "Not inside a git repository"
  exit 1
}

WORKTREE_PATH="${REPO_ROOT}/.claude/worktrees/${NAME}"

# Security: ensure the resolved path stays under .claude/worktrees/ (no path escape).
WORKTREES_DIR="${REPO_ROOT}/.claude/worktrees"
# realpath --relative-base is not portable; use string prefix check on canonical paths.
CANONICAL_WT=$(realpath "$WORKTREE_PATH" 2>/dev/null || printf -- '%s' "$WORKTREE_PATH")
CANONICAL_BASE=$(realpath "$WORKTREES_DIR" 2>/dev/null || printf -- '%s' "$WORKTREES_DIR")

if [[ "$CANONICAL_WT" != "${CANONICAL_BASE}/"* ]]; then
  log_error "Path escape detected: '$WORKTREE_PATH' is not under '$WORKTREES_DIR'"
  exit 1
fi

# Guard: if the calling process's CWD is inside the worktree we're about to
# delete, removing it would leave the shell in a non-existent directory and
# cause ENOENT crashes in hooks. Print instructions and exit non-zero so the
# caller (phase8-close.sh) sees a clean "skip" rather than a crash.
CURRENT_DIR=$(pwd -P 2>/dev/null || pwd)
CANONICAL_WT_REAL=$(realpath "$WORKTREE_PATH" 2>/dev/null || printf -- '%s' "$WORKTREE_PATH")
if [[ "$CURRENT_DIR" == "${CANONICAL_WT_REAL}"* ]]; then
  printf -- '\n'
  printf -- 'SKIP: CWD is inside worktree — cannot delete while session is open.\n'
  printf -- 'Close this Claude session, then remove manually:\n'
  printf -- '  git worktree remove --force .claude/worktrees/%s\n' "$NAME"
  printf -- '  git branch -D worktree-%s\n' "$NAME"
  printf -- '\n'
  exit 2
fi

# Confirm worktree is registered with git.
if ! git -C "$REPO_ROOT" worktree list --porcelain | grep -qF "worktree $WORKTREE_PATH"; then
  log_error "Worktree not found in git worktree list: $WORKTREE_PATH"
  exit 1
fi

BRANCH_NAME="worktree-${NAME}"

# Check for uncommitted/untracked changes unless --force.
if [[ "$FORCE" -eq 0 ]]; then
  # git status inside the worktree — use -C to target it from the main repo.
  DIRTY=$(git -C "$WORKTREE_PATH" status --porcelain 2>/dev/null || true)
  if [[ -n "$DIRTY" ]]; then
    log_error "Worktree has uncommitted or untracked changes:"
    printf -- '%s\n' "$DIRTY" >&2
    log_error "Use --force to remove anyway, or commit/stash changes first."
    exit 1
  fi
fi

log_info "Removing worktree: $WORKTREE_PATH"
git -C "$REPO_ROOT" worktree remove --force "$WORKTREE_PATH"

log_info "Deleting branch: $BRANCH_NAME"
git -C "$REPO_ROOT" branch -D "$BRANCH_NAME" 2>/dev/null || true

printf -- '\n'
printf -- 'Worktree removed: .claude/worktrees/%s\n' "$NAME"
printf -- 'Branch deleted:   worktree-%s\n' "$NAME"
printf -- '\n'
printf -- 'NOTE: If you ran this from inside the worktree, restart Claude session\n'
printf -- "with \`claude\` from %s to release session state.\n" "$REPO_ROOT"
