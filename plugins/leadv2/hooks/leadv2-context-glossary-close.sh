#!/usr/bin/env bash
# leadv2-context-glossary-close.sh — PreToolUse:Bash advisory hook.
#
# Fires on the same "chore: close TASK-ID"-style git commit that
# leadv2-close-ritual-guard.sh gates. If the staged diff appears to
# introduce new domain vocabulary (new class/def/interface/table
# definitions or new ALL-CAPS/CamelCase glossary-shaped terms) and the
# repo has a CONTEXT.md, print a reminder to run the `domain-modeling`
# skill to update it. ADVISORY ONLY — never blocks the commit.
#
# Modeled on leadv2-close-ritual-guard.sh (close-commit detection) and
# leadv2-plugin-sync-drift-warn.sh (warn-only, always exit 0).
#
# lean: vocab-detection is a coarse grep heuristic (new class/def/
# interface/CREATE TABLE lines in the staged diff), not a real NLP/glossary
# diff — upgrade when domain-modeling exposes a `--check-diff` mode that
# can compare against CONTEXT.md's existing glossary terms directly.

set -euo pipefail
trap 'echo "[$(basename "$0")] error at line $LINENO, allowing" >&2; exit 0' ERR

INPUT="$(cat 2>/dev/null || true)"
[[ -z "$INPUT" ]] && exit 0

CWD="$(printf '%s' "$INPUT" | python3 -c "
import sys, json
try:
    r = json.loads(sys.stdin.read())
    print(r.get('cwd', ''))
except Exception:
    pass
" 2>/dev/null || true)"
[[ -z "$CWD" ]] && CWD="$PWD"

CMD="$(printf '%s' "$INPUT" | python3 -c "
import sys, json
try:
    r = json.loads(sys.stdin.read())
    print(r.get('tool_input', {}).get('command', ''))
except Exception:
    pass
" 2>/dev/null || true)"
[[ -z "$CMD" ]] && exit 0

# Only care about git commit invocations.
echo "$CMD" | grep -qE '^git\s+commit' 2>/dev/null || exit 0

# Only fire on close-style commit messages (mirrors leadv2-close-ritual-guard.sh).
MSG="$(echo "$CMD" | sed -E 's/.*(-m|--message)[= ]"([^"]+)".*/\2/' 2>/dev/null || echo "")"
[[ -z "$MSG" ]] && MSG="$(echo "$CMD" | sed -E "s/.*(-m|--message)[= ]'([^']+)'.*/\2/" 2>/dev/null || echo "")"
[[ -z "$MSG" ]] && exit 0

CLOSE_MATCH="$(echo "$MSG" | grep -oiE '(chore|docs|feat|fix):[[:space:]]*close[[:space:]]+[A-Z][A-Z0-9-]+-[0-9]+' | head -1 || echo "")"
[[ -z "$CLOSE_MATCH" ]] && exit 0

# No CONTEXT.md at repo root → nothing to remind about.
[[ -f "${CWD}/CONTEXT.md" ]] || exit 0

# Best-effort: does the staged diff introduce new symbol/table-shaped vocab?
DIFF="$(cd "$CWD" && git diff --cached -U0 2>/dev/null || true)"
[[ -z "$DIFF" ]] && exit 0

if echo "$DIFF" | grep -qE '^\+[[:space:]]*(class[[:space:]]+\w+|def[[:space:]]+\w+|interface[[:space:]]+\w+|CREATE TABLE[[:space:]]+\w+)'; then
  printf -- '[leadv2-context-glossary-close] This close commit adds new domain vocab (new class/def/interface/table). Run the "domain-modeling" skill to update CONTEXT.md if any of these are new ubiquitous-language terms. Advisory only, not blocking.\n' >&2
fi

exit 0
