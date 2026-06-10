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
" | head -5 || true)

if [[ -n "$hot_paths_modified" ]]; then
  risky+=("hot_paths=$(echo "$hot_paths_modified" | wc -l | tr -d ' ')")
fi

# ── --compare-tasks mode (C1.2/D4) ───────────────────────────────────────
# Compare files_hint footprints of two tasks for glob overlap.
# Exit 2 = collision. Exit 0 = no overlap (or files_hint absent -> pass-through).
if [[ "${1:-}" == "--compare-tasks" ]]; then
  task_a="${2:?--compare-tasks requires <taskA>}"
  task_b="${3:?--compare-tasks requires <taskB>}"
  python3 - "$task_a" "$task_b" "${LEADV2_PROJECT_ROOT}/docs/tasks.yaml" <<'COMPARE_PY'
import sys, fnmatch, os

task_a   = sys.argv[1]
task_b   = sys.argv[2]
tasks_yaml = sys.argv[3]

try:
    import yaml
except ImportError:
    print("[collision] PyYAML not available; skipping compare", file=sys.stderr)
    sys.exit(0)

try:
    with open(tasks_yaml) as f:
        items = yaml.safe_load(f) or []
except FileNotFoundError:
    print(f"[collision] tasks.yaml not found at {tasks_yaml}", file=sys.stderr)
    sys.exit(0)

by_id = {str(it.get("id","")): it for it in items}

ta = by_id.get(task_a)
tb = by_id.get(task_b)

if ta is None or tb is None:
    print(f"[collision] task not found: {task_a if ta is None else task_b}", file=sys.stderr)
    sys.exit(0)

hints_a = (ta.get("context") or {}).get("files_hint") or []
hints_b = (tb.get("context") or {}).get("files_hint") or []

if not hints_a or not hints_b:
    # D14: emit WARN when files_hint absent; caller falls back to conservative single-claim
    print(f"WARN: files_hint absent for task {'A' if not hints_a else 'B'} ({task_a if not hints_a else task_b})", file=sys.stderr)
    sys.exit(0)

# Glob intersection: check if any pattern from A matches any pattern from B or vice versa.
# Simple overlap: check common stems (strip wildcards, compare path prefixes).
def stem(pattern):
    """Extract deterministic path prefix before first wildcard."""
    p = pattern.replace("**", "*")
    idx = next((i for i, c in enumerate(p) if c in "*?["), len(p))
    return p[:idx].rstrip("/")

stems_a = {stem(p) for p in hints_a if stem(p)}
stems_b = {stem(p) for p in hints_b if stem(p)}

# Check both directions: does any stem from A appear in B's patterns (or vice versa)?
overlapping = []
for pa in hints_a:
    for sb in stems_b:
        if sb and (pa.startswith(sb) or fnmatch.fnmatch(sb, pa)):
            overlapping.append(f"{pa} ~ {sb}")
for pb in hints_b:
    for sa in stems_a:
        if sa and (pb.startswith(sa) or fnmatch.fnmatch(sa, pb)):
            key = f"{sa} ~ {pb}"
            if key not in overlapping:
                overlapping.append(key)

if overlapping:
    print(f"COLLISION: files_hint overlap between {task_a} and {task_b}: {', '.join(overlapping[:3])}")
    sys.exit(2)

sys.exit(0)
COMPARE_PY
  exit $?
fi

# ── Default mode (existing session-collision check) ──────────────────────
if [[ ${#risky[@]} -eq 0 ]]; then
  exit 0
fi

echo "COLLISION_RISK ${risky[*]}"
[[ -n "$hot_paths_modified" ]] && echo "modified_hot_paths:" && echo "$hot_paths_modified" | sed 's/^/  /'
exit 2
