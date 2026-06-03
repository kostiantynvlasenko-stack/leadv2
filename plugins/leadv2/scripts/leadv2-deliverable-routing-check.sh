#!/bin/bash
# leadv2-deliverable-routing-check.sh — block Phase 5 if any group deliverable
# self-flags work for "Group B" or "follow-up" without explicit routing in groups-contract.md.
#
# Usage: leadv2-deliverable-routing-check.sh <handoff-dir>
# Exit 0 = clean. Exit 2 = unresolved routing flag.

set -euo pipefail

dir="${1:?usage: $0 <docs/handoff/<task_id>>}"
[[ -d "$dir" ]] || { echo "[routing-check] missing dir: $dir" >&2; exit 1; }

contract="$dir/groups-contract.md"
violations=()

# Pattern: phrases lead-developer/postgres-pro/critic use to punt work
ambiguity_pattern='deferred to follow.?up|deferred to group|Group [A-Z] should|Group [A-Z] may|may pick up|to be handled by|TODO: Group|left for follow.?up'

# Scan all deliverables (.md, not the contract itself)
shopt -s nullglob
for f in "$dir"/*.md; do
  [[ "$(basename "$f")" == "groups-contract.md" ]] && continue
  hits=$(grep -nEi "$ambiguity_pattern" "$f" 2>/dev/null || true)
  if [[ -n "$hits" ]]; then
    while IFS= read -r line; do
      # Try to extract a hint at the punted symbol; if contract resolves it, skip
      if [[ -f "$contract" ]] && grep -qFi "$line" "$contract" 2>/dev/null; then
        continue
      fi
      violations+=("$f: $line")
    done <<< "$hits"
  fi
done

if [[ ${#violations[@]} -eq 0 ]]; then
  exit 0
fi

echo "ROUTING_AMBIGUOUS — Phase 5 blocked. Resolve before review."
echo "Each item: route to a group OR file QUEUE follow-up id and add to groups-contract.md.deferred_or_followup."
printf '%s\n' "${violations[@]}" | head -20
exit 2
