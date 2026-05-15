#!/usr/bin/env bash
# PreToolUse:Edit|Write|MultiEdit — when /leadv2 has an active live task, all
# CODE edits must happen inside the per-task worktree at
# `<repo>/.claude/worktrees/<task-id>/...`. Edits in the main repo are blocked.
#
# Rationale: concurrent /leadv2 tasks share main repo → race conditions, half-merges,
# parallel session diff-check problems. Worktree isolation prevents this.
#
# Whitelist (these MUST stay in main repo, not worktree):
#   - docs/leadv2/, docs/handoff/, docs/BOARD.md, docs/LEAD_V2_STATE.md
#   - .claude/scripts/leadv2-*, .claude/hooks/leadv2-*, .claude/skills/leadv2-*
#   - settings.json/.local.json, active.yaml, context.yaml, *.summary.md
#   - /tmp /private/tmp /var/folders
#
# Override: `LEADV2_ALLOW_MAIN_REPO=1` for one-line fix-forward (rare).
set -euo pipefail
trap 'echo "[$(basename "$0")] error at line $LINENO" >&2; exit 0' ERR

# Resolve active task — exit if no live session
ACTIVE_YAML=""
for candidate in "$PWD/docs/leadv2/active.yaml" \
                 "/Users/kostiantyn.vlasenko/Projects/persona-engine/docs/leadv2/active.yaml"; do
  [[ -f "$candidate" ]] && ACTIVE_YAML="$candidate" && break
done
[[ -n "$ACTIVE_YAML" ]] || exit 0

LIVE_TASK=$(python3 -c "
import yaml, sys, os
d = yaml.safe_load(open(sys.argv[1])) or {}
for sess in (d.get('sessions') or []):
    pid = sess.get('pid')
    if not pid: continue
    try:
        os.kill(int(pid), 0)
        print(sess.get('task_id','')); break
    except (OSError, ValueError):
        pass
" "$ACTIVE_YAML" 2>/dev/null || true)
[[ -n "$LIVE_TASK" ]] || exit 0

[[ "${LEADV2_ALLOW_MAIN_REPO:-0}" == "1" ]] && exit 0

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

# Whitelist (always allowed in main repo, never moved to worktree)
case "$FILE_PATH" in
  /tmp/*|/private/tmp/*|/var/folders/*) exit 0 ;;
  */docs/handoff/*|*/docs/leadv2/*) exit 0 ;;
  */docs/BOARD.md|*/docs/LEAD_V2_STATE.md|*/docs/ROADMAP.md) exit 0 ;;
  */docs/specs/leadv2-*) exit 0 ;;
  */.claude/ref/*|*/.claude/templates/*) exit 0 ;;
  */.claude/leadv2-tasks/*) exit 0 ;;
  */.claude/skills/*/SKILL.md) exit 0 ;;
  */.claude/scripts/leadv2-*.sh) exit 0 ;;
  */.claude/hooks/leadv2-*.sh) exit 0 ;;
  */CLAUDE.md|*/memory/*.md) exit 0 ;;
  *.summary.md|*.full.md) exit 0 ;;
  *active.yaml|*context.yaml|*graph-snapshot.yaml|*.lock) exit 0 ;;
  */settings.json|*/settings.local.json) exit 0 ;;
esac

# Code edits MUST be in worktree
case "$FILE_PATH" in
  */.claude/worktrees/*)
    # Inside ANY worktree — accept (subagent may not know exact task-id mapping)
    exit 0 ;;
esac

# Anything else (code/config in main repo) — block
case "$FILE_PATH" in
  *.py|*.ts|*.tsx|*.js|*.jsx|*.sql|*.go|*.rs|*.sh|*.bash|*.zsh|*.rb|*.java|*.c|*.cc|*.cpp|*.h|*.hpp|*.lua|*.pl|*.php|*.json|*.yaml|*.yml|*.toml|*.tf|Dockerfile|*.Dockerfile|*.proto|*.graphql)
    cat <<MSG >&2
[leadv2-worktree-enforce] BLOCKED: edit on main repo while /leadv2 task ${LIVE_TASK} is active.
  file: $FILE_PATH

All code edits during a /leadv2 task MUST happen in the per-task worktree:
  /Users/kostiantyn.vlasenko/Projects/persona-engine/.claude/worktrees/${LIVE_TASK}/...

Why: concurrent leadv2 tasks share main repo → race conditions, parallel-session diff overwrites.

Setup (lead, before dispatching subagents):
  bash .claude/scripts/leadv2-task-init.sh ${LIVE_TASK}    # creates worktree
  # then spawn subagents with: cwd=.claude/worktrees/${LIVE_TASK}

Subagent: rewrite file_path to .claude/worktrees/${LIVE_TASK}/<rest>.

Override (rare, one-line fix-forward, no concurrent task): LEADV2_ALLOW_MAIN_REPO=1.
MSG
    exit 2
    ;;
esac
exit 0
