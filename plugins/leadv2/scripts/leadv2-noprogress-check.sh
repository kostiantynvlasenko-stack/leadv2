#!/usr/bin/env bash
# leadv2-noprogress-check.sh — deterministic no-progress stall detector for the recovery loop.
# Usage: leadv2-noprogress-check.sh <jsonl_path> <signature> [max_stalled=2]
# Appends one base64-encoded token per call to <jsonl_path> (creates file+parent dirs if missing),
# then counts trailing consecutive lines whose token equals base64(<signature>).
# Prints STALLED and exits 1 if count >= max_stalled; prints PROGRESS and exits 0 otherwise.
# Signatures containing any of " \ / | : and spaces round-trip exactly via base64 — no escaping.
set -euo pipefail

if [[ $# -lt 2 ]]; then
  printf -- 'Usage: %s <jsonl_path> <signature> [max_stalled=2]\n' "${0##*/}" >&2
  exit 2
fi

JSONL_PATH="$1"
SIGNATURE="$2"
MAX_STALLED="${3:-2}"

# Create parent directory and file if absent
mkdir -p "$(dirname "$JSONL_PATH")"
[[ -f "$JSONL_PATH" ]] || touch "$JSONL_PATH"

# Encode signature as base64 (strip newlines for single-line token)
TOKEN="$(printf '%s' "$SIGNATURE" | base64 | tr -d '\n')"

# Append token (one per line — no JSON, no escaping needed)
printf -- '%s\n' "$TOKEN" >> "$JSONL_PATH"

# Count trailing consecutive lines matching this token
count=0
while IFS= read -r line; do
  if [[ "$line" == "$TOKEN" ]]; then
    count=$(( count + 1 ))
  else
    count=0
  fi
done < "$JSONL_PATH"

if (( count >= MAX_STALLED )); then
  printf -- 'STALLED\n'
  exit 1
else
  printf -- 'PROGRESS\n'
  exit 0
fi
