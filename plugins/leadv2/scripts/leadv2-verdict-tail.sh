#!/usr/bin/env bash
# Extract verdict YAML block from a subagent .summary.md file.
# Lead reads this output instead of reading prose.
#
# Usage: leadv2-verdict-tail.sh <path-to-summary.md>
# Output: verdict block fields, one per line (verdict, next_action, blocking_count, summary_for_lead)

set -euo pipefail
trap 'exit 0' ERR

FILE="${1:-}"
[[ -z "$FILE" || ! -f "$FILE" ]] && { echo "verdict: MISSING_FILE"; exit 1; }

# Extract first YAML block (between --- or just key:value lines at top)
HEAD="$(head -30 "$FILE")"

VERDICT="$(echo "$HEAD" | grep -E '^verdict:' | head -1 | sed 's/^verdict:[ ]*//' | tr -d '"' || echo "UNKNOWN")"
NEXT_ACTION="$(echo "$HEAD" | grep -E '^next_action:' | head -1 | sed 's/^next_action:[ ]*//' | tr -d '"' || echo "UNKNOWN")"
SUMMARY="$(echo "$HEAD" | grep -E '^summary_for_lead:' | head -1 | sed 's/^summary_for_lead:[ ]*//' | tr -d '"' || echo "")"

# Count blocking issues — assumes simple YAML list format
BLOCKING_COUNT="$(awk '/^blocking_issues:/{f=1; next} f && /^[a-z_]+:/{f=0} f && /^[ ]+-/{c++} END{print c+0}' "$FILE" 2>/dev/null || echo "0")"

cat <<EOF
verdict: ${VERDICT:-UNKNOWN}
next_action: ${NEXT_ACTION:-UNKNOWN}
blocking_count: ${BLOCKING_COUNT}
summary_for_lead: ${SUMMARY}
EOF
