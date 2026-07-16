#!/usr/bin/env bash
# scripts/leadv2-fanout-classify.sh — pre-launch task classifier (SUPERVISOR-RETRO-01
# item 1). Replaces fanout's missing-class -> "Standard" silent fallback with an
# explicit risk-keyword scan over the task's intent/tags text. Called once per
# candidate task by scripts/leadv2-fanout.sh before the launch decision is made.
#
# Usage:
#   leadv2-fanout-classify.sh --intent "<text>" [--tags "<csv>"] \
#                              [--existing-class "<Light|Standard|Heavy|Strategic>"]
#
# Output (stdout, KEY=VALUE lines, stable order):
#   launch_class=Light|Standard|Heavy|Strategic
#   risk_tags=<comma-separated matched risk keywords, empty if none>
#   reason=<one-line human reason>
#   lead_model=opus|sonnet
#   lead_effort=high|medium
#
# Exit codes:
#   0 — classified
#   1 — bad usage
#
# Rule (design doc §1, "Risk"): a task carrying ANY safety-adjacent signal must
# classify Heavy even if the signal is ambiguous/partial. Never silently fall
# back to Standard on an unclear safety match — that IS the bug being fixed.

set -euo pipefail

log_error() { printf '[leadv2-fanout-classify] ERROR: %s\n' "$*" >&2; }

INTENT=""
TAGS=""
EXISTING_CLASS=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --intent)         INTENT="$2";         shift 2 ;;
    --tags)           TAGS="$2";           shift 2 ;;
    --existing-class) EXISTING_CLASS="$2"; shift 2 ;;
    *) log_error "unknown arg: $1"; exit 1 ;;
  esac
done

# ---------------------------------------------------------------------------
# Risk keyword table. Matched case-insensitively as whole-word-ish substrings
# against "intent + tags". Grouped so the reported risk_tags name WHICH
# category fired, not just "risky".
# lean: fixed keyword list, no NLP/embedding classifier — upgrade when a
# false-negative on a real Heavy-risk task is observed in fanout-*.md reports.
# ---------------------------------------------------------------------------
declare -A RISK_GROUPS=(
  [auth]="auth|oauth|login|cookie|session token|credential|api key|app_id"
  [rls]="rls|row level security|row-level security|policy|supabase policy"
  [safety]="safety gate|safety-gate|moderation|content policy|harmful"
  [publish]="publish|deploy|prod|production|migration|schema change|ddl|drop table|destructive"
  [security]="security|secret|token|payment|billing|pii|gdpr"
  [arch]="architecture|arch redesign|rearchitect|breaking change|irreversible"
)

# Ambiguity markers: presence alongside ANY risk keyword must still resolve to
# Heavy (never let uncertainty language soften a risk signal into Standard).
AMBIGUITY_RE="maybe|not sure|unclear|investigate|possibly|might touch|could affect"

HAYSTACK="$(printf '%s %s' "$INTENT" "$TAGS" | tr '[:upper:]' '[:lower:]')"

MATCHED_TAGS=()
for group in "${!RISK_GROUPS[@]}"; do
  pattern="${RISK_GROUPS[$group]}"
  if printf '%s' "$HAYSTACK" | grep -Eq "$pattern"; then
    MATCHED_TAGS+=("$group")
  fi
done

RISK_TAGS=""
if [[ "${#MATCHED_TAGS[@]}" -gt 0 ]]; then
  # stable order for reproducible receipts/tests
  RISK_TAGS="$(printf '%s\n' "${MATCHED_TAGS[@]}" | sort | paste -sd, -)"
fi

AMBIGUOUS=false
if [[ -n "$RISK_TAGS" ]] && printf '%s' "$HAYSTACK" | grep -Eq "$AMBIGUITY_RE"; then
  AMBIGUOUS=true
fi

EXISTING_L="$(printf '%s' "$EXISTING_CLASS" | tr '[:upper:]' '[:lower:]')"

LAUNCH_CLASS=""
REASON=""

if [[ "$EXISTING_L" == "heavy" || "$EXISTING_L" == "strategic" ]]; then
  LAUNCH_CLASS="$EXISTING_CLASS"
  REASON="existing class ${EXISTING_CLASS} preserved"
elif [[ -n "$RISK_TAGS" ]]; then
  LAUNCH_CLASS="Heavy"
  if [[ "$AMBIGUOUS" == "true" ]]; then
    REASON="risk keyword(s) [${RISK_TAGS}] with ambiguity language — fail Heavy, never silently Standard"
  else
    REASON="risk keyword(s) matched: ${RISK_TAGS}"
  fi
elif [[ -n "$EXISTING_L" && "$EXISTING_L" != "standard" ]]; then
  # honor an explicit non-Standard, non-Heavy class from tasks.yaml (e.g. Light)
  LAUNCH_CLASS="$EXISTING_CLASS"
  REASON="existing class ${EXISTING_CLASS} preserved (no risk keywords)"
else
  # No explicit class, no risk signal: this IS the "missing-class" fallback
  # path the design doc names. Preserve the existing default (Standard) --
  # the fix here is stopping Heavy-risk tasks from landing here silently
  # (handled by the risk-keyword branch above), not reclassifying benign
  # short tasks to a smaller class than before.
  LAUNCH_CLASS="Standard"
  if [[ -z "$INTENT" ]]; then
    REASON="no intent text available — default Standard"
  else
    REASON="no risk keywords, no existing class — default Standard"
  fi
fi

LAUNCH_CLASS_L="$(printf '%s' "$LAUNCH_CLASS" | tr '[:upper:]' '[:lower:]')"
if [[ "$LAUNCH_CLASS_L" == "heavy" || "$LAUNCH_CLASS_L" == "strategic" ]]; then
  LEAD_MODEL="opus"
  LEAD_EFFORT="high"
else
  LEAD_MODEL="sonnet"
  LEAD_EFFORT="medium"
fi

printf 'launch_class=%s\n' "$LAUNCH_CLASS"
printf 'risk_tags=%s\n' "$RISK_TAGS"
printf 'reason=%s\n' "$REASON"
printf 'lead_model=%s\n' "$LEAD_MODEL"
printf 'lead_effort=%s\n' "$LEAD_EFFORT"
