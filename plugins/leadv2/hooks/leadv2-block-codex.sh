#!/usr/bin/env bash
# PreToolUse hook: enforce Codex policy from .claude/leadv2-overrides/codex-policy.yaml.
# If codex_enabled: false (default), blocks Agent(subagent_type=codex:*) and Bash codex/codex-task.sh calls.
set -euo pipefail
trap 'echo "[$(basename "$0")] error at line $LINENO" >&2; exit 0' ERR

INPUT="$(cat 2>/dev/null || true)"
[[ -z "$INPUT" ]] && exit 0

CWD="$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || echo "")"
[[ -z "$CWD" ]] && CWD="$PWD"

# Find project root + codex policy file
PROJECT_ROOT="${CLAUDE_PROJECT_ROOT:-$(cd "$CWD" && git rev-parse --show-toplevel 2>/dev/null || echo "$CWD")}"
POLICY="$PROJECT_ROOT/.claude/leadv2-overrides/codex-policy.yaml"

# Default: codex disabled (must opt in via policy file)
CODEX_ENABLED="false"
if [[ -f "$POLICY" ]]; then
  if grep -qE '^[[:space:]]*codex_enabled:[[:space:]]*true' "$POLICY" 2>/dev/null; then
    CODEX_ENABLED="true"
  fi
fi

# If codex is enabled per policy, allow everything
[[ "$CODEX_ENABLED" == "true" ]] && exit 0

TOOL_NAME="$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || echo "")"

# Agent tool — check subagent_type for codex
if [[ "$TOOL_NAME" == "Agent" ]]; then
  SUBTYPE="$(echo "$INPUT" | jq -r '.tool_input.subagent_type // empty' 2>/dev/null || echo "")"
  if [[ "$SUBTYPE" == codex:* || "$SUBTYPE" == *codex* ]]; then
    cat >&2 <<MSG
[leadv2-block-codex] BLOCKED
Codex is disabled in this project (codex_enabled: false in $POLICY, or file missing).
Detected subagent_type: $SUBTYPE

To enable Codex 2nd-brain reviews:
  echo 'codex_enabled: true' > $POLICY
MSG
    exit 2
  fi
fi

# Bash tool — check for codex CLI invocation
if [[ "$TOOL_NAME" == "Bash" ]]; then
  CMD="$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || echo "")"
  if echo "$CMD" | grep -qE '(^|[^a-zA-Z0-9_])codex($|[^a-zA-Z0-9_])|codex-task\.sh|codex-companion'; then
    cat >&2 <<MSG
[leadv2-block-codex] BLOCKED
Codex CLI invocation detected, but codex_enabled is false (or $POLICY missing).
Command: $(echo "$CMD" | head -c 200)

To enable: echo 'codex_enabled: true' > $POLICY
MSG
    exit 2
  fi
fi

exit 0
