#!/usr/bin/env bash
# PreToolUse:Write — block subagent from writing .summary.md without strict verdict YAML block.
# Subagent contract: first 10 lines must contain `verdict:` and `next_action:` keys.
#
# Override: append `# verdict-guard: allow` to file content first line.

set -euo pipefail
trap 'echo "[$(basename "$0")] error at line $LINENO" >&2; exit 0' ERR

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

# Enforce on any handoff verdict file (.summary.md OR phase-named .md)
# Subagents were bypassing the guard by writing build.md / review.md / verify.md / deploy.md directly.
case "$FILE_PATH" in
  */docs/handoff/*/*.summary.md) ;;
  */docs/handoff/*/intake.md) ;;
  */docs/handoff/*/classify.md) ;;
  */docs/handoff/*/plan.md) ;;
  */docs/handoff/*/build.md) ;;
  */docs/handoff/*/review.md) ;;
  */docs/handoff/*/verify.md) ;;
  */docs/handoff/*/deploy.md) ;;
  */docs/handoff/*/gate1.md) ;;
  */docs/handoff/*/gate2.md) ;;
  */docs/handoff/*/close.md) ;;
  *) exit 0 ;;
esac

CONTENT="$(printf '%s' "$INPUT" | python3 -c "
import sys, json
try:
    r = json.loads(sys.stdin.read())
    print(r.get('tool_input', {}).get('content', ''))
except Exception:
    pass
" 2>/dev/null || true)"

[[ -z "$CONTENT" ]] && exit 0

# Override
HEAD_TWO="$(printf '%s' "$CONTENT" | head -2)"
if echo "$HEAD_TWO" | grep -q "verdict-guard: allow"; then exit 0; fi

# Validate: must have verdict: and next_action: in first 10 lines
HEAD_TEN="$(printf '%s' "$CONTENT" | head -10)"
HAS_VERDICT=0
HAS_NEXT=0
echo "$HEAD_TEN" | grep -qE '^verdict:[[:space:]]*(APPROVE|REVISE|NEEDS-INFO|BLOCK)' && HAS_VERDICT=1
echo "$HEAD_TEN" | grep -qE '^next_action:' && HAS_NEXT=1

if [[ "$HAS_VERDICT" -eq 1 && "$HAS_NEXT" -eq 1 ]]; then
  exit 0
fi

cat <<MSG >&2
[leadv2-verdict-format-guard] .summary.md missing strict verdict YAML block.
  file: $FILE_PATH

First 10 lines MUST contain:
  verdict: APPROVE | REVISE | NEEDS-INFO | BLOCK
  next_action: <one of: deploy | review_round_2 | escalate_to_founder | abort | continue>

Lead reads ONLY this block. Without it, lead can't dispatch — task stalls.

Override: prepend "# verdict-guard: allow" to content (first line).
MSG
exit 2
