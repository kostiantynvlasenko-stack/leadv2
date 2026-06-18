#!/bin/bash
# PreToolUse(Workflow) — model-pinning lint (founder directive 2026-06-09).
# Workflow agents inherit the SESSION model unless the script pins model: on each agent().
# With an Opus lead, an unpinned agent() = Opus, and a workflow spawns DOZENS of them =
# the 2026-06-09 quota leak at 10x scale. This counts agent() calls vs model: keys and
# WARNS (does not block) when any agent() looks unpinned. Warning is enough here because
# the Workflow tool has a human confirm-gate on first run — the orchestrator can fix the
# script before confirming. leadv2 workflow TEMPLATES must pin model on every agent().

INPUT=$(cat)
SCRIPT=$(echo "$INPUT" | jq -r '.tool_input.script // .tool_input.scriptPath // ""' 2>/dev/null)
[ -z "$SCRIPT" ] && exit 0

# If a path was passed, read the file; else SCRIPT is the inline body.
BODY="$SCRIPT"
[ -f "$SCRIPT" ] && BODY=$(cat "$SCRIPT" 2>/dev/null)

# Count agent( invocations and model: occurrences (rough but effective).
AGENTS=$(printf '%s' "$BODY" | grep -oE '\bagent\(' | wc -l | tr -d ' ')
MODELS=$(printf '%s' "$BODY" | grep -oE 'model:' | wc -l | tr -d ' ')

[ "${AGENTS:-0}" -eq 0 ] && exit 0
if [ "${MODELS:-0}" -ge "${AGENTS:-0}" ]; then
  exit 0   # at least one model: per agent() → assume pinned, pass silently
fi

GAP=$((AGENTS - MODELS))
printf '%s' "{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"additionalContext\":\"workflow-model-guard WARN: this workflow has ${AGENTS} agent() call(s) but only ${MODELS} model: pin(s) — ~${GAP} agent(s) would INHERIT the session model (Opus if the lead is Opus) = quota bonfire across many agents. Pin model: 'haiku' (reads/discovery), 'sonnet' (code/verify/synth) on EVERY agent() before confirming this run.\"}}"
exit 0
