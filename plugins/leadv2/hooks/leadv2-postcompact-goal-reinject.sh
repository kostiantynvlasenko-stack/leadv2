#!/usr/bin/env bash
# PostCompact hook: re-inject active-task context after compaction — task/phase/goal,
# journal tail, other open tasks, and open threads. Stdout is injected verbatim into the
# model's context window by the Claude runtime. Output is hard-capped at 60 lines.
# On no active task AND no open-threads content: exits 0 silently, emits nothing.
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
_OUT=""

if [[ -f "$_active_yaml" ]]; then
  # Source the 5-second active-task cache (canonical pattern from leadv2-active-cache.sh)
  _cache_script="${HOME}/.claude/hooks/leadv2-active-cache.sh"
  if [[ -f "$_cache_script" ]]; then
    # shellcheck source=/dev/null
    source "$_cache_script"
    leadv2_read_active_yaml "$_active_yaml"
  fi
  _task_id="${ACTIVE_TASK_ID:-}"
  _phase="${ACTIVE_PHASE:-}"

  if [[ -n "$_task_id" ]]; then
    # Extract phase and goal from STATE.md when it exists; fall back to cache phase otherwise.
    # The active-task header + journal tail are emitted independently of STATE.md presence —
    # a missing STATE.md means phase/goal are absent, not that the task is unrecoverable.
    _state_file="${_ROOT}/${_leadv2_dir}/tasks/${_task_id}/STATE.md"
    _state_phase=""
    _goal=""
    if [[ -f "$_state_file" ]]; then
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
    fi
    # Use active cache phase as fallback when STATE.md phase field absent
    [[ -z "$_state_phase" ]] && _state_phase="${_phase}"

    _flag_path="docs/handoff/${_task_id}/phase8-passed.flag"

    _OUT+=$'---\n'
    _OUT+="$(printf -- 'POSTCOMPACT CONTEXT RESTORE — active task: %s\n' "$_task_id")"$'\n'
    _OUT+="$(printf -- 'Current phase : %s\n' "${_state_phase:-unknown}")"$'\n'
    if [[ -n "$_goal" ]]; then
      _OUT+="$(printf -- 'Goal condition: %s\n' "$_goal")"$'\n'
    fi
    _OUT+="$(printf -- 'Pipeline rule : Continue the 9-phase pipeline until %s exists; do not stop mid-pipeline.\n' "$_flag_path")"$'\n'
    _OUT+=$'---\n'

    # Journal tail (last 10) — skip block if journal.md missing/empty
    _journal_file="${_ROOT}/${_leadv2_dir}/tasks/${_task_id}/journal.md"
    if [[ -f "$_journal_file" ]]; then
      _jtail="$(tail -n 10 "$_journal_file" 2>/dev/null || true)"
      if [[ -n "$_jtail" ]]; then
        _OUT+=$'Journal tail (last 10):\n'
        _OUT+="${_jtail}"$'\n'
      fi
    fi

    # Other open tasks (from active.yaml sessions, excluding the active one), max 5
    _other="$(python3 -c "
import yaml, sys
try:
    d = yaml.safe_load(open(sys.argv[1])) or {}
    sessions = d.get('sessions') or []
    seen = {}
    for s in sessions:
        tid = (s.get('task_id') or '').strip()
        if not tid or tid == sys.argv[2] or tid in seen:
            continue
        seen[tid] = s.get('phase', '?')
    for tid, phase in list(seen.items())[:5]:
        print(f'- {tid} (phase: {phase})')
except Exception:
    pass
" "$_active_yaml" "$_task_id" 2>/dev/null || true)"
    if [[ -n "$_other" ]]; then
      _OUT+=$'Other open tasks:\n'
      _OUT+="${_other}"$'\n'
    fi
  fi
fi

# Open threads block — independent of active-task state (also covers no-active-task case)
_threads_file="${_ROOT}/${_leadv2_dir}/open-threads.md"
if [[ -f "$_threads_file" && -s "$_threads_file" ]]; then
  _threads_head="$(head -n 20 "$_threads_file" 2>/dev/null || true)"
  if [[ -n "$_threads_head" ]]; then
    _OUT+=$'Open threads:\n'
    _OUT+="${_threads_head}"$'\n'
  fi
fi

[[ -z "$_OUT" ]] && exit 0

printf '%s' "$_OUT" | head -60
exit 0
