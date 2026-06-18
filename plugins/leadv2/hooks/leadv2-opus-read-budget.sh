#!/bin/bash
# PreToolUse gate: cap raw code-file reads before forcing delegation.
# OFF / CLAUDE        → off (no budget)
# CLAUDE_PLUS_CODEX   → 12 reads (generous)
# FULL                → 4 reads (tight — push to GLM)

MODE=$(~/.claude/hooks/lib/get-mode.sh 2>/dev/null || echo OFF)
case "$MODE" in
  CLAUDE_PLUS_CODEX) BUDGET=12 ;;
  FULL)              BUDGET=4 ;;
  *) exit 0 ;;
esac

COUNTER="/tmp/.pe-opus-reads-$PPID"
DELEGATED="/tmp/.pe-delegated"
GRAPH_MARKER="/tmp/cbm-graph-used-$PPID"

[ -f "$DELEGATED" ] && exit 0
# After graph query, file reads are justified follow-ups — budget doesn't apply.
[ -f "$GRAPH_MARKER" ] && exit 0

INPUT=$(cat)
FILE=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // .tool_input.pattern // ""' 2>/dev/null)

case "$FILE" in
  *.md|*.json|*.env|*.yaml|*.yml|*.txt|*.toml|*.cfg|*.ini) exit 0 ;;
  *memory/*|*MEMORY*|*CLAUDE*|*BOARD*|*rules/*|*plans/*) exit 0 ;;
  *supabase/migrations/*|*contracts/*|*docs/*) exit 0 ;;
  *.schema.*|*/.claude/*|"") exit 0 ;;
esac

COUNT=0
[ -f "$COUNTER" ] && COUNT=$(cat "$COUNTER" 2>/dev/null)
COUNT=$((COUNT + 1))
echo "$COUNT" > "$COUNTER"

[ "$COUNT" -le "$BUDGET" ] && exit 0

printf '%s' "{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"deny\",\"additionalContext\":\"opus-read-budget: $COUNT code reads, budget $BUDGET ($MODE). Use graph-first (search_graph/trace_path) or delegate: Agent(subagent_type=Explore, model=haiku). To lift: multi-model.sh mode \$(pwd) CLAUDE\"}}"
exit 0
