#!/usr/bin/env bash
# Blocks codex adversarial-review invocations beyond round 2 for a given task.
# Reads docs/handoff/<task-id>/context.yaml — counts existing reviews.codex_round_*.
# Exit 0 = OK to launch round; exit 1 = HARD CAP, escalate to architect/founder.
set -euo pipefail

TASK_ID="${1:-${LEADV2_TASK_ID:-}}"
if [[ -z "$TASK_ID" ]]; then
  echo "[round-gate] no task_id provided/exported — allowing (script invoked outside /leadv2)" >&2
  exit 0
fi

CTX="docs/handoff/${TASK_ID}/context.yaml"
[[ -f "$CTX" ]] || CTX="docs/leadv2/tasks/${TASK_ID}/context.yaml"
if [[ ! -f "$CTX" ]]; then
  echo "[round-gate] no context.yaml found for ${TASK_ID} — allowing first round" >&2
  exit 0
fi

ROUND_COUNT=$(python3 -c "
import yaml, sys
try:
    d = yaml.safe_load(open(sys.argv[1])) or {}
except Exception:
    print(0); sys.exit(0)
reviews = (d.get('reviews') or {})
n = sum(1 for k in reviews if k.startswith('codex_round_'))
print(n)
" "$CTX" 2>/dev/null || echo 0)

if [[ "$ROUND_COUNT" -ge 2 ]]; then
  cat >&2 <<MSG
[round-gate] HARD CAP: task=${TASK_ID} already has ${ROUND_COUNT} codex review rounds.
Per leadv2-review SKILL.md: max 2 rounds → architect escape → judge → founder.
Do NOT launch codex round $((ROUND_COUNT + 1)). Options:
  (a) Spawn architect(opus) with alt-approach
  (b) Invoke Skill(leadv2-judge) mode=review for ship/revise/abort verdict
  (c) Escalate to founder via AskUserQuestion
Set ROUND_GATE_OVERRIDE=1 to force (logged + flagged for retro).
MSG
  if [[ "${ROUND_GATE_OVERRIDE:-0}" == "1" ]]; then
    echo "[round-gate] OVERRIDE accepted, logging" >&2
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) override task=${TASK_ID} prev_rounds=${ROUND_COUNT}" \
      >> "$HOME/.claude/leadv2-round-gate-overrides.log"
    exit 0
  fi
  exit 1
fi

echo "[round-gate] OK: task=${TASK_ID} round=$((ROUND_COUNT + 1)) of 2" >&2
exit 0
