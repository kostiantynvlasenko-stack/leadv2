#!/usr/bin/env bash
set -euo pipefail
# leadv2-recovery-context.sh — emit compact recovery context for attempt 2+.
#
# Usage:
#   leadv2-recovery-context.sh --task-id <id> --attempt <n>
#
# Reads:
#   docs/handoff/<id>/rollback.md        — previous recovery attempts log
#   docs/handoff/<id>/architect.md       — architect decision from attempt 1
#   docs/handoff/<id>/context.yaml       — task classification + original mission
#   git diff (regression vs attempt-1)
#
# Writes:
#   docs/handoff/<id>/recovery-full.md   — full incident log archived for audit
#
# Stdout: compact RECOVERY-CONTEXT block (for injection into attempt-2 architect brief)

PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"

log()      { printf '[leadv2-recovery-context] %s\n' "$*" >&2; }
log_warn() { printf '[leadv2-recovery-context] WARN: %s\n' "$*" >&2; }

usage() {
  printf 'Usage: leadv2-recovery-context.sh --task-id <id> --attempt <n>\n' >&2
  exit 1
}

TASK_ID=""; ATTEMPT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --task-id) TASK_ID="$2";  shift 2 ;;
    --attempt) ATTEMPT="$2";  shift 2 ;;
    *) log_warn "unknown arg: $1"; usage ;;
  esac
done

[[ -z "$TASK_ID" || -z "$ATTEMPT" ]] && usage

HANDOFF_DIR="${PROJECT_ROOT}/docs/handoff/${TASK_ID}"

# Parse context.yaml for classification and original mission
CLASSIFICATION="Unknown"
ORIGINAL_TASK_ID="$TASK_ID"
CONTEXT_YAML="${HANDOFF_DIR}/context.yaml"
if [[ -f "$CONTEXT_YAML" ]]; then
  CLASSIFICATION=$(python3 - "$CONTEXT_YAML" <<'PY' 2>/dev/null || printf 'Unknown'
import sys, yaml
data = yaml.safe_load(open(sys.argv[1])) or {}
print(data.get("classification") or data.get("task_class") or "Unknown")
PY
)
fi

# Extract attempt-1 approach (architect.md decision + rationale, 2 sentences)
ATTEMPT1_APPROACH=""
ARCHITECT_FILE="${HANDOFF_DIR}/architect.md"
if [[ -f "$ARCHITECT_FILE" ]]; then
  ATTEMPT1_APPROACH=$(python3 - "$ARCHITECT_FILE" <<'PY' 2>/dev/null || true
import sys, re
content = open(sys.argv[1]).read()
# Extract decision line
decision = ""
m = re.search(r'(?im)^decision:\s*(.+)', content)
if m: decision = m.group(1).strip()
# Extract first 2 sentences of rationale
rationale = ""
m = re.search(r'(?im)^rationale:\s*(.+?)(?=\n[a-z]|\Z)', content, re.DOTALL)
if m:
    text = m.group(1).strip()
    sentences = re.split(r'(?<=[.!?])\s+', text)
    rationale = " ".join(sentences[:2])
if decision:
    print(f"Decision: {decision}. {rationale}"[:300])
else:
    # Fallback: first 300 chars of content
    print(content[:300].strip())
PY
)
fi

# Extract attempt-1 failure (one sentence from rollback.md)
ATTEMPT1_FAILURE=""
ROLLBACK_FILE="${HANDOFF_DIR}/rollback.md"
if [[ -f "$ROLLBACK_FILE" ]]; then
  ATTEMPT1_FAILURE=$(python3 - "$ROLLBACK_FILE" <<'PY' 2>/dev/null || true
import sys, re
content = open(sys.argv[1]).read()
# Look for failure description near attempt 1
for pattern in (r'(?im)attempt.1.*?fail[^\n]*\n([^\n]+)',
                r'(?im)^failure[^\n]*\n([^\n]+)',
                r'(?im)^error[^\n]*\n([^\n]+)'):
    m = re.search(pattern, content)
    if m:
        candidate = m.group(1).strip()
        if len(candidate) > 10:
            print(candidate[:200])
            sys.exit(0)
# Fallback: last non-empty line
lines = [l.strip() for l in content.splitlines() if l.strip()]
if lines:
    print(lines[-1][:200])
PY
)
fi

# One-paragraph regression summary from rollback.md or architect
REGRESSION_SUMMARY=""
if [[ -f "$ROLLBACK_FILE" ]]; then
  REGRESSION_SUMMARY=$(python3 - "$ROLLBACK_FILE" <<'PY' 2>/dev/null || true
import sys
content = open(sys.argv[1]).read().strip()
words = content.split()
# First 80 words as summary paragraph
print(" ".join(words[:80]))
PY
)
fi
if [[ -z "$REGRESSION_SUMMARY" && -f "$ARCHITECT_FILE" ]]; then
  REGRESSION_SUMMARY=$(python3 - "$ARCHITECT_FILE" <<'PY' 2>/dev/null || true
import sys
content = open(sys.argv[1]).read().strip()
words = content.split()
print(" ".join(words[:80]))
PY
)
fi

# Generate diff between original-broken state and attempt-1 outcome
REGRESSION_DIFF=""
# Look for explicit patch files in handoff
RECOVERY_DIFF_FILE="${HANDOFF_DIR}/recovery-attempt-1.diff"
if [[ -f "$RECOVERY_DIFF_FILE" ]]; then
  REGRESSION_DIFF=$(python3 -c "import sys; print(open(sys.argv[1]).read()[:2000])" "$RECOVERY_DIFF_FILE" 2>/dev/null || true) # bash-guard: allow
else
  # Try git diff of last 2 commits (approximation: original-broken..after-attempt-1)
  REGRESSION_DIFF=$(git -C "$PROJECT_ROOT" diff HEAD~2..HEAD -- 2>/dev/null | head -150 | python3 -c "import sys; print(sys.stdin.read()[:2000])" 2>/dev/null || true) # bash-guard: allow
fi

if [[ -z "$REGRESSION_DIFF" ]]; then
  REGRESSION_DIFF="[diff unavailable — check git log manually]"
fi

# Next approach suggestion (generic guidance for attempt 2)
NEXT_APPROACH="Attempt 2: prefer rollback to last good state + open RECOVERY-${TASK_ID} tracker task for permanent fix."

# Archive full incident log to recovery-full.md
FULL_LOG="${HANDOFF_DIR}/recovery-full.md"
{
  printf '# Recovery full log — task %s (attempt %s)\n\n' "$TASK_ID" "$ATTEMPT"
  printf '## Classification\n%s\n\n' "$CLASSIFICATION"
  printf '## Attempt 1 approach\n%s\n\n' "${ATTEMPT1_APPROACH:-[not available]}"
  printf '## Attempt 1 failure\n%s\n\n' "${ATTEMPT1_FAILURE:-[not available]}"
  printf '## Regression summary\n%s\n\n' "${REGRESSION_SUMMARY:-[not available]}"
  printf '## Regression diff\n```diff\n%s\n```\n\n' "$REGRESSION_DIFF"
  if [[ -f "$ARCHITECT_FILE" ]]; then
    printf '## Architect decision (attempt 1)\n'
    python3 -c "import sys; print(open(sys.argv[1]).read())" "$ARCHITECT_FILE" 2>/dev/null || true # bash-guard: allow
    printf '\n'
  fi
  if [[ -f "$ROLLBACK_FILE" ]]; then
    printf '## Rollback log\n'
    python3 -c "import sys; print(open(sys.argv[1]).read())" "$ROLLBACK_FILE" 2>/dev/null || true # bash-guard: allow
    printf '\n'
  fi
  printf 'Generated: %s\n' "$(date -u +%FT%TZ)"
} > "$FULL_LOG" 2>/dev/null || log_warn "could not write recovery-full.md"

log "archived full incident log: ${FULL_LOG}"

# Emit compact RECOVERY-CONTEXT
cat <<CONTEXT
RECOVERY-CONTEXT (compact)
Original task: ${ORIGINAL_TASK_ID}
Classification: ${CLASSIFICATION}
Regression: ${REGRESSION_SUMMARY:-[see rollback.md]}
Attempt 1 approach: ${ATTEMPT1_APPROACH:-[not available]}
Attempt 1 failure: ${ATTEMPT1_FAILURE:-[not available]}
Diff between original-broken and attempt-1:
\`\`\`diff
${REGRESSION_DIFF}
\`\`\`
Next approach requested: ${NEXT_APPROACH}

Full incident log archived at: docs/handoff/${TASK_ID}/recovery-full.md
CONTEXT
