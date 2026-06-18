#!/bin/bash
# PreToolUse gate: discourage/block Opus from editing code files directly.
# CLAUDE_PLUS_CODEX → warn-and-allow (orchestrator should delegate but small edits OK)
# FULL              → block (force delegation to GLM or Sonnet agent)
# OFF / CLAUDE      → off

MODE=$(~/.claude/hooks/lib/get-mode.sh 2>/dev/null || echo OFF)
case "$MODE" in
  CLAUDE_PLUS_CODEX|FULL) ;;
  *) exit 0 ;;
esac

INPUT=$(cat)
FILE=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // ""' 2>/dev/null)
[ -z "$FILE" ] && exit 0

case "$FILE" in
  *.md|*.json|*.env|*.yaml|*.yml|*.txt|*.toml|*.cfg|*.ini) exit 0 ;;
  *memory/*|*MEMORY*|*CLAUDE*|*BOARD*|*rules/*|*plans/*) exit 0 ;;
  *supabase/migrations/*|*contracts/*|*docs/*) exit 0 ;;
  *.schema.*|*/.claude/*) exit 0 ;;
esac

if [ "$MODE" = "CLAUDE_PLUS_CODEX" ]; then
  echo "TIP ($MODE): Edit on code file ($(basename "$FILE")). Small fix? Proceed. Larger work? Delegate to a named agent (Agent(subagent_type=developer))." >&2
  exit 0
fi

# FULL — hard block
echo "BLOCKED (FULL mode): Opus cannot edit code files directly ($(basename "$FILE")). Delegate:
  - Bash(command='~/.claude/scripts/glm-coder.sh \"fix X in $FILE\"', run_in_background=true)
  - Agent(subagent_type=developer, prompt=\"fix X in $FILE\")
Toggle off: ~/.claude/scripts/multi-model.sh mode \"\$(pwd)\" CLAUDE_PLUS_CODEX" >&2
exit 2
