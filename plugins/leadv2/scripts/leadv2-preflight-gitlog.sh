#!/bin/bash
# leadv2-preflight-gitlog.sh — Phase 0 pre-flight: detect already-shipped task before EnterWorktree.
# Saves entire setup cycle when founder picks a task whose code already landed.
#
# Usage: leadv2-preflight-gitlog.sh <task_id>
# Exit 0 = clean (no commits found, proceed). Exit 2 = commits found, surface to founder.
# stdout on exit 2 = up to 3 oneline commits + count.

set -euo pipefail

task_id="${1:?usage: $0 <task_id>}"

# Search subject lines only (not body) — commit bodies often reference follow-up task IDs
# that were never shipped, causing false positives. Use word boundaries to prevent
# PO-027 from matching PO-027b close-commit subjects.
git rev-parse --git-dir >/dev/null 2>&1 || { echo "[preflight] not a git repo" >&2; exit 1; }

matches=$(git log --all --format="%h %s" 2>/dev/null | grep -iE "\b${task_id}\b" | head -3 || true)

if [[ -z "$matches" ]]; then
  exit 0
fi
count=$(printf '%s\n' "$matches" | wc -l | tr -d ' ')

cat <<EOF
PREFLIGHT_GITLOG_HIT task=$task_id count=$count
$matches
EOF
exit 2
