#!/usr/bin/env bash
set -euo pipefail
# leadv2-build-feedback.sh — emit a compact diff-only feedback prompt for a failed build round.
#
# Usage:
#   leadv2-build-feedback.sh --task-id <id> --previous-attempt <n>
#
# Output (stdout): compact re-prompt containing previous summary + diff + failure reason.
# Falls back to tail of full context if diff generation fails.
#
# Files read:
#   docs/handoff/<id>/developer.summary.md  — previous round summary
#   docs/handoff/<id>/developer.full.md     — previous round full output (for failure reason)
#   docs/handoff/<id>/build-attempt-<n>.diff — explicit diff file if present
#   git diff (fallback)

PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"

log()      { printf '[leadv2-build-feedback] %s\n' "$*" >&2; }
log_warn() { printf '[leadv2-build-feedback] WARN: %s\n' "$*" >&2; }

usage() {
  printf 'Usage: leadv2-build-feedback.sh --task-id <id> --previous-attempt <n>\n' >&2
  exit 1
}

TASK_ID=""; PREV_ATTEMPT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --task-id)           TASK_ID="$2";        shift 2 ;;
    --previous-attempt)  PREV_ATTEMPT="$2";   shift 2 ;;
    *) log_warn "unknown arg: $1"; usage ;;
  esac
done

[[ -z "$TASK_ID" || -z "$PREV_ATTEMPT" ]] && usage

HANDOFF_DIR="${PROJECT_ROOT}/docs/handoff/${TASK_ID}"

# Extract previous summary (≤80 words)
PREV_SUMMARY=""
SUMMARY_FILE="${HANDOFF_DIR}/developer.summary.md"
if [[ -f "$SUMMARY_FILE" ]]; then
  PREV_SUMMARY=$(python3 - "$SUMMARY_FILE" <<'PY' 2>/dev/null || true
import sys
lines = open(sys.argv[1]).read().strip()
words = lines.split()
# Truncate to 80 words
print(" ".join(words[:80]))
PY
)
fi

# Extract failure reason from full deliverable (last non-empty lines before DELIVERABLE_COMPLETE)
FAILURE_REASON=""
FULL_FILE="${HANDOFF_DIR}/developer.full.md"
if [[ -f "$FULL_FILE" ]]; then
  FAILURE_REASON=$(python3 - "$FULL_FILE" <<'PY' 2>/dev/null || true
import sys, re
content = open(sys.argv[1]).read()
# Look for explicit failure/error section
for pattern in (r'(?im)^#+\s*(failure|error|issue|problem|why.*fail)[^\n]*\n((?:.+\n?){1,8})',
                r'(?im)^(FAIL|ERROR|ISSUE|PROBLEM)[^\n]*\n((?:.+\n?){1,5})'):
    m = re.search(pattern, content)
    if m:
        print(m.group(0).strip()[:400])
        sys.exit(0)
# Fallback: last 5 non-empty lines before DELIVERABLE_COMPLETE
lines = [l for l in content.splitlines() if l.strip() and "DELIVERABLE_COMPLETE" not in l]
print("\n".join(lines[-5:])[:400])
PY
)
fi

# Generate diff: prefer explicit attempt diff file, then git diff
DIFF_CONTENT=""
EXPLICIT_DIFF="${HANDOFF_DIR}/build-attempt-${PREV_ATTEMPT}.diff"

if [[ -f "$EXPLICIT_DIFF" ]]; then
  DIFF_CONTENT=$(python3 -c "import sys; content=open(sys.argv[1]).read(); print(content[:3000])" "$EXPLICIT_DIFF" 2>/dev/null || true) # bash-guard: allow
  log "using explicit attempt diff: ${EXPLICIT_DIFF}"
else
  # Try git diff from task start SHA stored in context.yaml
  CONTEXT_YAML="${HANDOFF_DIR}/context.yaml"
  START_SHA=""
  if [[ -f "$CONTEXT_YAML" ]]; then
    START_SHA=$(python3 - "$CONTEXT_YAML" <<'PY' 2>/dev/null || true
import sys, yaml
data = yaml.safe_load(open(sys.argv[1])) or {}
print(data.get("task_start_sha") or data.get("start_sha") or "")
PY
)
  fi

  if [[ -n "$START_SHA" ]]; then
    DIFF_CONTENT=$(git -C "$PROJECT_ROOT" diff "${START_SHA}..HEAD" -- 2>/dev/null | head -200 | python3 -c "import sys; print(sys.stdin.read()[:3000])" 2>/dev/null || true) # bash-guard: allow
    log "generated git diff from ${START_SHA}..HEAD"
  fi
fi

# Fallback: if no diff, emit tail of previous full deliverable
if [[ -z "$DIFF_CONTENT" ]]; then
  log_warn "diff generation failed — falling back to tail of previous deliverable"
  if [[ -f "$FULL_FILE" ]]; then
    DIFF_CONTENT=$(python3 - "$FULL_FILE" <<'PY' 2>/dev/null || true
import sys
lines = open(sys.argv[1]).readlines()
# Last 40 lines, skip DELIVERABLE_COMPLETE
filtered = [l for l in lines if "DELIVERABLE_COMPLETE" not in l]
print("".join(filtered[-40:])[:2000])
PY
)
    DIFF_CONTENT="[DIFF UNAVAILABLE — showing tail of previous output]
${DIFF_CONTENT}"
  else
    DIFF_CONTENT="[DIFF UNAVAILABLE — no previous deliverable found]"
  fi
fi

# Emit compact re-prompt
cat <<PROMPT
## Build feedback (attempt ${PREV_ATTEMPT} failed — diff-only context)

**Previous attempt summary (≤80w):**
${PREV_SUMMARY:-[no summary available]}

**Diff since task start:**
\`\`\`diff
${DIFF_CONTENT}
\`\`\`

**Failure reason:**
${FAILURE_REASON:-[failure reason not extracted — review previous output]}

**Fix request:** Address the failure above. Do NOT re-send full file context. Apply targeted fix only.
Context: docs/handoff/${TASK_ID}/context.yaml — re-read decisions and off_limits before proceeding.
PROMPT
