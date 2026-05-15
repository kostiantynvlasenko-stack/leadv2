#!/usr/bin/env bash
# leadv2-context-cache.sh
#
# When docs/leadv2/tasks/$TASK_ID/context.yaml (or docs/handoff/$TASK_ID/context.yaml)
# exceeds 200 lines, split its top-level YAML keys into phase-scoped files:
#
#   context.intake.yaml   — keys: task_id, title, class, classification, inputs
#   context.plan.yaml     — keys: plan, approach, plan_*, decisions, scope_decisions*
#   context.gates.yaml    — keys: gate_*, gate_check, verification, off_limits
#   context.review.yaml   — keys: review_*, codex_*, critic_*, reflect, history
#
# The original context.yaml is NEVER modified.
# Idempotent: re-running produces the same output (overwrites phase files).
#
# Skill integration (opt-in):
#   leadv2-build and leadv2-review can read only their phase slice instead of
#   the full context.  To opt in, add to your skill:
#     CONTEXT_FILE="${TASK_DIR}/context.plan.yaml"
#     [ -f "$CONTEXT_FILE" ] || CONTEXT_FILE="${TASK_DIR}/context.yaml"
#
# Usage:
#   leadv2-context-cache.sh <task_id>
#   TASK_DIR=/path/to/task leadv2-context-cache.sh   (override lookup)

set -euo pipefail

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log() { printf -- '[leadv2-context-cache] %s\n' "$*" >&2; }

# ---------------------------------------------------------------------------
# Locate context.yaml
# ---------------------------------------------------------------------------
TASK_ID="${1:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

if [[ -n "${TASK_DIR:-}" ]]; then
  CONTEXT_FILE="${TASK_DIR}/context.yaml"
elif [[ -n "$TASK_ID" ]]; then
  # Try handoff/ first (primary per leadv2 protocol), then tasks/ legacy
  CONTEXT_FILE=""
  for candidate in \
    "${PROJECT_ROOT}/docs/handoff/${TASK_ID}/context.yaml" \
    "${PROJECT_ROOT}/docs/leadv2/tasks/${TASK_ID}/context.yaml"; do
    if [[ -f "$candidate" ]]; then
      CONTEXT_FILE="$candidate"
      break
    fi
  done
  if [[ -z "$CONTEXT_FILE" ]]; then
    log "context.yaml not found for task ${TASK_ID}"
    exit 1
  fi
else
  printf -- 'Usage: %s <task_id>\n' "$(basename "$0")" >&2
  exit 1
fi

TASK_DIR="$(dirname "$CONTEXT_FILE")"

# ---------------------------------------------------------------------------
# Line count check
# ---------------------------------------------------------------------------
line_count=$(wc -l < "$CONTEXT_FILE" | tr -d ' ')
if (( line_count <= 200 )); then
  log "context.yaml is ${line_count} lines (≤200) — no split needed for ${TASK_ID:-$TASK_DIR}"
  exit 0
fi

log "context.yaml is ${line_count} lines — splitting into phase files"

# ---------------------------------------------------------------------------
# Phase-key mapping
# Keys are matched as top-level YAML keys (no leading spaces).
# A key lands in the first phase bucket it matches.
# ---------------------------------------------------------------------------

# Regex patterns for each phase (matched against "^<key>:")
INTAKE_KEYS='^(task_id|title|class|classification|inputs|meta|plan_round|plan_synthesized_by|approach):'
PLAN_KEYS='^(plan|plan_|approach|decisions|scope_decisions|scope_decisions_for_founder|corrections|plan_corrections):'
GATES_KEYS='^(gate|gate_|gate_check|verification|off_limits|guard|constraints):'
REVIEW_KEYS='^(review|codex|critic|reflect|history|incidents|build_summary|outcome|tests|verify):'

# ---------------------------------------------------------------------------
# Python-based YAML splitter (preserves exact text, no YAML parse required)
# Splits by top-level key boundaries (lines with no leading whitespace that
# match "key:" pattern).
# ---------------------------------------------------------------------------
python3 - "$CONTEXT_FILE" "$TASK_DIR" \
  "$INTAKE_KEYS" "$PLAN_KEYS" "$GATES_KEYS" "$REVIEW_KEYS" <<'PYEOF'
import sys
import re
import os

context_file  = sys.argv[1]
task_dir      = sys.argv[2]
intake_pat    = re.compile(sys.argv[3])
plan_pat      = re.compile(sys.argv[4])
gates_pat     = re.compile(sys.argv[5])
review_pat    = re.compile(sys.argv[6])

with open(context_file) as f:
    raw = f.read()

lines = raw.splitlines(keepends=True)

# Detect top-level key boundaries: lines that start with [a-zA-Z_] and contain ':'
# (not inside a block scalar — simplified heuristic, good enough for leadv2 YAML)
def top_level_key(line):
    m = re.match(r'^([a-zA-Z_][a-zA-Z0-9_-]*)\s*:', line)
    return m.group(1) if m else None

# Walk lines, assign each top-level section to a bucket
buckets = {"intake": [], "plan": [], "gates": [], "review": [], "other": []}
current_bucket = "other"
current_block = []

def flush_block(bucket, block):
    buckets[bucket].extend(block)

for line in lines:
    key = top_level_key(line)
    if key:
        # Flush previous block
        flush_block(current_bucket, current_block)
        current_block = [line]
        # Classify new key
        k_colon = key + ":"
        if intake_pat.match(k_colon):
            current_bucket = "intake"
        elif plan_pat.match(k_colon):
            current_bucket = "plan"
        elif gates_pat.match(k_colon):
            current_bucket = "gates"
        elif review_pat.match(k_colon):
            current_bucket = "review"
        else:
            current_bucket = "other"
    else:
        current_block.append(line)

flush_block(current_bucket, current_block)

# Redistribute "other" lines: prepend to intake (e.g. leading comments)
buckets["intake"] = buckets["other"] + buckets["intake"]

phase_map = {
    "intake": "context.intake.yaml",
    "plan":   "context.plan.yaml",
    "gates":  "context.gates.yaml",
    "review": "context.review.yaml",
}

generated = []
for phase, filename in phase_map.items():
    content = "".join(buckets[phase])
    if not content.strip():
        continue
    out_path = os.path.join(task_dir, filename)
    with open(out_path, "w") as f:
        f.write(content)
    line_c = content.count("\n")
    print(f"  wrote {filename} ({line_c} lines)")
    generated.append(filename)

if not generated:
    print("  no phase files generated (all content unclassified)")
    sys.exit(1)
PYEOF

log "Split complete. Original context.yaml unchanged."
