#!/usr/bin/env bash
# leadv2-bash-lint-pre-gate.sh
# PreToolUse hook: run bash -n on staged .sh files before git commit.
# Catches syntax errors (apostrophes, mismatched quotes) before Codex review.
# PO-027: 4 review rounds wasted because bash -n would have caught the bug.
#
# Hook mode: reads JSON from stdin, emits JSON to stdout.
# Manual mode: bash leadv2-bash-lint-pre-gate.sh <task-id>
#
# Skip conditions:
#   - No .sh or shell-shebang files in staged diff
#   - LEADV2_TASK_ID is empty AND not in manual mode (pure non-leadv2 commit)

set -euo pipefail
trap 'exit 0' ERR

HOOK_NAME="leadv2-bash-lint-pre-gate"

# ── helpers ────────────────────────────────────────────────────────────────────

log_block() {
  printf -- '[%s] BLOCK: %s\n' "$HOOK_NAME" "$*" >&2
}

is_shell_shebang() {
  local file="$1"
  [[ -f "$file" ]] || return 1
  local first_line
  first_line=$(head -1 "$file" 2>/dev/null || true)
  case "$first_line" in
    "#!/bin/bash"*|"#!/usr/bin/env bash"*|"#!/bin/sh"*|"#!/usr/bin/env sh"*) return 0 ;;
    *) return 1 ;;
  esac
}

# ── mode detection ─────────────────────────────────────────────────────────────

MANUAL_MODE=0
TASK_ID=""

if [[ $# -gt 0 ]]; then
  MANUAL_MODE=1
  TASK_ID="${1:-}"
else
  # Hook mode: read stdin JSON to detect the command
  INPUT=$(cat)

  # Extract the bash command being run
  TOOL_CMD=$(printf -- '%s' "$INPUT" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('tool_input', {}).get('command', ''))
except Exception:
    print('')
" 2>/dev/null || true)

  # Only gate on git commit commands
  case "$TOOL_CMD" in
    *"git commit"*) : ;;
    *)
      printf -- '{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "allow"}}\n'
      exit 0
      ;;
  esac

  TASK_ID="${LEADV2_TASK_ID:-}"
fi

# ── skip if no LEADV2_TASK_ID in hook mode ─────────────────────────────────────

if [[ "$MANUAL_MODE" -eq 0 && -z "$TASK_ID" ]]; then
  printf -- '{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "allow"}}\n'
  exit 0
fi

# ── collect staged shell files ─────────────────────────────────────────────────

STAGED_FILES=()
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  case "$f" in
    *.sh) STAGED_FILES+=("$f") ;;
    *)
      if is_shell_shebang "$f"; then
        STAGED_FILES+=("$f")
      fi
      ;;
  esac
done < <(git diff --name-only --cached 2>/dev/null || true)

if [[ ${#STAGED_FILES[@]} -eq 0 ]]; then
  if [[ "$MANUAL_MODE" -eq 1 ]]; then
    printf -- '[%s] No shell files in staged diff — skip\n' "$HOOK_NAME" >&2
    exit 0
  fi
  printf -- '{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "allow"}}\n'
  exit 0
fi

# ── run bash -n on each file ───────────────────────────────────────────────────

FAIL_DETAILS=()

for f in "${STAGED_FILES[@]}"; do
  if [[ ! -f "$f" ]]; then
    continue
  fi
  ERROR_OUTPUT=$(bash -n "$f" 2>&1) && RC=0 || RC=$?
  if [[ $RC -ne 0 ]]; then
    FAIL_DETAILS+=("$f: $ERROR_OUTPUT")
    log_block "syntax error in $f: $ERROR_OUTPUT"
  fi
done

# ── emit result ────────────────────────────────────────────────────────────────

if [[ ${#FAIL_DETAILS[@]} -eq 0 ]]; then
  if [[ "$MANUAL_MODE" -eq 1 ]]; then
    printf -- '[%s] All %d shell file(s) passed bash -n\n' "$HOOK_NAME" "${#STAGED_FILES[@]}" >&2
    exit 0
  fi
  printf -- '{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "allow"}}\n'
  exit 0
fi

# Build reason string
REASON="Shell syntax errors found (fix before commit):"
for detail in "${FAIL_DETAILS[@]}"; do
  REASON="$REASON  |  $detail"
done

if [[ "$MANUAL_MODE" -eq 1 ]]; then
  log_block "$REASON"
  exit 1
fi

python3 -c "
import json, sys
reason = sys.argv[1]
out = {
    'hookSpecificOutput': {
        'hookEventName': 'PreToolUse',
        'permissionDecision': 'deny',
        'permissionDecisionReason': reason
    }
}
print(json.dumps(out))
" "$REASON"
