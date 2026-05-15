#!/usr/bin/env bash
# PostToolUse hook for Bash: emit warning when output >5KB. Doesn't block (legit cases exist).
# Each warning makes lead aware so next call can `| head` at source.
set -euo pipefail
trap 'echo "[$(basename "$0")] error at line $LINENO" >&2; exit 0' ERR

INPUT="$(cat 2>/dev/null || true)"
[[ -z "$INPUT" ]] && exit 0

# tool_output for Bash is the stdout/stderr concat. Estimate size from the input record.
SIZE="$(echo "$INPUT" | jq -r '.tool_output // .tool_response.output // empty' 2>/dev/null | wc -c | tr -d ' ' || echo 0)"
[[ -z "$SIZE" || "$SIZE" -lt 8192 ]] && exit 0

CMD="$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null | head -c 200 || echo "")"
KB=$((SIZE / 1024))

# Heuristic: did the command try to truncate at source?
TRUNCATED=0
echo "$CMD" | grep -qE '\| *(head|tail) | -m | head -[0-9]+| tail -[0-9]+| jq | grep -m | awk' && TRUNCATED=1

if [[ "$TRUNCATED" -eq 0 ]]; then
  cat >&2 <<MSG
[leadv2-bash-output-cap] ${KB}KB output from untruncated command
  cmd: ${CMD:0:120}...
  next time: pipe at source — '| head -50' / '| tail -30' / 'grep -m 5' / 'find ... | head'.
  Output flooding lead context costs 1.25K tokens per KB and stays forever.
MSG
fi

exit 0
