#!/usr/bin/env bash
# leadv2-causal-analyze.sh — Causal incident linking: find probable cause for a RECOVERY-/REGRESSION- task.
#
# Usage:
#   leadv2-causal-analyze.sh --regression-task <task-id>
#   leadv2-causal-analyze.sh --causal-log              # print last 10 entries
#
# Output:
#   Appends entry to docs/leadv2-causal-log.yaml
#   Prints caused_by YAML block to stdout (for injection into recovery/reflect)
#
# Exit codes:
#   0 = cause found (score >= threshold)
#   1 = cause unknown (no candidate met threshold, or lookup failed)
#   2 = usage error

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=leadv2-helpers.sh
source "${SCRIPT_DIR}/leadv2-helpers.sh" || { echo "FATAL: cannot source leadv2-helpers.sh" >&2; exit 1; }

PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
CAUSAL_LOG="${PROJECT_ROOT}/docs/leadv2-causal-log.yaml"
HANDOFF_DIR="${PROJECT_ROOT}/docs/handoff"
CAUSAL_THRESHOLD="${CAUSAL_THRESHOLD:-0.3}"
GIT_LOOKBACK_DAYS="${GIT_LOOKBACK_DAYS:-14}"
GIT_TIMEOUT="${GIT_TIMEOUT:-60}"

# ── Logging ────────────────────────────────────────────────────────────────────
log()       { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }
log_warn()  { log "WARN: $*"; }
log_error() { log "ERROR: $*"; }

# ── Argument parsing ───────────────────────────────────────────────────────────
REGRESSION_TASK=""
SHOW_LOG=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --regression-task)
      [[ -z "${2:-}" ]] && { log_error "--regression-task requires a value"; exit 2; }
      REGRESSION_TASK="$2"; shift 2 ;;
    --causal-log)
      SHOW_LOG=1; shift ;;
    -h|--help)
      grep '^#' "$0" | head -20 | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *)
      log_error "Unknown argument: $1"; exit 2 ;;
  esac
done

# ── Show log mode ──────────────────────────────────────────────────────────────
if [[ "$SHOW_LOG" -eq 1 ]]; then
  if [[ ! -f "$CAUSAL_LOG" ]]; then
    echo "(causal log is empty — $CAUSAL_LOG does not exist)"
    exit 0
  fi
  python3 - "$CAUSAL_LOG" <<'PY'
import sys, yaml
with open(sys.argv[1]) as fh:
    entries = yaml.safe_load(fh) or []
# Last 10 in reverse-chronological order
for entry in reversed(entries[-10:]):
    cause = entry.get("cause_task") or "(unknown)"
    score = entry.get("causality_score", 0)
    ts    = entry.get("timestamp", "")
    effect = entry.get("effect_task", "")
    mech  = entry.get("mechanism", "")
    unknown = entry.get("cause_unknown", False)
    flag = " [CAUSE UNKNOWN]" if unknown else ""
    print(f"  {ts[:10]}  {effect} ← {cause}  score={score:.2f}{flag}")
    if mech:
        print(f"    {mech}")
PY
  exit 0
fi

# ── Validate task argument ─────────────────────────────────────────────────────
if [[ -z "$REGRESSION_TASK" ]]; then
  log_error "Provide --regression-task <task-id> or --causal-log"
  exit 2
fi

HANDOFF_PATH="${HANDOFF_DIR}/${REGRESSION_TASK}"

# ── Read context.yaml / diff.md to find changed files ─────────────────────────
log "Analyzing effect task: $REGRESSION_TASK"

CHANGED_FILES=()

CONTEXT_YAML="${HANDOFF_PATH}/context.yaml"
DIFF_MD="${HANDOFF_PATH}/diff.md"

if [[ -f "$CONTEXT_YAML" ]]; then
  mapfile -t CHANGED_FILES < <(python3 - "$CONTEXT_YAML" <<'PY'
import sys, yaml
with open(sys.argv[1]) as fh:
    ctx = yaml.safe_load(fh) or {}
gf = ctx.get("graph_footprint") or {}
files = gf.get("changed_files") or []
# Also derive from modified_symbols (module path component before first ':')
for sym in (gf.get("modified_symbols") or []):
    part = sym.split(":")[0].replace(".", "/")
    # Try common extensions
    for ext in (".py", ".ts", ".js"):
        files.append(part + ext)
for f in sorted(set(files)):
    if f.strip():
        print(f.strip())
PY
  )
fi

if [[ ${#CHANGED_FILES[@]} -eq 0 && -f "$DIFF_MD" ]]; then
  log "context.yaml missing changed_files — falling back to diff.md"
  mapfile -t CHANGED_FILES < <(grep -oP '^[+]{3} b/\K[^\s]+' "$DIFF_MD" 2>/dev/null | sort -u || true)
fi

# ── Resolve blame reference commit ────────────────────────────────────────────
# Prefer context.yaml.deploy_gate.commit_hash (the actual deployed SHA) over HEAD.
# Using HEAD can blame unrelated subsequent commits. Fallback to HEAD with WARN.
BLAME_REF=""
if [[ -f "$CONTEXT_YAML" ]]; then
  BLAME_REF=$(python3 - "$CONTEXT_YAML" <<'PY'
import sys, yaml
with open(sys.argv[1]) as fh:
    ctx = yaml.safe_load(fh) or {}
deploy_gate = ctx.get("deploy_gate") or {}
sha = (deploy_gate.get("commit_hash") or "").strip()
print(sha)
PY
  )
fi

if [[ -z "$BLAME_REF" ]]; then
  BLAME_REF=$(git -C "$PROJECT_ROOT" rev-parse HEAD 2>/dev/null || echo "")
  log_warn "deploy_gate.commit_hash not found in context.yaml — falling back to HEAD ($BLAME_REF) for blame analysis; results may include post-deploy commits"
else
  log "Using deploy commit for blame analysis: $BLAME_REF"
fi

if [[ ${#CHANGED_FILES[@]} -eq 0 ]]; then
  log_warn "No changed files found for $REGRESSION_TASK — cause_unknown"
  CAUSE_UNKNOWN=true
  CAUSE_TASK="null"
  SCORE="0"
  BLAME_PCT=0
  TEMPORAL_DAYS=0
  MECHANISM="No changed files identified in handoff artifacts"
  COUNTERFACTUAL="Insufficient data for counterfactual"
else
  log "Changed files (${#CHANGED_FILES[@]}): ${CHANGED_FILES[*]}"

  # ── Gather candidate commits ───────────────────────────────────────────────────
  declare -A CANDIDATE_SCORE   # task_id -> score
  declare -A CANDIDATE_BLAME   # task_id -> blame_overlap_pct
  declare -A CANDIDATE_DAYS    # task_id -> temporal_days
  declare -A CANDIDATE_FILE    # task_id -> first file matched

  for file in "${CHANGED_FILES[@]}"; do
    # Only process files that exist in the repo
    if ! git -C "$PROJECT_ROOT" ls-files --error-unmatch "$file" &>/dev/null 2>&1; then
      continue
    fi

    # Find recent commits on this file with task-id references
    # Prefer deploy_gate.commit_hash from context.yaml if available (more precise than HEAD)
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      hash="${line%% *}"
      subject="${line#* }"

      # Extract task-id from subject: pattern like NIK-42, PO-001, RECOVERY-05
      task_id=""
      if [[ "$subject" =~ ([A-Z]+-[0-9]+) ]]; then
        task_id="${BASH_REMATCH[1]}"
      fi
      [[ -z "$task_id" ]] && continue
      # Skip if task_id is the effect task itself
      [[ "$task_id" == "$REGRESSION_TASK" ]] && continue

      # Compute age_days
      commit_ts=$(git -C "$PROJECT_ROOT" show -s --format='%ct' "$hash" 2>/dev/null || echo "0")
      now_ts=$(date +%s)
      age_days=$(( (now_ts - commit_ts) / 86400 ))

      # Compute temporal proximity weight (linear decay over 14 days)
      temporal_weight=$(python3 -c "print(max(0.0, 1.0 - $age_days / $GIT_LOOKBACK_DAYS))")

      # Compute blame overlap for this file at deploy commit (or HEAD fallback — see WARN above)
      blame_lines=0
      total_lines=0
      if timeout "$GIT_TIMEOUT" git -C "$PROJECT_ROOT" blame --porcelain "$BLAME_REF" -- "$file" &>/dev/null 2>&1; then
        total_lines=$(timeout "$GIT_TIMEOUT" git -C "$PROJECT_ROOT" blame --porcelain "$BLAME_REF" -- "$file" 2>/dev/null \
          | grep -c '^[0-9a-f]\{40\}' || true) # bash-guard: allow
        blame_lines=$(timeout "$GIT_TIMEOUT" git -C "$PROJECT_ROOT" blame --porcelain "$BLAME_REF" -- "$file" 2>/dev/null \
          | grep "^${hash}" | wc -l | xargs || true) # bash-guard: allow
      fi

      if [[ "$total_lines" -gt 0 ]]; then
        overlap_pct=$(python3 -c "print(round($blame_lines / $total_lines * 100, 1))")
      else
        overlap_pct=0
      fi

      score=$(python3 -c "print(round(($overlap_pct / 100) * 0.7 + $temporal_weight * 0.3, 3))")

      # Keep highest score per task_id
      existing="${CANDIDATE_SCORE[$task_id]:-0}"
      better=$(python3 -c "print('yes' if $score > $existing else 'no')")
      if [[ "$better" == "yes" ]]; then
        CANDIDATE_SCORE[$task_id]="$score"
        CANDIDATE_BLAME[$task_id]="$overlap_pct"
        CANDIDATE_DAYS[$task_id]="$age_days"
        CANDIDATE_FILE[$task_id]="$file"
      fi

    done < <(timeout "$GIT_TIMEOUT" git -C "$PROJECT_ROOT" log \
      --since="${GIT_LOOKBACK_DAYS} days ago" \
      --oneline \
      --follow \
      -- "$file" 2>/dev/null || true)
  done

  # ── Pick best candidate ──────────────────────────────────────────────────────
  BEST_TASK=""
  BEST_SCORE="0"

  for task_id in "${!CANDIDATE_SCORE[@]}"; do
    s="${CANDIDATE_SCORE[$task_id]}"
    better=$(python3 -c "print('yes' if $s > $BEST_SCORE else 'no')")
    if [[ "$better" == "yes" ]]; then
      BEST_SCORE="$s"
      BEST_TASK="$task_id"
    fi
  done

  meets_threshold=$(python3 -c "print('yes' if $BEST_SCORE >= $CAUSAL_THRESHOLD else 'no')")

  if [[ "$meets_threshold" == "yes" && -n "$BEST_TASK" ]]; then
    CAUSE_UNKNOWN=false
    CAUSE_TASK="$BEST_TASK"
    SCORE="$BEST_SCORE"
    BLAME_PCT="${CANDIDATE_BLAME[$BEST_TASK]:-0}"
    TEMPORAL_DAYS="${CANDIDATE_DAYS[$BEST_TASK]:-0}"
    BEST_FILE="${CANDIDATE_FILE[$BEST_TASK]:-unknown}"
    MECHANISM="${BEST_TASK} modified ${BEST_FILE}; ${REGRESSION_TASK} caught regression in same location"
    COUNTERFACTUAL="If ${BEST_TASK} had included defensive checks in ${BEST_FILE}, ${REGRESSION_TASK} may not have occurred"
    log "Probable cause: $CAUSE_TASK (score=$SCORE, blame=${BLAME_PCT}%, days_ago=${TEMPORAL_DAYS})"
  else
    CAUSE_UNKNOWN=true
    CAUSE_TASK="null"
    SCORE="0"
    BLAME_PCT=0
    TEMPORAL_DAYS=0
    MECHANISM="No candidate met causality threshold (${CAUSAL_THRESHOLD})"
    COUNTERFACTUAL="Insufficient causal signal for counterfactual"
    log_warn "No probable cause found (best score=$BEST_SCORE below threshold $CAUSAL_THRESHOLD)"
  fi
fi

# ── Compute impact window ──────────────────────────────────────────────────────
IMPACT_WINDOW="t+unknown"
if [[ "$TEMPORAL_DAYS" -gt 0 ]]; then
  IMPACT_WINDOW="t+$((TEMPORAL_DAYS * 24))h"
fi

# ── Write causal log entry ─────────────────────────────────────────────────────
TIMESTAMP=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

# Initialize file if missing
if [[ ! -f "$CAUSAL_LOG" ]]; then
  printf -- '---\n# leadv2-causal-log.yaml — append-only causal incident log\n# Do not delete or modify existing entries.\n' > "$CAUSAL_LOG"
fi

causal_yaml=$(python3 - "$CAUSAL_LOG" "$TIMESTAMP" "$REGRESSION_TASK" "$CAUSE_TASK" \
  "$SCORE" "$BLAME_PCT" "$TEMPORAL_DAYS" "$MECHANISM" "$IMPACT_WINDOW" \
  "$COUNTERFACTUAL" "$CAUSE_UNKNOWN" <<'PY'
import sys, yaml, io

log_path, ts, effect, cause, score, blame, days, mech, window, cf, unknown = sys.argv[1:]

with open(log_path) as fh:
    content = fh.read()

# Read existing list (strip YAML header comments)
lines = [l for l in content.splitlines() if not l.startswith('#') and l.strip() != '---']
existing = yaml.safe_load('\n'.join(lines)) or []

entry = {
    "timestamp":          ts,
    "effect_task":        effect,
    "cause_task":         None if cause == "null" else cause,
    "causality_score":    round(float(score), 2),
    "blame_overlap_pct":  int(blame),
    "temporal_days":      int(days),
    "mechanism":          mech,
    "impact_window":      window,
    "counterfactual_note": cf,
    "cause_unknown":      unknown == "true",
}
existing.append(entry)

try:
    _buf = io.StringIO()
    _buf.write('---\n# leadv2-causal-log.yaml — append-only causal incident log\n# Do not delete or modify existing entries.\n')
    yaml.dump(existing, _buf, default_flow_style=False, allow_unicode=True, sort_keys=False)
    sys.stdout.write(_buf.getvalue())
    print("Log entry written.", file=sys.stderr)
except Exception as exc:
    print(f"ERROR: yaml.dump failed: {exc}", file=sys.stderr)
    raise
PY
)
if [[ -z "$causal_yaml" ]]; then
  log_warn "causal analysis produced empty output, skipping log write"
  exit 1
fi
_atomic_write_yaml "$CAUSAL_LOG" "$causal_yaml"
log "Causal log updated: $CAUSAL_LOG"

# ── Print caused_by block to stdout ───────────────────────────────────────────
python3 - "$CAUSE_TASK" "$SCORE" "$IMPACT_WINDOW" "$MECHANISM" "$CAUSE_UNKNOWN" <<'PY'
import sys
cause, score, window, lesson, unknown = sys.argv[1:]
print("caused_by:")
print(f"  task_id: {None if cause == 'null' else cause}")
print(f"  causality_score: {float(score):.2f}")
print(f"  detected_at: {window}")
print(f"  lesson: \"{lesson}\"")
print(f"  cause_unknown: {unknown == 'true'}")
PY

# Exit 0 if cause found, 1 if cause_unknown
[[ "$CAUSE_UNKNOWN" == "false" ]] && exit 0 || exit 1
