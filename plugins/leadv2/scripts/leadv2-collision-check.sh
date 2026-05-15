#!/bin/bash
# leadv2-collision-check.sh — Phase 0 parallel-session collision detector.
# Surfaces overlap warnings BEFORE EnterWorktree so lead can pre-plan rebase vs ff-merge.
#
# Usage: leadv2-collision-check.sh
# Exit 0 = no collision risk. Exit 2 = collision risk, stdout describes.

set -euo pipefail

active_yaml="docs/leadv2/active.yaml"
risky=()

# 1. Other active sessions claimed?
if [[ -f "$active_yaml" ]]; then
  other_count=$(python3 -c "
import yaml, sys
d = yaml.safe_load(open('$active_yaml')) or {}
sessions = d.get('sessions', []) or []
me = '${LEADV2_TASK_ID:-}'
print(sum(1 for s in sessions if s.get('task_id') and s.get('task_id') != me and s.get('status') != 'closed'))
" 2>/dev/null || echo 0)
  if [[ "$other_count" -gt 0 ]]; then
    risky+=("active_sessions=$other_count")
  fi
fi

# 2. git stash with content?
stash_count=$(git stash list 2>/dev/null | wc -l | tr -d ' ')
[[ "$stash_count" -gt 0 ]] && risky+=("stash_entries=$stash_count")

# 3. Modified files in shared paths
hot_paths_modified=$(git status --porcelain 2>/dev/null | awk '
  $2 ~ /^agent\/state\// || $2 ~ /^personas\// || $2 ~ /^agent\/safety\// || $2 ~ /^docs\/agents\/product-owner\// {
    print $2
  }
' | head -5)

if [[ -n "$hot_paths_modified" ]]; then
  risky+=("hot_paths=$(echo "$hot_paths_modified" | wc -l | tr -d ' ')")
fi

if [[ ${#risky[@]} -eq 0 ]]; then
  exit 0
fi

echo "COLLISION_RISK ${risky[*]}"
[[ -n "$hot_paths_modified" ]] && echo "modified_hot_paths:" && echo "$hot_paths_modified" | sed 's/^/  /'
exit 2
