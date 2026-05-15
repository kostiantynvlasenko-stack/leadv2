#!/usr/bin/env bash
# PreToolUse hook for Read: block reads of files >100 lines when no limit/offset given.
# Forces lead to either delegate to Explore-haiku OR pass `limit=30`.
set -euo pipefail
trap 'echo "[$(basename "$0")] error at line $LINENO" >&2; exit 0' ERR

INPUT="$(cat 2>/dev/null || true)"
[[ -z "$INPUT" ]] && exit 0

FPATH="$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null || echo "")"
LIMIT="$(echo "$INPUT" | jq -r '.tool_input.limit // empty' 2>/dev/null || echo "")"
OFFSET="$(echo "$INPUT" | jq -r '.tool_input.offset // empty' 2>/dev/null || echo "")"

[[ -z "$FPATH" ]] && exit 0
[[ -n "$LIMIT" ]] && exit 0
[[ -n "$OFFSET" ]] && exit 0
[[ ! -f "$FPATH" ]] && exit 0

# Skip binary / image / pdf — Read handles those specially
case "$FPATH" in
  *.png|*.jpg|*.jpeg|*.gif|*.pdf|*.svg|*.ico|*.webp|*.mp4|*.mp3|*.zip|*.tar*|*.bin|*.so|*.dylib|*.ipynb)
    exit 0;;
esac

LINES="$(wc -l < "$FPATH" 2>/dev/null | tr -d ' ')"
[[ -z "$LINES" ]] && exit 0
[[ "$LINES" -le 100 ]] && exit 0

# Whitelist: tiny config / state files we always read fully (under 200 lines exempt for these)
case "$(basename "$FPATH")" in
  STATE.md|active.yaml|context.yaml|pulse.md|pr-manifest.yaml)
    [[ "$LINES" -le 200 ]] && exit 0;;
esac

cat >&2 <<MSG
[leadv2-force-read-limit] BLOCKED
File: $FPATH ($LINES lines)
Reading without limit/offset on a file >100L floods lead context.

Fix one of:
  1. Read with limit=30 if you need the header/summary
  2. Read with offset=N limit=M for a specific section
  3. Delegate full read to Explore-haiku via Agent(subagent_type=Explore, model=haiku, run_in_background=true)
  4. For review/critic deliverables: bash .claude/scripts/leadv2-critic-tail.sh "$FPATH"

Override (rare): export LEADV2_ALLOW_FULL_READ=1 for this turn.
MSG

[[ "${LEADV2_ALLOW_FULL_READ:-0}" == "1" ]] && exit 0
exit 2
