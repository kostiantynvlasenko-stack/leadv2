#!/usr/bin/env bash
# leadv2-budget-check.sh — Mid-task token-budget gate (PO-059)
#
# Usage: leadv2-budget-check.sh --task-id <id> [--class <Light|Standard|Heavy>]
#
# Exit codes:
#   0 — under budget (continue)
#   1 — over ceiling (abort)
#   2 — over 75% warning (warn, continue)
#
# Ceilings (configurable via env):
#   LEADV2_BUDGET_LIGHT    default 50000
#   LEADV2_BUDGET_STANDARD default 200000
#   LEADV2_BUDGET_HEAVY    default 600000

set -euo pipefail
trap 'exit 0' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

log() { printf -- '[leadv2-budget-check] %s\n' "$*" >&2; }

TASK_ID=""
TASK_CLASS=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --task-id) TASK_ID="$2"; shift 2 ;;
    --class)   TASK_CLASS="$2"; shift 2 ;;
    *) shift ;;
  esac
done

[[ -z "$TASK_ID" ]] && { log "ERROR: --task-id required"; exit 0; }

# ── Resolve task class (arg > active.yaml > default Standard) ──────────────────

if [[ -z "$TASK_CLASS" ]]; then
  ACTIVE_YAML=""
  for f in "$PROJECT_ROOT/.claude/leadv2-tasks/active.yaml" \
            "$PROJECT_ROOT/docs/leadv2/active.yaml"; do
    [[ -f "$f" ]] && ACTIVE_YAML="$f" && break
  done

  if [[ -n "$ACTIVE_YAML" ]]; then
    TASK_CLASS="$(python3 -c "
import yaml, sys
try:
    d = yaml.safe_load(open('$ACTIVE_YAML')) or {}
    for s in (d.get('sessions') or []):
        if s.get('task_id') == '$TASK_ID':
            print(s.get('class', s.get('task_class', 'Standard')))
            sys.exit(0)
    print('Standard')
except Exception:
    print('Standard')
" 2>/dev/null || echo "Standard")"
  else
    TASK_CLASS="Standard"
  fi
fi

# Normalize capitalisation
TASK_CLASS="$(printf '%s' "$TASK_CLASS" | awk '{print toupper(substr($0,1,1)) tolower(substr($0,2))}')"

# ── Resolve ceiling per class ──────────────────────────────────────────────────

case "$TASK_CLASS" in
  Light)    CEILING="${LEADV2_BUDGET_LIGHT:-50000}" ;;
  Heavy)    CEILING="${LEADV2_BUDGET_HEAVY:-600000}" ;;
  Standard) CEILING="${LEADV2_BUDGET_STANDARD:-200000}" ;;
  # Fallback for unknown class names
  *)        CEILING="${LEADV2_BUDGET_STANDARD:-200000}" ;;
esac

WARN_THRESHOLD=$(( CEILING * 75 / 100 ))

# ── Accumulate spent tokens from costs.yaml in the task handoff dir ───────────

HANDOFF_DIR="$PROJECT_ROOT/docs/handoff/$TASK_ID"
COSTS_FILE="$HANDOFF_DIR/costs.yaml"

SPENT=0

if [[ -f "$COSTS_FILE" ]]; then
  SPENT="$(python3 -c "
import yaml, sys
try:
    d = yaml.safe_load(open('$COSTS_FILE')) or {}
    entries = d.get('entries') or d.get('sessions') or []
    if isinstance(entries, list):
        total = sum(
            (e.get('input_tokens', 0) or 0) + (e.get('output_tokens', 0) or 0)
            for e in entries
            if isinstance(e, dict)
        )
    elif isinstance(d, dict):
        # flat format: top-level input_tokens / output_tokens
        total = (d.get('input_tokens', 0) or 0) + (d.get('output_tokens', 0) or 0)
    else:
        total = 0
    print(int(total))
except Exception as e:
    print(0)
" 2>/dev/null || echo "0")"
fi

# Fallback: sum raw input/output tokens from any .stream.jsonl file in handoff dir
if [[ "${SPENT:-0}" -eq 0 && -d "$HANDOFF_DIR" ]]; then
  SPENT="$(python3 -c "
import os, json
total = 0
hdir = '$HANDOFF_DIR'
for fname in os.listdir(hdir):
    if not fname.endswith('.stream.jsonl'):
        continue
    path = os.path.join(hdir, fname)
    try:
        with open(path) as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                    usage = obj.get('usage') or obj.get('message', {}).get('usage') or {}
                    total += (usage.get('input_tokens', 0) or 0)
                    total += (usage.get('output_tokens', 0) or 0)
                except Exception:
                    pass
    except Exception:
        pass
print(total)
" 2>/dev/null || echo "0")"
fi

SPENT="${SPENT:-0}"

# ── Gate logic ─────────────────────────────────────────────────────────────────

PCT=0
if [[ "$CEILING" -gt 0 ]]; then
  PCT=$(( SPENT * 100 / CEILING ))
fi

log "task=$TASK_ID class=$TASK_CLASS spent=$SPENT ceiling=$CEILING pct=$PCT%"

if [[ "$SPENT" -ge "$CEILING" ]]; then
  log "ABORT: cumulative tokens $SPENT >= ceiling $CEILING for class $TASK_CLASS"
  printf -- 'budget_status: over_ceiling\nspent: %s\nceiling: %s\npct: %s\ntask_class: %s\n' \
    "$SPENT" "$CEILING" "$PCT" "$TASK_CLASS"
  exit 1
fi

if [[ "$SPENT" -ge "$WARN_THRESHOLD" ]]; then
  log "WARN: cumulative tokens $SPENT >= 75%% of ceiling $CEILING (${WARN_THRESHOLD}) for class $TASK_CLASS"
  printf -- 'budget_status: warn_75pct\nspent: %s\nceiling: %s\npct: %s\ntask_class: %s\n' \
    "$SPENT" "$CEILING" "$PCT" "$TASK_CLASS"
  exit 2
fi

printf -- 'budget_status: ok\nspent: %s\nceiling: %s\npct: %s\ntask_class: %s\n' \
  "$SPENT" "$CEILING" "$PCT" "$TASK_CLASS"
exit 0
