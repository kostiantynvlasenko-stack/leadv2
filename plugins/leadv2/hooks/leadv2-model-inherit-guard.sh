#!/bin/bash
# PreToolUse(Agent) model guard (founder directive 2026-06-09, updated 2026-06-18).
#
# PRINCIPLE: expensive model (opus) ONLY for high-judgment agents; cheap operations
# must never get opus — not by inheritance, not by explicit request.
#
# OPUS ALLOWLIST — subagent_types allowed to spawn with an opus model:
#   architect, critic, security-auditor,
#   leadv2:architect, leadv2:critic, leadv2:security-auditor
# All other subagent_types that request opus are DENIED with an actionable message.
#
# For non-opus models: explicit model= always passes (as before).
# For no explicit model= at all: falls through to the inheritance-guard logic below.
#
# Inheritance guard guarantees: even when the MAIN chat is Opus, no subagent silently
# inherits Opus. A subagent's model is Opus-by-inheritance ONLY when BOTH are true:
#   (1) the Agent call passes no explicit model=, AND
#   (2) the agent definition has no frontmatter `model:` to pin it.
# This hook DENIES exactly that case (forcing an explicit model= or a frontmatter fix),
# and passes everything else silently. Custom agents that pin model: sonnet/haiku are safe.
# Was WARN-only until 2026-06-09; warn proved insufficient (Opus quota leak via inherited spawns).

INPUT=$(cat)
SUBTYPE=$(echo "$INPUT" | jq -r '.tool_input.subagent_type // ""' 2>/dev/null)
MODEL=$(echo "$INPUT" | jq -r '.tool_input.model // ""' 2>/dev/null)
SESSION_MODEL="${LEADV2_MAIN_MODEL:-the session model}"

deny() {
  # $1 = reason (no double-quotes inside, callers keep it clean)
  printf '%s' "{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"deny\",\"permissionDecisionReason\":\"$1\"}}"
  exit 0
}

# Explicit model on the call — check if it is opus.
if [ -n "$MODEL" ]; then
  # Case-insensitive substring match for "opus" covers: opus, claude-opus-4, claude-opus-4*, opus[1m], etc.
  MODEL_LOWER=$(echo "$MODEL" | tr '[:upper:]' '[:lower:]')
  if echo "$MODEL_LOWER" | grep -q "opus"; then
    # Opus requested — enforce allowlist.
    case "$SUBTYPE" in
      architect|critic|security-auditor|leadv2:architect|leadv2:critic|leadv2:security-auditor)
        # High-judgment agent — allow opus.
        exit 0
        ;;
      *)
        deny "model-guard DENY: opus is reserved for high-judgment agents (architect/critic/security-auditor). subagent_type=$SUBTYPE is a cheaper-op agent — use model=sonnet (code/verify/ops) or model=haiku (reads/discovery). Principle: no expensive models for cheap operations."
        ;;
    esac
  else
    # Non-opus explicit model → always allow.
    exit 0
  fi
fi

# No explicit model= → fall through to inheritance guard.

# No subtype (defensive) → don't block.
[ -z "$SUBTYPE" ] && exit 0

# Frontmatter-less built-ins ALWAYS inherit the caller (no definition file to pin a model).
case "$SUBTYPE" in
  Explore|general-purpose|claude)
    deny "model-guard DENY: subagent_type=$SUBTYPE has no explicit model= -> it inherits the caller ($SESSION_MODEL) = double burn, zero savings. Re-spawn with model=haiku (reads/discovery/fan-out) or model=sonnet (code/verify). Pass model= on EVERY built-in Agent call."
    ;;
esac

# Custom agent without explicit model=: safe ONLY if its definition pins a frontmatter model.
# Locate the definition (best-effort across project / user / plugin agent dirs).
AGENT_FILE=""
for root in \
  "${CLAUDE_PROJECT_DIR:-$PWD}/.claude/agents" \
  "$HOME/.claude/agents" \
  "$HOME/.claude/plugins"/*/agents \
  ${CLAUDE_PLUGIN_ROOT:+"$CLAUDE_PLUGIN_ROOT/agents"} ; do
  cand="$root/$SUBTYPE.md"
  [ -f "$cand" ] && { AGENT_FILE="$cand"; break; }
done

# Definition not found (namespaced/plugin agent we can't inspect) → don't block, avoid false-deny.
[ -z "$AGENT_FILE" ] && exit 0

# Found: frontmatter model: pins the model regardless of caller → safe, pass silently.
head -30 "$AGENT_FILE" | grep -qiE "^model:" && exit 0

# Found AND no frontmatter model → it would inherit the caller ($SESSION_MODEL). DENY.
deny "model-guard DENY: agent '$SUBTYPE' ($AGENT_FILE) has NO frontmatter model: and the spawn passed no model= -> it inherits the caller ($SESSION_MODEL). Fix: add 'model: sonnet' (or haiku) to the agent frontmatter, or pass model= on the spawn."
