#!/usr/bin/env bash
# leadv2-code-ref.sh — Emit {file, line_start, line_end} JSON ref for context.yaml.
#
# Usage:
#   leadv2-code-ref.sh --file <path> --pattern <regex>
#   leadv2-code-ref.sh --file <path> --symbol <name>
#   leadv2-code-ref.sh --file <path> --line <N> [--span <N>]
#
# Replaces inline code pasting in planner/critic handoffs. Subagents read via
# Read tool using the returned {file, line_start, line_end}.

set -euo pipefail

FILE=""
PATTERN=""
SYMBOL=""
LINE=""
SPAN=20

while [[ $# -gt 0 ]]; do
  case "$1" in
    --file)    FILE="$2"; shift 2 ;;
    --pattern) PATTERN="$2"; shift 2 ;;
    --symbol)  SYMBOL="$2"; shift 2 ;;
    --line)    LINE="$2"; shift 2 ;;
    --span)    SPAN="$2"; shift 2 ;;
    -h|--help) grep '^# ' "$0" | sed 's/^# //'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ -z "$FILE" ]] && { echo "--file required" >&2; exit 2; }
[[ ! -f "$FILE" ]] && { echo "file not found: $FILE" >&2; exit 2; }

LINE_START=0
LINE_END=0

if [[ -n "$LINE" ]]; then
  LINE_START="$LINE"
  LINE_END=$(( LINE + SPAN ))
elif [[ -n "$SYMBOL" ]]; then
  PATTERN="(def|class|function|const|let|var|fn)[[:space:]]+$SYMBOL\b"
fi

if [[ -n "$PATTERN" ]] && [[ "$LINE_START" -eq 0 ]]; then
  LINE_START=$(grep -nE "$PATTERN" "$FILE" | head -1 | cut -d: -f1 || true)
  [[ -z "$LINE_START" ]] && LINE_START=1
  LINE_END=$(( LINE_START + SPAN ))
fi

TOTAL=$(wc -l < "$FILE" | tr -d ' ')
[[ "$LINE_END" -gt "$TOTAL" ]] && LINE_END="$TOTAL"

printf '{"file":"%s","line_start":%d,"line_end":%d}\n' "$FILE" "$LINE_START" "$LINE_END"
