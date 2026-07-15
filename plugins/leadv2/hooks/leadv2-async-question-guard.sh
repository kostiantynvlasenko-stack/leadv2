#!/usr/bin/env bash
# PreToolUse hook (matcher: AskUserQuestion) — enforce async-question routing
# under LEADV2_ASYNC_QUESTIONS.
#
# THE GAP THIS CLOSES: fanned-out /leadv2 child sessions run headless/detached
# (LEADV2_ASYNC_QUESTIONS=1 exported by leadv2-fanout.sh into every child).
# The founder watches the SUPERVISING lead's window, not the child's. Before
# this hook, the ONLY enforcement was prose in the /leadv2 skill telling the
# model to use the control-plane proxy script instead of the interactive
# AskUserQuestion tool -- nothing structural stopped a child from calling it
# anyway. When it did, the tool call blocked the child's tmux window forever:
# `leadv2-supervise.sh` only reads the control plane, never a worktree-private
# AskUserQuestion prompt, so the stall was permanent and invisible (confirmed
# incident -- child sat blocked for hours with no recoverable signal).
#
# Behavior:
#   LEADV2_ASYNC_QUESTIONS=1 or =true (case-insensitive)  -> DENY (exit 2),
#     redirect the model to scripts/leadv2-ask.sh.
#   unset / 0 / anything else                              -> no-op (exit 0).
set -euo pipefail
trap 'echo "[$(basename "$0")] error at line $LINENO" >&2; exit 0' ERR

FLAG="${LEADV2_ASYNC_QUESTIONS:-0}"
FLAG_LC="$(printf '%s' "$FLAG" | tr '[:upper:]' '[:lower:]')"

if [[ "$FLAG_LC" != "1" && "$FLAG_LC" != "true" ]]; then
  exit 0
fi

INPUT="$(cat 2>/dev/null || true)"

TASK_ID="${LEADV2_TASK_ID:-}"
if [[ -z "$TASK_ID" && -n "$INPUT" ]]; then
  TASK_ID="$(echo "$INPUT" | jq -r '.tool_input.task_id // empty' 2>/dev/null || echo "")"
fi
[[ -z "$TASK_ID" ]] && TASK_ID="\$LEADV2_TASK_ID"

cat >&2 <<MSG
[leadv2-async-question-guard] BLOCKED
This is a fanned-out /leadv2 child session (LEADV2_ASYNC_QUESTIONS=$FLAG set).
The founder is watching the SUPERVISING lead's window, not this one -- the
interactive AskUserQuestion tool would block THIS window forever with no
recoverable signal (supervise never sees it -- confirmed permanent-stall
incident).

Route the question through the control-plane proxy instead:
  bash "\${CLAUDE_PLUGIN_ROOT}/../../scripts/leadv2-ask.sh" "$TASK_ID" "<question>" \\
    --option "a|<label>" --option "b|<label>" [--timeout <sec>]

It writes the question to the control plane, blocks until answered via
\`/leadv2 reply <q-id> <option>\`, and prints the chosen option on stdout.
On timeout (exit 2): fall back to your best-effort default and state the
assumption explicitly in STATE.md -- never block forever.
MSG

exit 2
