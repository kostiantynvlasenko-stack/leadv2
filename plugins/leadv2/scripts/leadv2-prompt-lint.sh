#!/bin/bash
# leadv2-prompt-lint.sh — enforce ≤300-word lead-side spawn prompts.
# Lead's job: orient (path, branch, project hint) + name files + name deliverable + cap word count.
# Subagent reads context.yaml + mission.md itself. Don't duplicate spec into the prompt.
#
# Usage: leadv2-prompt-lint.sh <prompt-file-or-stdin>
# Exit 0 = pass. Exit 2 = too long.

set -euo pipefail

MAX_WORDS="${LEADV2_PROMPT_MAX_WORDS:-300}"

if [[ $# -ge 1 && -f "$1" ]]; then
  text=$(cat "$1")
  src="$1"
else
  text=$(cat)
  src="<stdin>"
fi

words=$(echo "$text" | wc -w | tr -d ' ')
if [[ "$words" -gt "$MAX_WORDS" ]]; then
  echo "PROMPT_TOO_LONG src=$src words=$words max=$MAX_WORDS"
  echo "→ subagent reads context.yaml + mission.md itself; prompt should orient, not respec."
  exit 2
fi
exit 0
