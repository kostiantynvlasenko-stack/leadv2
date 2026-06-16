#!/usr/bin/env bash
# PreToolUse:Agent hook — hard-block developer spawns during Build phase
# when Gate 1 artifacts are absent (context.yaml AND .gate1-passed sentinel).
#
# HARD BLOCK: exit 2 with deny decision JSON when artifacts are missing.
# Fail-safe: any internal error exits 0 (never blocks session on hook crash).
# Does NOT fire for non-developer subagent types or non-build phases.
#
# Override: LEADV2_GATE_ENFORCE=0 disables this hook entirely.

set -euo pipefail
trap 'exit 0' ERR

[[ "${LEADV2_GATE_ENFORCE:-1}" == "0" ]] && exit 0

INPUT="$(cat 2>/dev/null || true)"
[[ -z "$INPUT" ]] && exit 0

# Parse subagent_type and cwd from hook input JSON
PARSED="$(python3 -c "
import sys, json
try:
    d = json.loads(sys.argv[1])
    inp = d.get('tool_input') or {}
    stype = (inp.get('subagent_type') or '').strip().lower()
    cwd   = (d.get('cwd') or '').strip()
    print(stype)
    print(cwd)
except Exception:
    pass
" "$INPUT" 2>/dev/null || true)"

[[ -z "$PARSED" ]] && exit 0

SUBTYPE="$(printf '%s' "$PARSED" | sed -n '1p')"
CWD="$(printf '%s' "$PARSED" | sed -n '2p')"
[[ -z "$CWD" ]] && CWD="$PWD"

# Only applies to build-role subagent types
case "$SUBTYPE" in
  developer|frontend-developer) ;;
  *) exit 0 ;;
esac

# Determine active phase: env var first, then active.yaml
ACTIVE_PHASE="${LEADV2_ACTIVE_PHASE:-}"

if [[ -z "$ACTIVE_PHASE" ]]; then
  for _cand in "$CWD/docs/leadv2/active.yaml" "$CWD/.claude/leadv2-tasks/active.yaml"; do
    if [[ -f "$_cand" ]]; then
      ACTIVE_PHASE="$(python3 -c "
import sys
try:
    try:
        import yaml
        d = yaml.safe_load(open(sys.argv[1])) or {}
    except ImportError:
        import re
        src = open(sys.argv[1]).read()
        m = re.search(r'phase\s*:\s*(\S+)', src)
        d = {'sessions': [{'phase': m.group(1).strip(\"'\\\"\")}]} if m else {}
    sessions = d.get('sessions') or []
    print((sessions[0].get('phase') or '').lower().strip() if sessions else '')
except Exception:
    pass
" "$_cand" 2>/dev/null || true)"
      break
    fi
  done
fi

# Only enforce during build phase
case "${ACTIVE_PHASE:-}" in
  build) ;;
  *) exit 0 ;;
esac

# Resolve TASK_ID: env first, then sanitize for filesystem use
TASK_ID="$(printf '%s' "${LEADV2_TASK_ID:-}" | tr -cd 'A-Za-z0-9._-')"
[[ -z "$TASK_ID" ]] && exit 0  # fail-open: no task id, cannot check

HANDOFF_DIR="$CWD/docs/handoff/$TASK_ID"
CONTEXT_YAML="$HANDOFF_DIR/context.yaml"
GATE1_SENTINEL="$HANDOFF_DIR/.gate1-passed"

MISSING=()
[[ ! -f "$CONTEXT_YAML" ]] && MISSING+=("docs/handoff/$TASK_ID/context.yaml")
[[ ! -f "$GATE1_SENTINEL" ]] && MISSING+=("docs/handoff/$TASK_ID/.gate1-passed")

[[ "${#MISSING[@]}" -eq 0 ]] && exit 0

# Hard block: emit deny decision JSON then exit 2
MISSING_LIST="$(printf '%s, ' "${MISSING[@]}" | sed 's/, $//')"
python3 -c "
import sys, json
task_id = sys.argv[1]
missing = sys.argv[2]
subtype = sys.argv[3]
reason = (
    '[GATE-ARTIFACT-GUARD] DENY: Build phase spawned without Gate 1 artifacts. '
    'Missing: ' + missing + '. '
    'Required: docs/handoff/' + task_id + '/context.yaml AND docs/handoff/' + task_id + '/.gate1-passed. '
    'Gate 1 must be presented to founder and approved before Build. '
    'Override: LEADV2_GATE_ENFORCE=0'
)
print(json.dumps({'hookSpecificOutput': {'hookEventName': 'PreToolUse', 'permissionDecision': 'deny', 'permissionDecisionReason': reason}}))
" -- "$TASK_ID" "$MISSING_LIST" "$SUBTYPE"

exit 2
