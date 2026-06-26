#!/usr/bin/env bash
set -euo pipefail
trap 'exit 0' ERR
DEFAULT="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')"; [[ -z "$DEFAULT" ]] && DEFAULT=main
git fetch origin "$DEFAULT" --quiet || { echo "[main-sync] fetch failed — skip" >&2; exit 0; }
CUR="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '')"
if [[ "$CUR" == "$DEFAULT" ]]; then
  if git merge --ff-only "origin/$DEFAULT" >/dev/null 2>&1; then echo "[main-sync] $DEFAULT fast-forwarded to origin"; else echo "[main-sync] WARN: $DEFAULT diverged from origin/$DEFAULT — not resetting" >&2; fi
elif git merge-base --is-ancestor "$DEFAULT" "origin/$DEFAULT" 2>/dev/null; then
  git update-ref "refs/heads/$DEFAULT" "origin/$DEFAULT" && echo "[main-sync] $DEFAULT ref FF'd to origin (not checked out)"
else echo "[main-sync] WARN: local $DEFAULT diverged — not resetting" >&2; fi
exit 0
