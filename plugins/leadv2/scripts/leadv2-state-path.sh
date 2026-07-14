#!/usr/bin/env bash
# scripts/leadv2-state-path.sh — LEAD-CONTROL-PLANE-01 canonical path resolver.
#
# THE BUG this fixes: every /leadv2 coordination file (active.yaml, bus.jsonl,
# merge-queue.jsonl, .merge.lock, open-threads.md) used to live at a
# REPO-RELATIVE path (docs/leadv2/...). But every /leadv2 session runs in its
# OWN `git worktree add` checkout — so each of N parallel sessions got its own
# PRIVATE copy of every "shared" coordination file. The merge lock locked
# nothing. The bus connected no one. All N sessions still raced the same
# `main`.
#
# THE FIX: resolve one canonical root OUTSIDE any worktree, via
# `git rev-parse --path-format=absolute --git-common-dir` — this path is
# IDENTICAL from every worktree of the same repo (unlike `--git-dir`, which
# is worktree-private: <repo>/.git for the main tree,
# <repo>/.git/worktrees/<name> for a linked one). Root:
#   ~/.claude/leadv2-state/<repo-slug>/
# where <repo-slug> = basename of the MAIN repo's toplevel dir (derived from
# git-common-dir, never from the calling worktree's own path).
#
# ALL scripts/hooks that touch active.yaml / bus.jsonl / merge-queue.jsonl /
# .merge.lock / open-threads.md MUST resolve the path through this script —
# no hardcoded `docs/leadv2/...` string for these five files anywhere else.
#
# Usage:
#   leadv2-state-path.sh                  # -> control-plane root, ensures it
#                                            exists + repairs the standard
#                                            docs/leadv2/<name> symlink set
#                                            for the CURRENT worktree
#   leadv2-state-path.sh root             # same as above
#   leadv2-state-path.sh <name>           # -> <root>/<name> (nested names,
#                                            e.g. .bus-offsets/<session>,
#                                            questions/<id>.yaml, are NOT
#                                            symlinked individually — only
#                                            their parent dir is)
#   leadv2-state-path.sh --no-link <name> # resolve only, skip the symlink /
#                                            migration side effect (used by
#                                            the test harness to probe raw
#                                            paths without mutating a worktree)
#
# Migration semantics (idempotent, safe to call from every worktree, every
# invocation): for each name in the standard set, if the control-plane copy
# does not exist yet AND a REAL file/dir (not a symlink) is sitting at
# docs/leadv2/<name> in THIS worktree, its content is MOVED into the control
# plane (never dropped) and replaced with a symlink. If the control-plane
# copy already exists (another worktree migrated first) and this worktree
# also has independent real content, the local copy is preserved as
# `<name>.pre-controlplane-backup` before the symlink is created — nothing is
# ever silently overwritten.
#
# Env overrides (test sandboxing):
#   LEADV2_STATE_ROOT   — full absolute override of the control-plane root
#                         (skips git/slug resolution entirely)
#   LEADV2_STATE_BASE   — override the base dir (default ~/.claude/leadv2-state)
#   PROJECT_ROOT        — repo root override (for the symlink step only;
#                         defaults to `git rev-parse --show-toplevel` of cwd)

set -euo pipefail

NO_LINK=0
if [[ "${1:-}" == "--no-link" ]]; then
  NO_LINK=1
  shift
fi
NAME="${1:-root}"

# LINK_ROOT is the worktree this invocation cares about — an explicit
# PROJECT_ROOT override (test sandboxes, callers that already know their
# root) always wins; otherwise fall back to this invocation's own cwd
# toplevel. git-common-dir MUST be resolved AGAINST LINK_ROOT, never against
# the ambient `git rev-parse` cwd — resolving from cwd silently pointed every
# caller (including test sandboxes with no .git at all) at whichever repo
# happened to be the current shell's cwd, which is wrong for any caller that
# passes an explicit PROJECT_ROOT belonging to a different tree.
LINK_ROOT="${PROJECT_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"

# ── Resolve control-plane root ──────────────────────────────────────────────
if [[ -n "${LEADV2_STATE_ROOT:-}" ]]; then
  STATE_ROOT="$LEADV2_STATE_ROOT"
else
  COMMON_DIR="$(git -C "$LINK_ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  if [[ -z "$COMMON_DIR" ]]; then
    # LINK_ROOT is not inside a git repo at all (e.g. a test sandbox that
    # never ran `git init`) — degrade to the pre-fix repo-relative layout
    # for THIS root only. This never silently borrows the real control
    # plane of an unrelated repo just because it happens to be the caller's
    # ambient cwd.
    STATE_ROOT="${LINK_ROOT}/docs/leadv2"
    mkdir -p "$STATE_ROOT"
    if [[ "$NAME" == "root" || -z "$NAME" ]]; then
      printf -- '%s\n' "$STATE_ROOT"
      exit 0
    fi
    TARGET="${STATE_ROOT}/${NAME}"
    mkdir -p "$(dirname "$TARGET")"
    printf -- '%s\n' "$TARGET"
    exit 0
  fi
  MAIN_REPO_ROOT="$(cd "$(dirname "$COMMON_DIR")" && pwd)"
  REPO_SLUG="$(basename "$MAIN_REPO_ROOT")"
  STATE_BASE="${LEADV2_STATE_BASE:-${HOME}/.claude/leadv2-state}"
  STATE_ROOT="${STATE_BASE}/${REPO_SLUG}"
fi

mkdir -p "$STATE_ROOT"

# ── Migration + symlink repair (idempotent, best-effort, never fatal) ──────
if [[ "$NO_LINK" -eq 0 ]]; then
  python3 - "$STATE_ROOT" "$LINK_ROOT" <<'PYEOF' 2>/dev/null || true
import os, shutil, sys

state_root, link_root = sys.argv[1], sys.argv[2]
leadv2_dir = os.path.join(link_root, "docs", "leadv2")
os.makedirs(leadv2_dir, exist_ok=True)

# name -> is_dir
STANDARD = {
    "active.yaml": False,
    "active.yaml.lock": False,
    "bus.jsonl": False,
    ".bus.lock": False,
    ".bus-offsets": True,
    "merge-queue.jsonl": False,
    ".merge.lock": False,
    "open-threads.md": False,
    "questions": True,
}

for name, is_dir in STANDARD.items():
    target = os.path.join(state_root, name)
    local = os.path.join(leadv2_dir, name)

    if os.path.islink(local):
        try:
            cur = os.readlink(local)
        except OSError:
            cur = None
        if cur != target:
            try:
                os.unlink(local)
                os.symlink(target, local)
            except OSError:
                pass
        continue

    if os.path.exists(local):
        # Real (non-symlink) content sitting at the old repo-relative path.
        if not os.path.exists(target):
            # First migration: move content into the control plane verbatim.
            try:
                shutil.move(local, target)
            except OSError:
                continue
        else:
            # Control plane already has content (another worktree migrated
            # first) — never clobber; preserve this worktree's local copy.
            backup = local + ".pre-controlplane-backup"
            if not os.path.exists(backup):
                try:
                    shutil.move(local, backup)
                except OSError:
                    continue
            else:
                continue

    if not os.path.exists(local):
        if is_dir:
            os.makedirs(target, exist_ok=True)
        try:
            os.symlink(target, local)
        except FileExistsError:
            pass
        except OSError:
            pass
PYEOF
fi

if [[ "$NAME" == "root" || -z "$NAME" ]]; then
  printf -- '%s\n' "$STATE_ROOT"
  exit 0
fi

TARGET="${STATE_ROOT}/${NAME}"
mkdir -p "$(dirname "$TARGET")"
printf -- '%s\n' "$TARGET"
