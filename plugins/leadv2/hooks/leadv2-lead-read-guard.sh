#!/usr/bin/env bash
# PreToolUse:Read guard — block lead from reading code files outside handoff during active /leadv2.
# Advisory by default (warn-only). When LEADV2_LEAD_GUARD=1, the LEAD (main session) is
# hard-blocked from reading code; subagents are NEVER blocked (they need raw reads for byte-exact Edit targets + non-graph files). Lead vs subagent is detected via the input's agent_type field.
# Lead's whitelist:
#   docs/handoff/**, docs/leadv2/**, docs/BOARD.md, docs/LEAD_V2_STATE.md,
#   .claude/ref/**, .claude/leadv2-tasks/**, *.yaml in handoff dirs
#
# To override (rare, e.g. lead truly needs to peek code): set LEADV2_LEAD_GUARD=0
# or append "# read-guard: allow" — but reads don't accept commands, so use env var.

set -euo pipefail
trap 'echo "[$(basename "$0")] error at line $LINENO" >&2; exit 0' ERR

# Advisory fires by default (LEADV2_LEAD_GUARD=0 disables, =1 hard-blocks).
[[ "${LEADV2_LEAD_GUARD:-advisory}" == "0" ]] && exit 0
LEAD_GUARD_MODE="${LEADV2_LEAD_GUARD:-advisory}"

INPUT="$(cat 2>/dev/null || true)"
[[ -z "$INPUT" ]] && exit 0
# Lead (main session) has no agent_type in hook input; subagents carry a non-empty
# agent_type. Verified empirically 2026-06-06. Only the lead is a router that must
# route discovery through codebase-memory-mcp — so only the lead gets hard-blocked.
_LV2_AGENT_TYPE="$(printf '%s' "$INPUT" | python3 -c "
import sys, json
try:
    print(json.loads(sys.stdin.read()).get('agent_type','') or '')
except Exception:
    pass
" 2>/dev/null || true)"

FILE_PATH="$(printf '%s' "$INPUT" | python3 -c "
import sys, json
try:
    r = json.loads(sys.stdin.read())
    print(r.get('tool_input', {}).get('file_path', ''))
except Exception:
    pass
" 2>/dev/null || true)"

[[ -z "$FILE_PATH" ]] && exit 0

# Resolve configured paths from state-paths.yaml (fallback to PE defaults)
_lv2_sp_root="${CLAUDE_PROJECT_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
_lv2_sp_yaml="${_lv2_sp_root}/.claude/leadv2-overrides/state-paths.yaml"
_lv2_leadv2_dir=$(grep -E "^[[:space:]]*leadv2_dir[[:space:]]*:" "$_lv2_sp_yaml" 2>/dev/null | head -1 | sed -E "s/^[[:space:]]*leadv2_dir[[:space:]]*:[[:space:]]*//" | sed -E "s/^['\"]//; s/['\"][[:space:]]*$//" | tr -d '\r' || true)
[[ -z "$_lv2_leadv2_dir" || "$_lv2_leadv2_dir" == "null" || "$_lv2_leadv2_dir" == "~" ]] && _lv2_leadv2_dir="docs/leadv2"
_lv2_handoff_dir=$(grep -E "^[[:space:]]*handoff_dir[[:space:]]*:" "$_lv2_sp_yaml" 2>/dev/null | head -1 | sed -E "s/^[[:space:]]*handoff_dir[[:space:]]*:[[:space:]]*//" | sed -E "s/^['\"]//; s/['\"][[:space:]]*$//" | tr -d '\r' || true)
[[ -z "$_lv2_handoff_dir" || "$_lv2_handoff_dir" == "null" || "$_lv2_handoff_dir" == "~" ]] && _lv2_handoff_dir="docs/handoff"
_lv2_board_path=$(grep -E "^[[:space:]]*board_path[[:space:]]*:" "$_lv2_sp_yaml" 2>/dev/null | head -1 | sed -E "s/^[[:space:]]*board_path[[:space:]]*:[[:space:]]*//" | sed -E "s/^['\"]//; s/['\"][[:space:]]*$//" | tr -d '\r' || true)
[[ -z "$_lv2_board_path" || "$_lv2_board_path" == "null" || "$_lv2_board_path" == "~" ]] && _lv2_board_path="docs/BOARD.md"

# Dynamic whitelist check for configured paths (runs before case — handles non-default repos).
# Supports both absolute paths (prefix match) and relative path components (substring match).
_lv2_match_path() {
  local file_path="$1" pattern="$2"
  # If pattern is absolute, use prefix match; otherwise use substring glob.
  if [[ "$pattern" == /* ]]; then
    [[ "$file_path" == "${pattern}"/* || "$file_path" == "${pattern}" ]]
  else
    [[ "$file_path" == */"${pattern}"/* || "$file_path" == */"${pattern}" || "$file_path" == "${pattern}"/* ]]
  fi
}
_lv2_match_path "$FILE_PATH" "$_lv2_handoff_dir" && exit 0
_lv2_match_path "$FILE_PATH" "$_lv2_leadv2_dir" && exit 0
_lv2_match_path "$FILE_PATH" "$_lv2_board_path" && exit 0

# Whitelist: handoff, BOARD, LEAD_V2_STATE, refs, active.yaml, .summary.md, .full.md
case "$FILE_PATH" in
  /tmp/*) exit 0 ;;
  /private/tmp/*) exit 0 ;;
  /var/folders/*) exit 0 ;;
  */docs/handoff/*) exit 0 ;;
  */docs/leadv2/*) exit 0 ;;
  */docs/BOARD.md) exit 0 ;;
  */docs/LEAD_V2_STATE.md) exit 0 ;;
  */docs/ROADMAP.md) exit 0 ;;
  */docs/specs/leadv2-*) exit 0 ;;
  */.claude/ref/*) exit 0 ;;
  */.claude/leadv2-tasks/*) exit 0 ;;
  */.claude/skills/*/SKILL.md) exit 0 ;;
  */.claude/scripts/leadv2-*.sh) exit 0 ;;
  */.claude/hooks/leadv2-*.sh) exit 0 ;;
  */CLAUDE.md) exit 0 ;;
  */memory/*.md) exit 0 ;;
  *.summary.md) exit 0 ;;
  *.full.md) exit 0 ;;
  *active.yaml) exit 0 ;;
  *context.yaml) exit 0 ;;
  *graph-snapshot.yaml) exit 0 ;;
  */settings.json) exit 0 ;;
  */settings.local.json) exit 0 ;;
  */package.json) exit 0 ;;
  */tsconfig.json) exit 0 ;;
  */.env*) exit 0 ;;
esac

# Whitelist plugin's own source and cache paths (lead must read its own tooling)
case "$FILE_PATH" in
  */leadv2/*/hooks/*|*/leadv2/*/scripts/*) exit 0 ;;
esac

# Code file extensions — block when leadv2 active
case "$FILE_PATH" in
  *.py|*.ts|*.tsx|*.js|*.jsx|*.sql|*.json|*.go|*.rs|*.swift|*.kt|*.cs|*.sh|*.bash|*.zsh|*.fish|*.rb|*.java|*.c|*.cc|*.cpp|*.h|*.hpp|*.m|*.mm|*.lua|*.pl|*.php)
    if [[ -n "$_LV2_AGENT_TYPE" ]]; then
      # Subagent: advisory nudge only, NEVER block. Discovery should go through
      # codebase-memory-mcp; raw read is legit only for byte-exact Edit targets + non-graph files.
      printf '[leadv2-lead-read-guard] note: subagent(%s) raw-reading %s — prefer codebase-memory-mcp for discovery; raw read OK for edit-target / non-graph files.\n' "$_LV2_AGENT_TYPE" "$FILE_PATH" >&2
      exit 0
    fi
    printf '[leadv2-lead-read-guard] WARN: lead reading code file %s directly.\n' "$FILE_PATH" >&2
    printf '  Prefer: Agent(Explore,haiku) | get_code_snippet | search_graph\n' >&2
    printf '  Disable warn: export LEADV2_LEAD_GUARD=0  Hard-block: =1\n' >&2
    [[ "$LEAD_GUARD_MODE" == "1" ]] && python3 -c \
      "import sys,json; f=sys.argv[1]; print(json.dumps({'hookSpecificOutput':{'hookEventName':'PreToolUse','permissionDecision':'deny','permissionDecisionReason':'[leadv2-lead-read-guard] BLOCKED (lead is a router — use codebase-memory-mcp / delegate to a subagent): '+f+'. Set LEADV2_LEAD_GUARD=0 to allow.'}}))" -- "$FILE_PATH"
    exit 0
    ;;
esac

exit 0
