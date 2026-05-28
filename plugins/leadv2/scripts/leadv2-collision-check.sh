#!/bin/bash
# leadv2-collision-check.sh — Phase 0 parallel-session collision detector.
# Surfaces overlap warnings BEFORE EnterWorktree so lead can pre-plan rebase vs ff-merge.
#
# Usage: leadv2-collision-check.sh
# Exit 0 = no collision risk. Exit 2 = collision risk, stdout describes.

set -euo pipefail

# Source helpers for _lv2_stack_list (grep/awk only, no python3)
_COLLISION_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LEADV2_PROJECT_ROOT="${LEADV2_PROJECT_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
export LEADV2_PROJECT_ROOT
# shellcheck disable=SC1091
source "${_COLLISION_SCRIPT_DIR}/leadv2-helpers.sh" 2>/dev/null || true

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

# 3. Modified files in shared paths (hot_paths from stack.yaml; fallback: PE defaults)
_LV2_HOT_PATHS=""
if command -v _lv2_stack_list &>/dev/null; then
  _LV2_HOT_PATHS="$(_lv2_stack_list 'hot_paths' 'agent/state/ personas/ agent/safety/')"
else
  _LV2_HOT_PATHS="agent/state/ personas/ agent/safety/"
fi

# Build awk condition dynamically from space-separated hot_paths list
_LV2_AWK_COND=""
for _hp in $_LV2_HOT_PATHS; do
  if [[ -n "$_LV2_AWK_COND" ]]; then
    _LV2_AWK_COND="${_LV2_AWK_COND} || \$2 ~ /^${_hp//\//\\/}/"
  else
    _LV2_AWK_COND="\$2 ~ /^${_hp//\//\\/}/"
  fi
done

hot_paths_modified=$(git status --porcelain 2>/dev/null | awk "
  ${_LV2_AWK_COND} { print \$2 }
" | head -5)

if [[ -n "$hot_paths_modified" ]]; then
  risky+=("hot_paths=$(echo "$hot_paths_modified" | wc -l | tr -d ' ')")
fi

if [[ ${#risky[@]} -eq 0 ]]; then
  exit 0
fi

echo "COLLISION_RISK ${risky[*]}"
[[ -n "$hot_paths_modified" ]] && echo "modified_hot_paths:" && echo "$hot_paths_modified" | sed 's/^/  /'
exit 2
