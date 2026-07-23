#!/usr/bin/env bash
# PostCompact hook: was a full independent re-computation of active-task context
# (task/phase/goal, journal tail, other open tasks, open threads) — this duplicated
# post-compact-reground.sh (SessionStart matcher=compact), which re-prints the SAME
# frozen content from <leadv2_dir>/.compact-freeze.md (written pre-compact by
# pre-compact-task-freeze.sh) as the canonical post-compact reinject.
#
# COMPACT-DEDUP-01 (2026-07-23): silenced the duplicate stdout emission here — the
# canonical reinject is post-compact-reground.sh. This hook now emits at most a
# 2-line pointer so the audit trail is preserved without re-paying the token cost.
# No file writes existed in the old body (pure stdout re-injection), so nothing is
# lost by no-op'ing the emission.
set -euo pipefail
trap 'exit 0' ERR

# Resolve project root — prefer CLAUDE_PROJECT_DIR, fall back to cwd
_ROOT="${CLAUDE_PROJECT_DIR:-$(pwd)}"

# Resolve leadv2_dir from state-paths.yaml (mirrors leadv2-pulse-enforcer.sh pattern)
_sp_yaml="${_ROOT}/.claude/leadv2-overrides/state-paths.yaml"
_leadv2_dir=$(python3 -c "
import sys, re
try:
    for line in open(sys.argv[1]):
        m = re.match(r\"^\s*leadv2_dir\s*:\s*['\\\"]*([\w/._-]+)['\\\"]*(\\s.*)?$\", line)
        if m:
            print(m.group(1)); sys.exit(0)
except Exception:
    pass
print('docs/leadv2')
" "$_sp_yaml" 2>/dev/null || printf 'docs/leadv2')

_freeze_file="${_ROOT}/${_leadv2_dir}/.compact-freeze.md"
if [[ -f "$_freeze_file" ]]; then
  printf -- 'POSTCOMPACT: full context already reinjected by post-compact-reground.sh from %s\n' "$_freeze_file"
fi
exit 0
