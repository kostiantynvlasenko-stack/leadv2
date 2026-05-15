#!/usr/bin/env bash
# PreToolUse:Read guard — block lead from reading code files outside handoff during active /leadv2.
# Only fires when LEADV2_LEAD_GUARD=1 in env (opt-in), to avoid breaking subagent reads.
# Lead's whitelist:
#   docs/handoff/**, docs/leadv2/**, docs/BOARD.md, docs/LEAD_V2_STATE.md,
#   .claude/ref/**, .claude/leadv2-tasks/**, *.yaml in handoff dirs
#
# To override (rare, e.g. lead truly needs to peek code): set LEADV2_LEAD_GUARD=0
# or append "# read-guard: allow" — but reads don't accept commands, so use env var.

set -euo pipefail
trap 'echo "[$(basename "$0")] error at line $LINENO" >&2; exit 0' ERR

# Off by default
[[ "${LEADV2_LEAD_GUARD:-0}" == "1" ]] || exit 0

INPUT="$(cat 2>/dev/null || true)"
[[ -z "$INPUT" ]] && exit 0

FILE_PATH="$(printf '%s' "$INPUT" | python3 -c "
import sys, json
try:
    r = json.loads(sys.stdin.read())
    print(r.get('tool_input', {}).get('file_path', ''))
except Exception:
    pass
" 2>/dev/null || true)"

[[ -z "$FILE_PATH" ]] && exit 0

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

# Code file extensions — block when leadv2 active
case "$FILE_PATH" in
  *.py|*.ts|*.tsx|*.js|*.jsx|*.sql|*.json|*.go|*.rs|*.swift|*.kt|*.cs|*.sh|*.bash|*.zsh|*.fish|*.rb|*.java|*.c|*.cc|*.cpp|*.h|*.hpp|*.m|*.mm|*.lua|*.pl|*.php)
    cat <<MSG >&2
[leadv2-lead-read-guard] Lead reading code file directly is forbidden during /leadv2.
  file: $FILE_PATH

Lead's job: dispatch. Spawn one of:
  - Agent(subagent_type=Explore, model=haiku) for explanation
  - Skill(leadv2-judge-question) for "should I" questions
  - leadv2-phase-advance.sh for state transitions

Override: \`unset LEADV2_LEAD_GUARD\` if this is genuinely a Phase 0 graph-warm read.
MSG
    exit 2
    ;;
esac

exit 0
