#!/bin/bash
# critic-tail.sh — token-efficient view of critic / codex / security-auditor deliverable.
# Mirrors ~/.claude/scripts/cx-tail.sh pattern.
#
# Output (always): Verdict line, summary_for_lead line, Critical/High/Medium counts.
# Output (only if Verdict ≠ APPROVE): first 50 body lines.
#
# Usage: critic-tail.sh <deliverable-file>

set -euo pipefail

file="${1:?usage: $0 <deliverable-file>}"
[[ -f "$file" ]] || { echo "[critic-tail] missing: $file" >&2; exit 1; }

verdict=$(grep -m1 -iE '^Verdict:' "$file" 2>/dev/null || echo "Verdict: <missing>")
summary=$(grep -m1 -iE '^summary_for_lead:' "$file" 2>/dev/null || echo "summary_for_lead: <missing>")

# Severity counts — match the shapes used by critic-Opus, codex, security-auditor
crit=$(grep -ciE '^[[:space:]]*(critical|c[0-9]+:|severity: critical)' "$file" 2>/dev/null || echo 0)
high=$(grep -ciE '^[[:space:]]*(high|h[0-9]+:|severity: high)' "$file" 2>/dev/null || echo 0)
med=$(grep -ciE '^[[:space:]]*(medium|m[0-9]+:|severity: medium)' "$file" 2>/dev/null || echo 0)

# Strip newlines from grep -c piped through subshell.
crit=$(printf '%s' "$crit" | tr -dc '0-9'); crit="${crit:-0}"
high=$(printf '%s' "$high" | tr -dc '0-9'); high="${high:-0}"
med=$(printf '%s' "$med" | tr -dc '0-9'); med="${med:-0}"

echo "$verdict"
echo "$summary"
echo "counts: critical=$crit high=$high medium=$med"

# If verdict signals revise/no-ship, surface body context (first 50 lines after the header).
if echo "$verdict" | grep -qiE 'revise|no.?ship|reject|fail|block'; then
  echo "---"
  head -50 "$file"
fi
