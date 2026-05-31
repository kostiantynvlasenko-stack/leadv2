#!/usr/bin/env bash
# PostCompact hook: re-inject active task goal into model context after compaction.
# Stdout is injected verbatim into the model's context window by the Claude runtime.
# On no active task or missing files: exits 0 silently, emits nothing.
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

_active_yaml="${_ROOT}/${_leadv2_dir}/active.yaml"
[[ -f "$_active_yaml" ]] || exit 0

# Source the 5-second active-task cache (canonical pattern from leadv2-active-cache.sh)
_cache_script="${HOME}/.claude/hooks/leadv2-active-cache.sh"
[[ -f "$_cache_script" ]] || exit 0
# shellcheck source=/dev/null
source "$_cache_script"

leadv2_read_active_yaml "$_active_yaml"
_task_id="${ACTIVE_TASK_ID:-}"
_phase="${ACTIVE_PHASE:-}"

[[ -n "$_task_id" ]] || exit 0

_state_file="${_ROOT}/${_leadv2_dir}/tasks/${_task_id}/STATE.md"
[[ -f "$_state_file" ]] || exit 0

# Extract phase: and goal: fields from STATE.md
_state_phase=$(python3 - "$_state_file" <<'PYEOF' 2>/dev/null || true
import sys, re
try:
    for line in open(sys.argv[1]):
        m = re.match(r'^phase:\s*(.+)', line.rstrip())
        if m:
            print(m.group(1).strip()); sys.exit(0)
except Exception:
    pass
PYEOF
)

_goal=$(python3 - "$_state_file" <<'PYEOF' 2>/dev/null || true
import sys, re
try:
    for line in open(sys.argv[1]):
        m = re.match(r'^goal:\s*(.+)', line.rstrip())
        if m:
            print(m.group(1).strip()); sys.exit(0)
except Exception:
    pass
PYEOF
)

# Use active cache phase as fallback when STATE.md phase field absent
[[ -z "$_state_phase" ]] && _state_phase="${_phase}"

# If both phase and goal are empty there is nothing useful to inject
[[ -z "$_state_phase" && -z "$_goal" ]] && exit 0

_flag_path="docs/handoff/${_task_id}/phase8-passed.flag"

printf -- '---\n'
printf -- 'POSTCOMPACT CONTEXT RESTORE — active task: %s\n' "$_task_id"
printf -- 'Current phase : %s\n' "${_state_phase:-unknown}"
if [[ -n "$_goal" ]]; then
  printf -- 'Goal condition: %s\n' "$_goal"
fi
printf -- 'Pipeline rule : Continue the 9-phase pipeline until %s exists; do not stop mid-pipeline.\n' "$_flag_path"
printf -- '---\n'

exit 0
