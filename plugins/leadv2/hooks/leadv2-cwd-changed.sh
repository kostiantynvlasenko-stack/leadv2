#!/usr/bin/env bash
# Fires on CwdChanged — detects worktree entry and reminds model to read context

NEW_CWD=$(python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('new_cwd',''))" 2>/dev/null)

if [[ "$NEW_CWD" == *"/.claude/worktrees/"* ]]; then
  RESUME="$NEW_CWD/.claude/pre-compact-resume.md"
  if [[ -f "$RESUME" ]]; then
    echo "Worktree entered: $NEW_CWD — read .claude/pre-compact-resume.md before continuing"
    exit 2
  fi
fi
exit 0
