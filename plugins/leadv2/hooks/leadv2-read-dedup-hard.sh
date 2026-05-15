#!/usr/bin/env bash
# PreToolUse hook for Read: hard-block 3rd same-file no-limit Read in a session.
# Replaces (sits alongside) the soft warn-only read-dedup.sh.
set -euo pipefail
trap 'echo "[$(basename "$0")] error at line $LINENO" >&2; exit 0' ERR

INPUT="$(cat 2>/dev/null || true)"
[[ -z "$INPUT" ]] && exit 0

FPATH="$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null || echo "")"
LIMIT="$(echo "$INPUT" | jq -r '.tool_input.limit // empty' 2>/dev/null || echo "")"
OFFSET="$(echo "$INPUT" | jq -r '.tool_input.offset // empty' 2>/dev/null || echo "")"

[[ -z "$FPATH" ]] && exit 0

SESSION_ID="$(echo "$INPUT" | jq -r '.session_id // .session.id // empty' 2>/dev/null || echo "default")"
TRACKER="/tmp/.leadv2-read-tracker-${SESSION_ID}.tsv"

# Tracker line format: PATH<TAB>READ_COUNT<TAB>NO_LIMIT_COUNT
COUNT=0
NO_LIMIT_COUNT=0
if [[ -f "$TRACKER" ]]; then
  ROW="$(awk -F'\t' -v p="$FPATH" '$1==p {print; exit}' "$TRACKER")"
  if [[ -n "$ROW" ]]; then
    COUNT="$(echo "$ROW" | cut -f2)"
    NO_LIMIT_COUNT="$(echo "$ROW" | cut -f3)"
  fi
fi

NEW_COUNT=$((COUNT + 1))
NEW_NO_LIMIT=$NO_LIMIT_COUNT
if [[ -z "$LIMIT" && -z "$OFFSET" ]]; then
  NEW_NO_LIMIT=$((NO_LIMIT_COUNT + 1))
fi

# Block: 3rd no-limit re-read of same file
if [[ "$NEW_NO_LIMIT" -ge 3 ]]; then
  cat >&2 <<MSG
[leadv2-read-dedup-hard] BLOCKED
File: $FPATH already read ${NO_LIMIT_COUNT}x without limit/offset.
3rd full re-read of the same file = pure waste. The content hasn't changed.
You already have it in chat history.

Fix:
  - Skip this read; refer to memory of prior reads
  - If file actually changed: pass limit/offset to read just the changed section
  - If you NEED full content again: export LEADV2_ALLOW_FULL_READ=1 (rare)
MSG
  if [[ "${LEADV2_ALLOW_FULL_READ:-0}" != "1" ]]; then
    exit 2
  fi
fi

# Persist
if [[ -f "$TRACKER" ]]; then
  awk -F'\t' -v p="$FPATH" -v c="$NEW_COUNT" -v n="$NEW_NO_LIMIT" '
    BEGIN{found=0; OFS="\t"}
    $1==p {print p, c, n; found=1; next}
    {print}
    END{if (!found) print p, c, n}
  ' "$TRACKER" > "${TRACKER}.new" && mv "${TRACKER}.new" "$TRACKER"
else
  printf "%s\t%d\t%d\n" "$FPATH" "$NEW_COUNT" "$NEW_NO_LIMIT" > "$TRACKER"
fi
exit 0
