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

  --mission "<text>"     Inline mission text (passed directly via CLI).
  --mission-file <path>  Path to mission file; read early for race protection.
                         Mutually exclusive with --mission.

Codex model is the codex-companion default (gpt-5.5 on plugin >=1.0.4).
The --model flag is intentionally not exposed; spark is banned project-wide.
EOF
  exit 1
}

TASK_ID=""; MISSION=""; MISSION_FILE=""; EFFORT="high"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --task-id)      TASK_ID="$2"; shift 2 ;;
    --mission)      MISSION="$2"; shift 2 ;;
    --mission-file) MISSION_FILE="$2"; shift 2 ;;
    --effort)       EFFORT="$2"; shift 2 ;;
    --model)
      echo "[leadv2-codex-planner] --model is no longer accepted (gpt-5.5 default, spark banned)" >&2
      usage
      ;;
    *) echo "[leadv2-codex-planner] unknown arg: $1" >&2; usage ;;
  esac
done

# Validate: task-id required; exactly one of --mission / --mission-file required.
[[ -z "$TASK_ID" ]] && { echo "[leadv2-codex-planner] --task-id is required" >&2; usage; }
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

# Test-mode short-circuit: set LEADV2_TEST_MODE=1 to skip codex dispatch.
if [[ "${LEADV2_TEST_MODE:-0}" == "1" ]]; then
  echo "[leadv2-codex-planner] TEST_MODE: mission loaded (${#MISSION} chars), skipping dispatch"
  exit 0
fi

PROJECT_ROOT="${PROJECT_ROOT:-$(pwd)}"
HANDOFF_DIR="$PROJECT_ROOT/docs/handoff/$TASK_ID"
mkdir -p "$HANDOFF_DIR"

PROMPT_FILE="/tmp/codex-plan-${TASK_ID}.md"

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

STARTED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

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
