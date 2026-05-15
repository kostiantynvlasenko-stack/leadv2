#!/usr/bin/env bash
# SubagentStop hook: verify subagent wrote a deliverable file with DELIVERABLE_COMPLETE marker.
# Soft mode by default — emits warning. Strict via LEADV2_SUBAGENT_VERIFY_STRICT=1 → blocks Stop.
set -euo pipefail
trap 'echo "[$(basename "$0")] error at line $LINENO" >&2; exit 0' ERR

INPUT="$(cat 2>/dev/null || true)"
[[ -z "$INPUT" ]] && exit 0

CWD="$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || echo "")"
[[ -z "$CWD" ]] && CWD="$PWD"

# Find any active task's handoff dir
ACTIVE=""
for f in "$CWD/.claude/leadv2-tasks/active.yaml" "$CWD/docs/leadv2/active.yaml"; do
  [[ -f "$f" ]] && ACTIVE="$f" && break
done
[[ -z "$ACTIVE" ]] && exit 0

TASK_ID="$(python3 -c "
import yaml
try:
    d = yaml.safe_load(open('$ACTIVE')) or {}
    s = d.get('sessions') or []
    print(s[0].get('task_id','') if s else '')
except: print('')
" 2>/dev/null || echo "")"
[[ -z "$TASK_ID" ]] && exit 0

# Look for any .md deliverable in handoff dir modified within last 60s
HANDOFF_DIRS=(
  "$CWD/docs/handoff/$TASK_ID"
  "$CWD/.claude/leadv2-tasks/$TASK_ID"
)
HAS_RECENT=0
HAS_MARKER=0
for hd in "${HANDOFF_DIRS[@]}"; do
  [[ -d "$hd" ]] || continue
  for f in $(find "$hd" -maxdepth 2 -name '*.md' -mmin -1 -type f 2>/dev/null); do
    HAS_RECENT=1
    if tail -5 "$f" 2>/dev/null | grep -q 'DELIVERABLE_COMPLETE'; then
      HAS_MARKER=1
      break 2
    fi
  done
done

# If recent file exists but no marker → soft warn (or strict block)
if [[ "$HAS_RECENT" -eq 1 && "$HAS_MARKER" -eq 0 ]]; then
  if [[ "${LEADV2_SUBAGENT_VERIFY_STRICT:-0}" == "1" ]]; then
    jq -n '{
      decision: "block",
      reason: "Subagent wrote a deliverable but did not end with DELIVERABLE_COMPLETE marker. Add it before stopping so lead can verify completion."
    }'
    exit 0
  fi
  echo "[leadv2-subagent-stop-verify] WARN: deliverable written without DELIVERABLE_COMPLETE marker (task=$TASK_ID)" >&2
fi
exit 0
