#!/usr/bin/env bash
# UserPromptSubmit hook: inject lightweight context (active task phase + bloat warn).
# Saves lead from Read'ing active.yaml/STATE.md every turn.
# Output JSON with `additionalContext` field per Anthropic hooks spec.
set -euo pipefail
trap 'echo "[$(basename "$0")] error at line $LINENO" >&2; exit 0' ERR

INPUT="$(cat 2>/dev/null || true)"
[[ -z "$INPUT" ]] && exit 0

# shellcheck source=leadv2-mode-isolation.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/leadv2-mode-isolation.sh"

CWD="$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || echo "")"
[[ -z "$CWD" ]] && CWD="$PWD"
SESSION_ID="$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || echo "")"
_lv2_safe_session="$(printf -- '%s' "$SESSION_ID" | tr -cd 'A-Za-z0-9._-')"
SUPERVISOR_SESSION=0
if [[ -n "$_lv2_safe_session" && -f "/tmp/.leadv2-supervisor-mode-${_lv2_safe_session}" ]]; then
  SUPERVISOR_SESSION=1
fi

CTX_PARTS=()

# Resolve configured base dirs from state-paths.yaml (fallback: PE defaults)
_lv2_sp_yaml="${CWD}/.claude/leadv2-overrides/state-paths.yaml"
_lv2_leadv2_dir=$(grep -E "^[[:space:]]*leadv2_dir[[:space:]]*:" "$_lv2_sp_yaml" 2>/dev/null | head -1 | sed -E "s/^[[:space:]]*leadv2_dir[[:space:]]*:[[:space:]]*//" | sed -E "s/^['\"]//; s/['\"][[:space:]]*$//" | tr -d '\r' || true)
[[ -z "$_lv2_leadv2_dir" || "$_lv2_leadv2_dir" == "null" || "$_lv2_leadv2_dir" == "~" ]] && _lv2_leadv2_dir="docs/leadv2"
_lv2_handoff_dir=$(grep -E "^[[:space:]]*handoff_dir[[:space:]]*:" "$_lv2_sp_yaml" 2>/dev/null | head -1 | sed -E "s/^[[:space:]]*handoff_dir[[:space:]]*:[[:space:]]*//" | sed -E "s/^['\"]//; s/['\"][[:space:]]*$//" | tr -d '\r' || true)
[[ -z "$_lv2_handoff_dir" || "$_lv2_handoff_dir" == "null" || "$_lv2_handoff_dir" == "~" ]] && _lv2_handoff_dir="docs/handoff"

# === 0. /compact intercept: write pre-compact-resume.md BEFORE compact executes ===
PROMPT_TEXT="$(echo "$INPUT" | jq -r '.prompt // .message // empty' 2>/dev/null || echo "")"
if [[ "$SUPERVISOR_SESSION" != "1" ]] && echo "$PROMPT_TEXT" | grep -q '<command-name>/compact</command-name>'; then
  # Find active task
  ACTIVE_FILE=""
  for f in "$CWD/.claude/leadv2-tasks/active.yaml" "$CWD/${_lv2_leadv2_dir}/active.yaml"; do
    [[ -f "$f" ]] && ACTIVE_FILE="$f" && break
  done
  if [[ -n "$ACTIVE_FILE" ]]; then
    TID_FOR_RESUME="$(leadv2_hook_resolve_task_id "$INPUT" "$ACTIVE_FILE" 2>/dev/null || true)"
    if [[ -n "$TID_FOR_RESUME" ]]; then
      RESUME_DIR="$CWD/${_lv2_leadv2_dir}/tasks/$TID_FOR_RESUME"
      mkdir -p "$RESUME_DIR" 2>/dev/null || true
      RESUME_FILE="$RESUME_DIR/pre-compact-resume.md"
      # Read current phase from active.yaml
      PHASE_NOW="$(leadv2_hook_resolve_phase "$INPUT" "$ACTIVE_FILE" 2>/dev/null || true)"
      [[ -z "$PHASE_NOW" ]] && PHASE_NOW="?"
      # Read latest handoff artifact to infer context
      HANDOFF_DIR="$CWD/${_lv2_handoff_dir}/$TID_FOR_RESUME"
      LATEST_ARTIFACT=""
      if [[ -d "$HANDOFF_DIR" ]]; then
        LATEST_ARTIFACT="$(ls -t "$HANDOFF_DIR"/*.md "$HANDOFF_DIR"/*.yaml 2>/dev/null | head -1 | xargs basename 2>/dev/null || echo "")"
      fi
      cat > "$RESUME_FILE" <<RESUME
# pre-compact-resume: $TID_FOR_RESUME
written: $(date -u +%Y-%m-%dT%H:%M:%SZ)
task_id: $TID_FOR_RESUME
phase: $PHASE_NOW
latest_handoff: ${LATEST_ARTIFACT:-unknown}
---
You are the LEADV2 ORCHESTRATOR. Task: $TID_FOR_RESUME, phase: $PHASE_NOW.
After /compact: read ${_lv2_leadv2_dir}/tasks/$TID_FOR_RESUME/STATE.md limit=20 and ${_lv2_handoff_dir}/$TID_FOR_RESUME/context.yaml limit=30.
NEVER write .py/.sh/.ts/.tsx/.sql directly. Delegate ALL code changes to developer subagents.
RESUME
      # Emit typed pre-compact-resume.json alongside the .md for machine-readable recovery.
      # Fields: task_id/phase/latest_handoff/written from known values; others empty (no fabrication).
      python3 -c "
import json, sys
d = {
  'task_id': sys.argv[1],
  'phase': sys.argv[2],
  'latest_handoff': sys.argv[3],
  'written': sys.argv[4],
  'session_summary': '',
  'key_decisions': [],
  'blockers': [],
  'next_actions': [],
}
print(json.dumps(d, indent=2))
" "$TID_FOR_RESUME" "$PHASE_NOW" "${LATEST_ARTIFACT:-unknown}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"         > "${RESUME_DIR}/pre-compact-resume.json" 2>/dev/null || true
    fi
  fi
fi

# === 2. Active leadv2 task summary ===
TID_ACTIVE=""
if [[ "${LEADV2_ANCHOR_OWNS_CONTEXT:-1}" != "1" ]]; then
ACTIVE=""
for f in "$CWD/.claude/leadv2-tasks/active.yaml" "$CWD/${_lv2_leadv2_dir}/active.yaml"; do
  [[ -f "$f" ]] && ACTIVE="$f" && break
done
if [[ -n "$ACTIVE" ]]; then
  ACTIVE_SUM="$(python3 -c "
import yaml
try:
    d = yaml.safe_load(open('$ACTIVE')) or {}
    s = d.get('sessions') or []
    if not s: print('')
    else:
        lines = []
        for sess in s[:3]:
            tid = sess.get('task_id','?')
            phase = sess.get('phase','?')
            note = sess.get('note','') or sess.get('blocked_by','')
            extra = f' ({note})' if note else ''
            lines.append(f'  {tid}: phase={phase}{extra}')
        print('\n'.join(lines))
except Exception: print('')
" 2>/dev/null || echo "")"
  if [[ -n "$ACTIVE_SUM" ]]; then
    CTX_PARTS+=("[LEADV2_ACTIVE]
$ACTIVE_SUM
(Lead: read STATE.md only when needed for phase action. active.yaml summary above is current.)")
  fi

  # === 2.b. Auto-detect real phase from handoff/ artifacts (active.yaml often stale) ===
  TID_ACTIVE="$(leadv2_hook_resolve_task_id "$INPUT" "$ACTIVE" 2>/dev/null || true)"
  if [[ -n "$TID_ACTIVE" ]]; then
    HANDOFF_DIR="$CWD/${_lv2_handoff_dir}/$TID_ACTIVE"
    if [[ -d "$HANDOFF_DIR" ]]; then
      DETECT="$(python3 -c "
import os, glob
d = '$HANDOFF_DIR'
files = {f: os.path.getmtime(os.path.join(d,f)) for f in os.listdir(d) if os.path.isfile(os.path.join(d,f))}
if not files:
    print('')
else:
    latest = max(files.items(), key=lambda x: x[1])[0]
    review_rounds = len(glob.glob(os.path.join(d, 'codex-review-r*.md'))) + (1 if os.path.exists(os.path.join(d, 'codex-review.md')) else 0)
    dev_rounds = len(glob.glob(os.path.join(d, 'developer-r*.md'))) + (1 if os.path.exists(os.path.join(d, 'developer.md')) else 0)
    iter_rounds = max(review_rounds, dev_rounds)
    phase_likely = 'intake'
    if 'phase8-passed.flag' in files or 'phase11-passed.flag' in files: phase_likely = 'closed'
    elif latest.startswith('deploy'): phase_likely = 'deploy'
    elif latest.startswith('verify') or 'verify.md' in files: phase_likely = 'verify'
    elif latest.startswith('codex-review') or latest.startswith('review'): phase_likely = 'review'
    elif latest == 'developer.md' or latest.startswith('build'): phase_likely = 'build'
    elif latest.startswith('plan') or latest.startswith('classify'): phase_likely = 'plan'
    print(f'phase_likely={phase_likely}|review_rounds={review_rounds}|dev_rounds={dev_rounds}|iter_rounds={iter_rounds}|latest={latest}')
" 2>/dev/null || echo "")"
      if [[ -n "$DETECT" ]]; then
        ITER_ROUNDS=$(echo "$DETECT" | sed -n 's/.*iter_rounds=\([0-9]*\).*/\1/p')
        PHASE_HINT="[LEADV2_PHASE_HINT] handoff/$TID_ACTIVE: $DETECT"
        if [[ "${ITER_ROUNDS:-0}" -ge 1 ]]; then
          PHASE_HINT="$PHASE_HINT
[SEVERITY_GATE] Round developer ONLY on findings tagged critical|high. medium|nit findings → auto-accept with note in close-summary. If codex did not tag severity, treat as nit (cosmetic) by default. Don't optimize codex into nit-finding loops."
        fi
        if [[ "${ITER_ROUNDS:-0}" -ge 2 ]]; then
          PHASE_HINT="$PHASE_HINT
[ROUND_CAP_REACHED] STRICT: ${ITER_ROUNDS} iterations done — DO NOT spawn another developer round. Call Skill(leadv2-judge) mode=review NOW. Judge will: accept-with-caveats / scope-cut / abort. Lead just dispatches."
        fi
        CTX_PARTS+=("$PHASE_HINT")
      fi
    fi
  fi
fi

# === 2.4. Orchestrator role reminder — fires when active task detected ===
# Fires on every user turn so /compact doesn't erase the orchestrator frame.
if [[ -n "$TID_ACTIVE" ]]; then
  # Check for pre-compact-resume context (written by lead before /compact)
  RESUME_FILE="$CWD/${_lv2_leadv2_dir}/tasks/$TID_ACTIVE/pre-compact-resume.md"
  RESUME_SNIPPET=""
  if [[ -f "$RESUME_FILE" ]]; then
    # Read last 20 lines — it's a short status dump
    RESUME_SNIPPET="$(tail -20 "$RESUME_FILE" 2>/dev/null || true)"
    RESUME_INJECT="[POST_COMPACT_RESUME] $TID_ACTIVE context before last /compact:
$RESUME_SNIPPET"
    CTX_PARTS+=("$RESUME_INJECT")
  fi

  # EFFICIENCY-TUNE-01 A2: full block once/session (sentinel), 1-line pointer thereafter.
  ORCH_SENTINEL="/tmp/leadv2-orch-role-${SESSION_ID:-nosession}"
  if [[ ! -f "$ORCH_SENTINEL" ]]; then
    # Knowledge archive lookup hint — one line, always visible when a task is active
    KNOWLEDGE_DIR="$CWD/docs/leadv2/knowledge"
    KNOWLEDGE_COUNT=0
    [[ -d "$KNOWLEDGE_DIR" ]] && KNOWLEDGE_COUNT=$(ls "$KNOWLEDGE_DIR"/*.md 2>/dev/null | wc -l | tr -d ' ' || echo 0)
    if [[ "$KNOWLEDGE_COUNT" -gt 0 ]]; then
      CTX_PARTS+=("[KNOWLEDGE_ARCHIVE] ${KNOWLEDGE_COUNT} entries in docs/leadv2/knowledge/. Before re-deciding anything (architecture choice, schema approach, error strategy), run: grep -r '<keyword>' docs/leadv2/knowledge/ to surface prior decisions and gotchas.")
    fi

    CTX_PARTS+=("[ORCHESTRATOR_ROLE] You are the LEADV2 ORCHESTRATOR for task $TID_ACTIVE.
Rules that persist across /compact:
- NEVER write .py/.sh/.ts/.tsx/.sql directly — delegate ALL code to developer/devops subagents.
- SILENCE PROTOCOL: No preamble. No 'Let me…'. No reasoning narration. Output ONLY: pulse line | gate prompt | async question | ≤3-line close. All detail → deliverable files.
- Every text-only turn costs 150K+ tokens. No 'I am now doing X'. No multi-paragraph reasoning.
- If you just resumed from /compact: read ${_lv2_leadv2_dir}/tasks/$TID_ACTIVE/STATE.md limit=20 and ${_lv2_handoff_dir}/$TID_ACTIVE/context.yaml limit=30 to restore plan context.")
    touch "$ORCH_SENTINEL" 2>/dev/null || true
  else
    CTX_PARTS+=("[ORCHESTRATOR_ROLE] full rules already injected this session — see above.")
  fi
fi

fi # LEADV2_ANCHOR_OWNS_CONTEXT: task-anchor owns active/phase/role context by default

# === 2.5. Pending Stop-hook warnings (lead-prose-guard, etc.) ===
if [[ -n "$SESSION_ID" ]]; then
  WARN_FILE="$HOME/.claude/leadv2-pending-warn-${SESSION_ID}.txt"
  if [[ -f "$WARN_FILE" ]]; then
    WARN_CONTENT="$(cat "$WARN_FILE" 2>/dev/null || true)"
    if [[ -n "$WARN_CONTENT" ]]; then
      CTX_PARTS+=("$WARN_CONTENT")
      rm -f "$WARN_FILE" 2>/dev/null || true
    fi
    rm -f "$WARN_FILE"
  fi
fi

# === 3. Per-prompt budget reset (also tracked by task-budget-tracker.sh) ===
if [[ -n "$SESSION_ID" ]]; then
  BUDGET_FILE="/tmp/.leadv2-budget-${SESSION_ID}"
  PREV="$(cat "$BUDGET_FILE" 2>/dev/null || echo '0|0')"
  PREV_TOOLS="${PREV%|*}"
  PREV_TOTAL_TYPED="${PREV#*|}"
  NEW_TOTAL_TYPED=$((PREV_TOTAL_TYPED + 1))
  echo "0|${NEW_TOTAL_TYPED}" > "$BUDGET_FILE"  # reset tool counter for this prompt
  if [[ "$PREV_TOOLS" -gt 30 ]] && [[ "$PREV_TOTAL_TYPED" -gt 0 ]]; then
    CTX_PARTS+=("[PREV_TURN_TOOLS] Lead used ${PREV_TOOLS} tool calls on previous founder input. Heavy. Aim for <10 per founder turn unless heavy build phase.")
  fi
fi

# === Emit JSON if anything to inject ===
if [[ ${#CTX_PARTS[@]} -gt 0 ]]; then
  CONTEXT_BODY="$(printf '%s\n\n' "${CTX_PARTS[@]}")"
  jq -n --arg ctx "$CONTEXT_BODY" '{
    hookSpecificOutput: {
      hookEventName: "UserPromptSubmit",
      additionalContext: $ctx
    }
  }'
fi
exit 0
