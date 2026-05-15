#!/usr/bin/env bash
# leadv2-graph-cache-bust.sh — PostToolUse Bash hook (PO-061)
#
# Fires after any Bash tool call matching ^git commit.
# Removes stale MCP search_graph cache files so the next subagent
# that wakes up after the commit sees a fresh graph.
#
# Silent exit 0 when:
#   - stdin is empty / malformed
#   - git commit not detected in tool input
#   - no cache files exist

set -euo pipefail
trap 'exit 0' ERR

INPUT="$(cat 2>/dev/null || true)"
[[ -z "$INPUT" ]] && exit 0

# Extract the Bash command from PostToolUse JSON
CMD="$(printf '%s' "$INPUT" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    # PostToolUse: tool_input.command
    print(d.get('tool_input', {}).get('command', ''))
except Exception:
    print('')
" 2>/dev/null || true)"

# Only act on git commit invocations
case "$CMD" in
  "git commit"*) ;;  # match
  *) exit 0 ;;
esac

# Derive project root from cwd in hook input (fall back to env, then known path)
PROJECT_ROOT="$(printf '%s' "$INPUT" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('cwd', ''))
except Exception:
    print('')
" 2>/dev/null || true)"

[[ -z "$PROJECT_ROOT" ]] && PROJECT_ROOT="${PROJECT_ROOT:-/Users/kostiantyn.vlasenko/Projects/persona-engine}"

# Bust per-task MCP cache files (docs/handoff/<id>/mcp-cache/*.yaml)
HANDOFF_BASE="$PROJECT_ROOT/docs/handoff"
BUSTED=0
if [[ -d "$HANDOFF_BASE" ]]; then
  while IFS= read -r -d '' cache_file; do
    rm -f "$cache_file"
    BUSTED=$(( BUSTED + 1 ))
  done < <(
    # bash-guard: allow
    find "$HANDOFF_BASE" -maxdepth 3 -path "*/mcp-cache/*.yaml" -print0 2>/dev/null
  )
fi

# Also bust any global graph-cache files under ~/.claude/state/leadv2/
GLOBAL_CACHE_DIR="$HOME/.claude/state/leadv2"
if [[ -d "$GLOBAL_CACHE_DIR" ]]; then
  while IFS= read -r -d '' cache_file; do
    rm -f "$cache_file"
    BUSTED=$(( BUSTED + 1 ))
  done < <(
    # bash-guard: allow
    find "$GLOBAL_CACHE_DIR" -maxdepth 1 -name "*.graph-cache" -print0 2>/dev/null
  )
fi

# Silent success — no stdout output needed
exit 0
