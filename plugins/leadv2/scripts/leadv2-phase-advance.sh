#!/usr/bin/env bash
# Phase machine — advances /leadv2 task phase based on file state, not LLM judgment.
#
# Usage: leadv2-phase-advance.sh --task-id <id>
# Output (yaml-ish, one key=value per line):
#   phase_now: build
#   phase_next: review            # or "blocked"
#   deliverables_present: ["build.summary.md"]
#   verdicts: ["APPROVE"]
#   action: spawn_review          # spawn_review | spawn_deploy | wait | escalate | close
#   reason: "build verdict APPROVE; deploy precondition met"

set -euo pipefail
trap 'exit 0' ERR

PROJECT_ROOT="${PROJECT_ROOT:-$(pwd)}"
TASK_ID=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --task-id) TASK_ID="$2"; shift 2 ;;
    *) shift ;;
  esac
done

[[ -z "$TASK_ID" ]] && { echo "ERROR: --task-id required" >&2; exit 1; }

HANDOFF_DIR="$PROJECT_ROOT/docs/handoff/$TASK_ID"
ACTIVE_YAML=""
for f in "$PROJECT_ROOT/.claude/leadv2-tasks/active.yaml" "$PROJECT_ROOT/docs/leadv2/active.yaml"; do
  [[ -f "$f" ]] && ACTIVE_YAML="$f" && break
done

# Read current phase from active.yaml
PHASE_NOW="$(python3 -c "
import yaml, sys
try:
    d = yaml.safe_load(open('$ACTIVE_YAML')) or {}
    for s in d.get('sessions') or []:
        if s.get('task_id') == '$TASK_ID':
            print(s.get('phase','unknown'))
            sys.exit(0)
    print('unknown')
except Exception:
    print('unknown')
" 2>/dev/null || echo "unknown")"

# ── PO-059: Mid-task token-budget gate ────────────────────────────────────────
# Run at the START of every phase transition — aborting early is cheaper than late.
BUDGET_SCRIPT="$(dirname "${BASH_SOURCE[0]}")/leadv2-budget-check.sh"
if [[ -f "$BUDGET_SCRIPT" ]]; then
  BUDGET_EXIT=0
  bash "$BUDGET_SCRIPT" --task-id "$TASK_ID" 2>/dev/null || BUDGET_EXIT=$?
  if [[ "$BUDGET_EXIT" -eq 1 ]]; then
    echo "phase_now: $PHASE_NOW"
    echo "phase_next: blocked"
    echo "deliverables_present: []"
    echo "verdicts: []"
    echo "action: abort_budget"
    echo "reason: token ceiling exceeded — leadv2-budget-check exit 1"
    exit 1
  fi
  # exit 2 (75% warn) — continue but phase-advance already logged the warning
fi

# Collect deliverables and their verdicts
DELIVERABLES=()
VERDICTS=()
if [[ -d "$HANDOFF_DIR" ]]; then
  for f in "$HANDOFF_DIR"/*.summary.md; do
    [[ -f "$f" ]] || continue
    name="$(basename "$f")"
    DELIVERABLES+=("$name")
    v="$(head -5 "$f" | grep -E '^verdict:' | head -1 | sed 's/^verdict:[ ]*//' | tr -d '"' || echo "UNKNOWN")"
    VERDICTS+=("$v")
  done
fi

# Phase transition rules (data-driven)
PHASE_NEXT="$PHASE_NOW"
ACTION="wait"
REASON="no transition rule fired"

case "$PHASE_NOW" in
  intake|classify|plan)
    if [[ -f "$HANDOFF_DIR/architect.summary.md" && -f "$HANDOFF_DIR/critic.summary.md" ]]; then
      ARCH_V="$(head -5 "$HANDOFF_DIR/architect.summary.md" | grep -E '^verdict:' | sed 's/.*: *//' | tr -d '"')"
      CRIT_V="$(head -5 "$HANDOFF_DIR/critic.summary.md" | grep -E '^verdict:' | sed 's/.*: *//' | tr -d '"')"
      if [[ "$ARCH_V" == "APPROVE" && "$CRIT_V" == "APPROVE" ]]; then
        PHASE_NEXT="gate1"; ACTION="propose_gate1"; REASON="plan triad APPROVED"
      else
        ACTION="wait"; REASON="plan triad not yet APPROVED (arch=$ARCH_V crit=$CRIT_V)"
      fi
    fi
    ;;
  gate1|build)
    if [[ -f "$HANDOFF_DIR/build.summary.md" ]]; then
      BV="$(head -5 "$HANDOFF_DIR/build.summary.md" | grep -E '^verdict:' | sed 's/.*: *//' | tr -d '"')"
      if [[ "$BV" == "APPROVE" ]]; then
        PHASE_NEXT="review"; ACTION="spawn_review"; REASON="build APPROVED → spawn review triad"
      elif [[ "$BV" == "BLOCK" ]]; then
        PHASE_NEXT="recovery"; ACTION="escalate"; REASON="build BLOCKED → recovery"
      fi
    fi
    ;;
  review)
    R_VERDICTS=()
    for r in critic codex sec-auditor; do
      f="$HANDOFF_DIR/${r}.summary.md"
      [[ -f "$f" ]] && R_VERDICTS+=("$(head -5 "$f" | grep -E '^verdict:' | sed 's/.*: *//' | tr -d '"')")
    done
    if [[ ${#R_VERDICTS[@]} -ge 2 ]]; then
      ALL_OK=1
      for v in "${R_VERDICTS[@]}"; do
        [[ "$v" != "APPROVE" ]] && ALL_OK=0
      done
      if [[ "$ALL_OK" -eq 1 ]]; then
        PHASE_NEXT="gate2"; ACTION="propose_gate2"; REASON="review triad APPROVED"
      else
        PHASE_NEXT="review_round_2"; ACTION="spawn_developer_revise"; REASON="review found issues (verdicts: ${R_VERDICTS[*]})"
      fi
    fi
    ;;
  gate2|deploy)
    if [[ -f "$HANDOFF_DIR/deploy.summary.md" ]]; then
      DV="$(head -5 "$HANDOFF_DIR/deploy.summary.md" | grep -E '^verdict:' | sed 's/.*: *//' | tr -d '"')"
      if [[ "$DV" == "APPROVE" ]]; then
        PHASE_NEXT="verify"; ACTION="spawn_verify"; REASON="deploy APPROVED → spawn verify"
      elif [[ "$DV" == "BLOCK" ]]; then
        PHASE_NEXT="recovery"; ACTION="escalate"; REASON="deploy failed"
      fi
    fi
    ;;
  verify)
    if [[ -f "$HANDOFF_DIR/verify.summary.md" ]]; then
      VV="$(head -5 "$HANDOFF_DIR/verify.summary.md" | grep -E '^verdict:' | sed 's/.*: *//' | tr -d '"')"
      [[ "$VV" == "APPROVE" ]] && { PHASE_NEXT="close"; ACTION="close"; REASON="verify OK"; } \
        || { PHASE_NEXT="recovery"; ACTION="escalate"; REASON="verify failed"; }
    fi
    ;;
esac

# Format output
DELIV_JSON="["
for d in "${DELIVERABLES[@]}"; do DELIV_JSON+="\"$d\","; done
DELIV_JSON="${DELIV_JSON%,}]"

VERD_JSON="["
for v in "${VERDICTS[@]}"; do VERD_JSON+="\"$v\","; done
VERD_JSON="${VERD_JSON%,}]"

cat <<EOF
phase_now: $PHASE_NOW
phase_next: $PHASE_NEXT
deliverables_present: $DELIV_JSON
verdicts: $VERD_JSON
action: $ACTION
reason: "$REASON"
EOF
