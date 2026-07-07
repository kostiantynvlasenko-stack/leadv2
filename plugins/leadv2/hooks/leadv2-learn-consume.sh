#!/usr/bin/env bash
# SessionStart hook: consume .learn-trigger → instruct lead to run leadv2-learn workflow.
# [R3-2 SILENTDEATH-01] Flywheel fix: phase8-close writes .learn-trigger every N closes;
# nothing was reading it at session start → self-learning loop permanently dead.
#
# Contract:
#   - Stdout JSON {additionalContext: "..."} is injected into model context by runtime.
#   - Non-blocking: trap '... exit 0' ERR on any failure.
#   - Deletes .learn-trigger after consuming it (idempotent one-shot).
set -euo pipefail
trap 'exit 0' ERR

INPUT="$(cat 2>/dev/null || true)"

CWD="$(printf -- '%s' "$INPUT" | python3 -c "
import sys, json
try:
    d = json.loads(sys.stdin.read() or '{}')
    print(d.get('cwd', ''))
except Exception:
    print('')
" 2>/dev/null || true)"
[[ -z "$CWD" ]] && CWD="${CLAUDE_PROJECT_DIR:-${PWD:-}}"

# MEM-WRITE-PATH-FIX-01 round2 (finding #6): the writer (phase8-close.sh) anchors
# .learn-trigger to the durable main-repo root (git-common-dir), not the worktree
# cwd. This reader used the hook's raw session cwd, which "works" only because a
# fresh session usually starts at the main repo -- unproven if it ever starts
# inside a leftover worktree. Re-anchor CWD the same way, marker-checked, before
# resolving the trigger path, so writer and reader always agree.
_durable_cwd="$(git -C "$CWD" rev-parse --path-format=absolute --git-common-dir 2>/dev/null | xargs dirname 2>/dev/null || true)"
[[ -n "$_durable_cwd" && -d "${_durable_cwd}/docs/leadv2" ]] && CWD="$_durable_cwd"

# Resolve leadv2_dir (mirror pattern from leadv2-postcompact-goal-reinject.sh)
_sp_yaml="${CWD}/.claude/leadv2-overrides/state-paths.yaml"
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

_trigger="${CWD}/${_leadv2_dir}/.learn-trigger"
[[ -f "$_trigger" ]] || exit 0

# Read trigger metadata for context
_trigger_task_id="$(python3 -c "
import yaml, pathlib, sys
try:
    d = yaml.safe_load(pathlib.Path(sys.argv[1]).read_text()) or {}
    print(d.get('trigger_task_id', 'unknown'))
except Exception:
    print('unknown')
" "$_trigger" 2>/dev/null || echo 'unknown')"

_close_count="$(python3 -c "
import yaml, pathlib, sys
try:
    d = yaml.safe_load(pathlib.Path(sys.argv[1]).read_text()) or {}
    print(d.get('trigger_close_count', '?'))
except Exception:
    print('?')
" "$_trigger" 2>/dev/null || echo '?')"

# Consume trigger (delete) before emitting — prevents re-injection on crash/retry
rm -f "$_trigger" 2>/dev/null || true

python3 -c "
import json, sys
msg = (
    '[LEARN TRIGGER] Self-learning flywheel fired: '
    + str(sys.argv[1]) + ' closes completed (last task: ' + str(sys.argv[2]) + '). '
    + 'Run the leadv2-learn workflow NOW before starting new tasks: '
    + 'Workflow({name:\"leadv2-learn\", args:{taskId: \"' + str(sys.argv[2]) + '\"}}) '
    + '— this synthesizes recurring signals into immune-patterns and shared-memory. '
    + 'Do not skip: the self-learning flywheel depends on this step.'
)
print(json.dumps({'additionalContext': msg}))
" "$_close_count" "$_trigger_task_id" 2>/dev/null || true

exit 0
