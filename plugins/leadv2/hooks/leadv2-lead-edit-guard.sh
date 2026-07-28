#!/usr/bin/env bash
# PreToolUse:Edit|Write|MultiEdit guard — block lead from modifying code files during /leadv2.
# Mirrors lead-read-guard. Lead's job is dispatch — code edits go to subagents.
#
# Whitelist: handoff/, leadv2/, BOARD, LEAD_V2_STATE, refs, summary/full md, active/context yaml,
#            settings/package/tsconfig json, .env*, .claude/scripts/leadv2-*, .claude/hooks/leadv2-*
# Block: any source extension (.py .ts .go .sh .rs etc) outside whitelist
#
# Opt-in via LEADV2_LEAD_GUARD=1. NOTE (F2, task 6d0c93f4a7b2): this is almost
# always armed via ~/.claude/settings.json env (LEADV2_LEAD_GUARD=1), and
# settings.json env wins over whatever a shell `export`/`unset` sets before a
# tool call -- so a dispatch script exporting LEADV2_LEAD_GUARD=0 is silently
# ignored (D4). LEADV2_LEAD_GUARD_FORCE is NOT defined in settings.json, so it
# is the one override that actually reaches this hook:
#   LEADV2_LEAD_GUARD_FORCE=0   force the guard OFF, even if LEADV2_LEAD_GUARD=1
#   LEADV2_LEAD_GUARD_FORCE=1   force the guard ON,  even if LEADV2_LEAD_GUARD=0
#   (unset)                    fall through to LEADV2_LEAD_GUARD as before

set -euo pipefail
trap 'echo "[$(basename "$0")] error at line $LINENO" >&2; exit 0' ERR

if [[ "${LEADV2_LEAD_GUARD_FORCE:-}" == "0" ]]; then
    exit 0
elif [[ "${LEADV2_LEAD_GUARD_FORCE:-}" == "1" ]]; then
    : # fall through — guard forced on regardless of LEADV2_LEAD_GUARD
elif [[ -n "${LEADV2_LEAD_GUARD_FORCE:-}" ]]; then
    # NIT (fix-round-2, task 6d0c93f4a7b2): unrecognized value falls through to
    # default behavior silently otherwise -- warn once so a typo'd override
    # doesn't look like it took effect.
    echo "[leadv2-lead-edit-guard] LEADV2_LEAD_GUARD_FORCE='${LEADV2_LEAD_GUARD_FORCE}' is not 0 or 1 -- ignoring, falling back to LEADV2_LEAD_GUARD" >&2
    [[ "${LEADV2_LEAD_GUARD:-0}" == "1" ]] || exit 0
else
    [[ "${LEADV2_LEAD_GUARD:-0}" == "1" ]] || exit 0
fi

INPUT="$(cat 2>/dev/null || true)"
[[ -z "$INPUT" ]] && exit 0

# Subagents are always exempt — only the lead router is blocked from direct edits.
_LV2_AGENT_TYPE="$(printf '%s' "$INPUT" | jq -r '.agent_type // empty' 2>/dev/null || true)"
[[ -n "$_LV2_AGENT_TYPE" ]] && exit 0

FILE_PATH="$(printf '%s' "$INPUT" | python3 -c "
import sys, json
try:
    r = json.loads(sys.stdin.read())
    print(r.get('tool_input', {}).get('file_path', ''))
except Exception:
    pass
" 2>/dev/null || true)"

[[ -z "$FILE_PATH" ]] && exit 0

# Whitelist
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
esac

# Code/config files — block
case "$FILE_PATH" in
  *.py|*.ts|*.tsx|*.js|*.jsx|*.sql|*.go|*.rs|*.swift|*.kt|*.cs|*.sh|*.bash|*.zsh|*.fish|*.rb|*.java|*.c|*.cc|*.cpp|*.h|*.hpp|*.m|*.mm|*.lua|*.pl|*.php|*.json|*.yaml|*.yml|*.toml|*.tf|*.tfvars|*.proto|*.graphql|Dockerfile|*.Dockerfile)
    # LOW (fix-round-2, task 6d0c93f4a7b2): disable the ERR trap before the
    # deny write -- a failure inside the heredoc would otherwise fire the trap
    # (exit 0 -> allow), silently converting an intended deny into an allow.
    trap - ERR
    cat <<MSG >&2 || true
[leadv2-lead-edit-guard] Lead editing code/config files directly is forbidden during /leadv2.
  file: $FILE_PATH
  tool: Edit/Write/MultiEdit

Lead's job: dispatch. To make code changes:
  1. Write a REVISE verdict to handoff/<phase>.summary.md
  2. Spawn Agent(subagent_type=developer, model=sonnet) with mission file
  3. Subagent edits, returns new .summary.md verdict

If this is post-deploy verification only: spawn Agent(subagent_type=verifier).

NOTE: \`unset LEADV2_LEAD_GUARD\` / \`export LEADV2_LEAD_GUARD=0\` does NOT work --
~/.claude/settings.json arms LEADV2_LEAD_GUARD=1 as hook env, which wins over
whatever the calling shell exported. The working override is:
  export LEADV2_LEAD_GUARD_FORCE=0
MSG
    exit 2
    ;;
esac

exit 0
