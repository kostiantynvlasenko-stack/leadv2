#!/usr/bin/env bash
# UserPromptSubmit hook — suppress content-free teammate idle_notification wakes.
#
# WHY: in a multi-teammate session (/leadv2 supervise, agent-team mode), the harness
# auto-delivers an idle_notification message from every teammate each time it stops
# (idleReason "available"|"failed"). The InboxPoller batches pending mailbox messages
# and submits them through the SAME onSubmitMessage/UserPromptSubmit pipeline used for
# real user prompts -- so a content-free "I'm idle, nothing to report" ping forces a
# full model turn on the whole session context, exactly like a real prompt would.
# One session burned ~10 such wakes in one night; the lead compensating by remembering
# not to reply verbosely does NOT save the turn -- it's already spent by delivery time.
#
# MECHANISM: this hook runs at UserPromptSubmit, the one point BEFORE the API call
# where the submission can still be rejected outright (exit code 2 => "block
# processing, erase original prompt" per the hooks contract -- no model call happens).
# We parse every <teammate-message teammate_id="..." ...>...</teammate-message> block
# in the prompt; only if EVERY block is a well-formed idle_notification with
# idleReason=="available" (no failureReason, no meaningful summary) do we block.
#
# SAFETY (hard requirement): idleReason=="failed", any parse error, any non-idle
# message type (task_completed, teammate_terminated, shutdown_request, plan
# approval, a real report/summary), or ANY leftover text outside recognized blocks
# -> fail OPEN (exit 0, let it through unchanged). We would rather spend an
# unnecessary turn than silently swallow a failure or a report the lead must act on.
#
# KNOWN LIMITATION (see idle-wake-fix.md): the InboxPoller re-queues a blocked
# submission client-side and retries on the next idle poll tick (~1s). Repeated
# hook invocations are cheap (no LLM cost) but the "pending" message never
# self-clears from local session state -- documented, not solved, here.
#
# Override: LEADV2_IDLE_FILTER=0 disables this hook entirely.

set -euo pipefail
trap 'echo "[$(basename "$0")] internal error at line $LINENO -- failing open" >&2; exit 0' ERR

[[ "${LEADV2_IDLE_FILTER:-1}" == "0" ]] && exit 0

INPUT="$(cat 2>/dev/null || true)"
[[ -z "$INPUT" ]] && exit 0

# Fast fail-open: nothing that looks like a teammate idle ping -> don't even parse.
case "$INPUT" in
  *teammate-message*idle_notification*) ;;
  *) exit 0 ;;
esac

VERDICT="$(python3 -c "
import sys, json, re

try:
    hook_input = json.loads(sys.argv[1])
    prompt = hook_input.get('prompt') or ''
except Exception:
    print('ALLOW:parse-error-hook-input')
    sys.exit(0)

if not prompt:
    print('ALLOW:empty-prompt')
    sys.exit(0)

block_re = re.compile(
    r'<teammate-message\s+teammate_id=\"([^\"]*)\"[^>]*>(.*?)</teammate-message>',
    re.DOTALL,
)
matches = list(block_re.finditer(prompt))
if not matches:
    print('ALLOW:no-teammate-blocks')
    sys.exit(0)

# Any text outside the matched blocks (beyond whitespace) -> don't touch it.
stripped = block_re.sub('', prompt).strip()
if stripped:
    print('ALLOW:leftover-text-outside-blocks')
    sys.exit(0)

names = []
for _, body in [(m.group(1), m.group(2)) for m in matches]:
    text = body.strip()
    try:
        payload = json.loads(text)
    except Exception:
        print('ALLOW:block-not-json')
        sys.exit(0)
    if not isinstance(payload, dict):
        print('ALLOW:block-not-object')
        sys.exit(0)
    if payload.get('type') != 'idle_notification':
        print(f\"ALLOW:non-idle-type={payload.get('type')}\")
        sys.exit(0)
    if payload.get('idleReason') != 'available':
        print(f\"ALLOW:idle-reason={payload.get('idleReason')}\")
        sys.exit(0)
    if payload.get('failureReason'):
        print('ALLOW:has-failure-reason')
        sys.exit(0)
    summary = (payload.get('summary') or '').strip()
    if summary:
        print(f'ALLOW:has-summary')
        sys.exit(0)
    names.append(payload.get('from') or '?')

print('BLOCK:' + ','.join(names))
" "$INPUT" 2>/dev/null || echo "ALLOW:python-exec-error")"

case "$VERDICT" in
  BLOCK:*)
    NAMES="${VERDICT#BLOCK:}"
    printf '%s|idle-notification-filter|suppressed|%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$NAMES" >> /tmp/leadv2-idle-notification-filter.log 2>/dev/null || true
    echo "leadv2: suppressed content-free idle_notification (idleReason=available, no report) from: ${NAMES}. Not a wake-worthy event." >&2
    exit 2
    ;;
  *)
    exit 0
    ;;
esac
