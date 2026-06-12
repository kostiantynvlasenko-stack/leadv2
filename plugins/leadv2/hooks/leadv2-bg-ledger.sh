#!/usr/bin/env bash
# PostToolUse hook: track background Agent spawns and watchdog Monitor calls per session.
#
# On Agent PostToolUse with run_in_background==true  → append BG_SPAWN line to ledger.
# On Monitor PostToolUse                             → append WATCHDOG line to ledger.
# All other tools                                    → exit 0 (no-op).
#
# Ledger path: /tmp/leadv2-bg-ledger/<session_id>.log
# Each line is tab-separated: <ts>  <type>  <desc>
# Types: BG_SPAWN | WATCHDOG
#
# Only fires for the lead (no agent_type field in hook input).
# Subagents have agent_type set → exit 0 silently.
set -euo pipefail
trap 'exit 0' ERR

INPUT="$(cat 2>/dev/null || true)"
[[ -z "$INPUT" ]] && exit 0

# Subagent guard: lead has NO agent_type field (or empty); subagents have it set.
AGENT_TYPE="$(printf -- '%s' "$INPUT" | jq -r '.agent_type // empty' 2>/dev/null || true)"
[[ -n "$AGENT_TYPE" ]] && exit 0

# Extract session_id — required for ledger keying.
SESSION_ID="$(printf -- '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)"
[[ -z "$SESSION_ID" ]] && exit 0

TOOL_NAME="$(printf -- '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || true)"
[[ -z "$TOOL_NAME" ]] && exit 0

LEDGER_DIR="/tmp/leadv2-bg-ledger"
mkdir -p "$LEDGER_DIR"
SAFE_SID="$(printf -- '%s' "$SESSION_ID" | tr -cd 'A-Za-z0-9._-')"
[[ -z "$SAFE_SID" ]] && exit 0
LEDGER_FILE="${LEDGER_DIR}/${SAFE_SID}.log"

TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

if [[ "$TOOL_NAME" == "Agent" ]]; then
  # Only track background spawns.
  IS_BG="$(printf -- '%s' "$INPUT" | jq -r '.tool_input.run_in_background // false' 2>/dev/null || true)"
  [[ "$IS_BG" != "true" ]] && exit 0

  DESC="$(printf -- '%s' "$INPUT" | jq -r '.tool_input.description // "(no description)"' 2>/dev/null || true)"
  # Sanitize: strip tabs/newlines from desc
  DESC="$(printf -- '%s' "$DESC" | tr '\t\n' '  ')"
  printf -- '%s\tBG_SPAWN\t%s\n' "$TS" "$DESC" >> "$LEDGER_FILE"

elif [[ "$TOOL_NAME" == "Monitor" ]]; then
  printf -- '%s\tWATCHDOG\t(monitor)\n' "$TS" >> "$LEDGER_FILE"
fi

exit 0
