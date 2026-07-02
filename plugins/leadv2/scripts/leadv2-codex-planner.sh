#!/bin/bash
set -euo pipefail
# leadv2-codex-planner.sh — wrapper around codex-task.sh for /leadv2 Plan phase.

# Repo-level Codex switch. m3-market must set codex_enabled: false in
# .claude/leadv2-overrides/codex-policy.yaml; this script then exits 0 with a
# clear stderr message so the caller falls back to Agent(critic, opus).
_LV2_HELPERS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
if source "${_LV2_HELPERS_DIR}/leadv2-helpers.sh" 2>/dev/null && declare -F _lv2_codex_enabled >/dev/null; then
  if ! _lv2_codex_enabled; then
    repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    echo "[leadv2-codex-planner] codex_enabled=false in ${repo_root}/.claude/leadv2-overrides/codex-policy.yaml — skipping Codex (use Agent(critic, opus) fallback)" >&2
    echo "codex_skipped_by_policy"
    exit 0
  fi
fi

usage() {
  cat >&2 <<EOF
Usage: leadv2-codex-planner.sh --task-id <id> (--mission "<text>" | --mission-file <path>) [--effort <medium|high|xhigh>=high]
       leadv2-codex-planner.sh --task-id <id> --mode <quick-verify|diagnose|reconfirm> [--out <file>]
                                [--diff-paths <str>] [--log-path <file>] [--prior-verdict <file>]

  --mission "<text>"     Inline mission text (passed directly via CLI). --mode plan only.
  --mission-file <path>  Path to mission file; read early for race protection.
                         Mutually exclusive with --mission. --mode plan only.
  --mode <m>             plan (default, current behavior) | quick-verify | diagnose | reconfirm.
                         Non-plan modes assemble a short mode-specific prompt and imply --wait.
  --out <file>           Write findings here instead of the default handoff path (non-plan modes).
  --diff-paths <str>     quick-verify: paths to review. diagnose: diff content/path (optional).
  --log-path <file>      diagnose: log file (tail -100 used as prompt input).
  --prior-verdict <file> reconfirm: prior verdict file content used as prompt input.

Codex model is the codex-companion default (gpt-5.5 on plugin >=1.0.4).
The --model flag is intentionally not exposed; spark is banned project-wide.
EOF
  exit 1
}

TASK_ID=""; MISSION=""; MISSION_FILE=""; EFFORT="high"; WAIT=0
MODE="plan"; OUT_FILE=""; DIFF_PATHS=""; LOG_PATH=""; PRIOR_VERDICT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --task-id)       TASK_ID="$2"; shift 2 ;;
    --mission)       MISSION="$2"; shift 2 ;;
    --mission-file)  MISSION_FILE="$2"; shift 2 ;;
    --effort)        EFFORT="$2"; shift 2 ;;
    --wait)          WAIT=1; shift ;;
    --mode)          MODE="$2"; shift 2 ;;
    --out)           OUT_FILE="$2"; shift 2 ;;
    --diff-paths)    DIFF_PATHS="$2"; shift 2 ;;
    --log-path)      LOG_PATH="$2"; shift 2 ;;
    --prior-verdict) PRIOR_VERDICT="$2"; shift 2 ;;
    --model)
      echo "[leadv2-codex-planner] --model is no longer accepted (gpt-5.5 default, spark banned)" >&2
      usage
      ;;
    *) echo "[leadv2-codex-planner] unknown arg: $1" >&2; usage ;;
  esac
done

case "$MODE" in
  plan|quick-verify|diagnose|reconfirm) ;;
  *) echo "[leadv2-codex-planner] unknown --mode: $MODE (expected plan|quick-verify|diagnose|reconfirm)" >&2; usage ;;
esac

# Validate: task-id always required.
[[ -z "$TASK_ID" ]] && { echo "[leadv2-codex-planner] --task-id is required" >&2; usage; }

if [[ "$MODE" == "plan" ]]; then
  # Exactly one of --mission / --mission-file required (unchanged legacy behavior).
  if [[ -n "$MISSION" && -n "$MISSION_FILE" ]]; then
    echo "[leadv2-codex-planner] --mission and --mission-file are mutually exclusive" >&2; usage
  fi
  if [[ -z "$MISSION" && -z "$MISSION_FILE" ]]; then
    echo "[leadv2-codex-planner] one of --mission or --mission-file is required" >&2; usage
  fi

  # Resolve --mission-file: realpath, readable, non-empty. Read NOW for race protection.
  if [[ -n "$MISSION_FILE" ]]; then
    RESOLVED=$(realpath "$MISSION_FILE" 2>/dev/null) || {
      echo "[leadv2-codex-planner] cannot resolve path: $MISSION_FILE" >&2; exit 1
    }
    [[ -r "$RESOLVED" ]] || {
      echo "[leadv2-codex-planner] mission file not readable: $RESOLVED" >&2; exit 1
    }
    MISSION=$(< "$RESOLVED")
    [[ -n "$MISSION" ]] || {
      echo "[leadv2-codex-planner] mission file is empty: $RESOLVED" >&2; exit 1
    }
  fi
else
  # Non-plan modes: mission not required from the caller -- assemble a short
  # mode-specific prompt instead, and imply synchronous --wait.
  WAIT=1
  _read_or_literal() {
    local val="$1"
    [[ -n "$val" && -f "$val" ]] && cat "$val" 2>/dev/null || printf '%s' "$val"
  }
  case "$MODE" in
    quick-verify)
      MISSION="review ONLY these paths for Critical/High: ${DIFF_PATHS}. Max 3 findings, one sentence each"
      ;;
    diagnose)
      LOG_CONTENT=""
      [[ -n "$LOG_PATH" && -f "$LOG_PATH" ]] && LOG_CONTENT="$(tail -100 "$LOG_PATH" 2>/dev/null || true)"
      DIFF_CONTENT="$(_read_or_literal "$DIFF_PATHS")"
      MISSION="independent root-cause hypothesis. Log: ${LOG_CONTENT}. Diff: ${DIFF_CONTENT}. Max 3 hypotheses, one sentence each"
      ;;
    reconfirm)
      PRIOR_CONTENT="$(_read_or_literal "$PRIOR_VERDICT")"
      MISSION="re-review your prior verdict (${PRIOR_CONTENT}): APPROVE or REVISE with 1-sentence reason"
      ;;
  esac
fi

# Test-mode short-circuit: set LEADV2_TEST_MODE=1 to skip codex dispatch.
if [[ "${LEADV2_TEST_MODE:-0}" == "1" ]]; then
  echo "[leadv2-codex-planner] TEST_MODE: mission loaded (${#MISSION} chars), skipping dispatch"
  exit 0
fi

PROJECT_ROOT="${PROJECT_ROOT:-$(pwd)}"
HANDOFF_DIR="$PROJECT_ROOT/docs/handoff/$TASK_ID"
mkdir -p "$HANDOFF_DIR"

PROMPT_FILE="/tmp/codex-plan-${TASK_ID}.md"

if [[ "$MODE" == "plan" ]]; then
  cat > "$PROMPT_FILE" <<EOF
Outcome: a 2nd-opinion plan for the task below, ready for the lead orchestrator to synthesize against an Opus architect's plan.

Mission: $MISSION

Deliver these sections, in this order, plain paragraphs (no headings unless they aid scanning):

1. Three approach options labeled A/B/C — each one sentence, with effort (S/M/L), risk (Low/Med/High), best case, worst case.
2. Recommended option with a one-paragraph rationale grounded in the mission.
3. Top 3 risks for the recommendation, each paired with a concrete mitigation.
4. Rollback plan if the change ships and degrades production.
5. Likely-touched file paths (be specific when inferable; otherwise say "unknown — needs discovery").

Decision rules:
- Review changes for correctness, security, and performance.
- Propose an architectural rewrite only when the mission cannot be met without one.
- Stop and surface a clarifying question instead of guessing when the mission underspecifies success criteria.

text.verbosity: low.
EOF
else
  # Non-plan modes: short mode-specific prompt assembled above (no 5-section plan boilerplate).
  cat > "$PROMPT_FILE" <<EOF
$MISSION

text.verbosity: low.
EOF
fi

STARTED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

if ! command -v gtimeout >/dev/null 2>&1 && ! command -v timeout >/dev/null 2>&1; then
  echo "[leadv2-codex-planner] WARN: no timeout binary (gtimeout/timeout) — --wait path unbounded" >&2
fi

if [[ "$WAIT" == "1" ]]; then
  # Synchronous path: block until codex completes, write findings to a file.
  # `task` is synchronous by default; no --wait flag needed (nor accepted by codex-companion).
  FINDINGS_FILE="${OUT_FILE:-$HANDOFF_DIR/codex-plan-output.txt}"
  CODEX_ARGS=(task --effort "$EFFORT")
  CODEX_ARGS+=("$(cat "$PROMPT_FILE")")
  DISPATCH_EXIT=0
  ~/.claude/scripts/codex-task.sh "${CODEX_ARGS[@]}" > "$FINDINGS_FILE" 2>&1 || DISPATCH_EXIT=$?
  if [[ $DISPATCH_EXIT -ne 0 ]]; then
    echo "[leadv2-codex-planner] ERROR: codex-task.sh --wait failed (exit $DISPATCH_EXIT):" >&2
    head -10 "$FINDINGS_FILE" >&2
    exit "$DISPATCH_EXIT"
  fi
  cat > "$HANDOFF_DIR/codex-plan.json" <<EOF
{
  "mode": "wait",
  "findings_file": "$FINDINGS_FILE",
  "started_at": "$STARTED_AT",
  "effort": "$EFFORT",
  "model": "default",
  "prompt_file": "$PROMPT_FILE"
}
EOF
  # Emit findings file path so callers can: cx-tail.sh <path>
  echo "$FINDINGS_FILE"
else
  # Async path (original behaviour): dispatch background job, emit job ID.
  CODEX_ARGS=(task --background --effort "$EFFORT")
  CODEX_ARGS+=("$(cat "$PROMPT_FILE")")
  OUT=$(~/.claude/scripts/codex-task.sh "${CODEX_ARGS[@]}" 2>&1)
  DISPATCH_EXIT=$?
  # PO-LEADV2-001 R4 H3: fail-closed on dispatch exit BEFORE attempting to
  # parse — error output may contain noise that matches the slug pattern.
  if [[ $DISPATCH_EXIT -ne 0 ]]; then
    echo "[leadv2-codex-planner] ERROR: codex-task.sh dispatch failed (exit $DISPATCH_EXIT):" >&2
    echo "$OUT" | head -10 >&2
    exit "$DISPATCH_EXIT"
  fi
  # Stricter slug match: real Codex IDs follow {task,review,job}-XXXXXXXX-YYYYYY
  # where each segment is base36-like (lowercase alnum), 6-12 chars. This rejects
  # unrelated tokens like `task-id`, `task-list`, `job-name`.
  JOB_ID=$(echo "$OUT" | grep -oE '(task|review|job)-[a-z0-9]{6,12}-[a-z0-9]{4,12}' | head -1 || true)
  if [[ -z "${JOB_ID:-}" ]]; then
    echo "[leadv2-codex-planner] ERROR: dispatched but could not parse task ID from codex-task.sh output:" >&2
    echo "$OUT" | head -10 >&2
    exit 2
  fi
  cat > "$HANDOFF_DIR/codex-plan.json" <<EOF
{
  "job_id": "$JOB_ID",
  "started_at": "$STARTED_AT",
  "effort": "$EFFORT",
  "model": "default",
  "prompt_file": "$PROMPT_FILE"
}
EOF
  echo "$JOB_ID"
fi
