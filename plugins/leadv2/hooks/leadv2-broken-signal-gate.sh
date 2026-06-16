#!/usr/bin/env bash
# UserPromptSubmit hook — detect broken-signal words in prompt and inject an advisory
# directing lead to open a NEW task (Phase 0 Intake) rather than resuming the current one.
#
# NON-BLOCKING: exit 0 always. Injects additionalContext when broken-signal matched.
# Fail-safe: any internal error exits 0 (never blocks the session on hook crash).
#
# Override: LEADV2_BROKEN_GATE=0 disables this hook entirely.

set -euo pipefail
trap 'echo "[$(basename "$0")] internal error at line $LINENO -- continuing" >&2; exit 0' ERR

[[ "${LEADV2_BROKEN_GATE:-1}" == "0" ]] && exit 0

INPUT="$(cat 2>/dev/null || true)"
[[ -z "$INPUT" ]] && exit 0

# Parse hook input -- extract prompt text via python3 (argv to avoid heredoc+pipe conflict)
PROMPT_TEXT="$(python3 -c "
import sys, json
try:
    r = json.loads(sys.argv[1])
    text = r.get('prompt') or r.get('message') or ''
    print(text)
except Exception:
    pass
" "$INPUT" 2>/dev/null || true)"

[[ -z "$PROMPT_TEXT" ]] && exit 0

# Match broken-signal regex (IGNORECASE via python re.search)
# Regex covers Russian and English broken-signal phrases.
MATCHED="$(python3 -c "
import sys, re
text = sys.argv[1]
regex = (
    r'(?:'
    r'не\s*работает'
    r'|сломал'
    r'|ничего\s*не\s*делает'
    r'|broken'
    r'|persona\s*dead'
    r'|не\s*публикует'
    r'|does\s*n[oa]t\s*work'
    r'|nothing\s*works'
    r'|still\s*broken'
    r'|keeps\s*failing'
    r')'
)
m = re.search(regex, text, re.IGNORECASE)
print('1' if m else '0')
" "$PROMPT_TEXT" 2>/dev/null || true)"

[[ "${MATCHED:-0}" != "1" ]] && exit 0

# Emit additionalContext advisory (non-blocking inject -- exit 0)
python3 -c "
import json
ctx = (
    '[BROKEN-SIGNAL-GATE] Broken-signal detected in prompt.\n'
    'MANDATORY: treat this as a NEW task -- run Phase 0 Intake + Phase 1 Classify + Diverge.\n'
    'Resume of an existing task is FORBIDDEN until founder explicitly says \"resume <task-id>\".\n'
    'Do NOT silently patch the current run. Open a new task slot.\n'
    'Override: LEADV2_BROKEN_GATE=0'
)
print(json.dumps({'additionalContext': ctx}))
" 2>/dev/null || true

exit 0
