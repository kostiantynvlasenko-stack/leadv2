#!/usr/bin/env bash
# PreToolUse:Bash — deny-floor: blocks unambiguously-destructive commands
# EVEN under Codex danger-full-access. off_limits/hack-detection are
# post-hoc review-phase only today; this is a pre-execution hard floor.
#
# Patterns live in config/leadv2-deny-patterns.yaml (conservative, few rules,
# individually toggleable). Fail-open on any hook-internal error.
#
# Kill-switch: LEADV2_DENY_FLOOR=0 disables the whole hook (bypasses
# EVERY rule, including catastrophic ones).
# Inline override: append "# deny-floor: allow" to the command to bypass —
# but ONLY for rules marked allow_inline_override: true in the patterns
# yaml (SOFT rules: git reset --hard, git clean, git stash). CATASTROPHIC
# rules (rm -rf root/home, mkfs, dd/redirect to a raw device, chmod -R 777
# /, force-push to main) ignore the inline comment entirely — only the
# kill-switch can bypass them.
set -euo pipefail
trap 'echo "[$(basename "$0")] error at line $LINENO" >&2; exit 0' ERR

# Kill-switch — checked before reading stdin so it always short-circuits.
if [[ "${LEADV2_DENY_FLOOR:-1}" == "0" ]]; then
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATTERNS_FILE="${LEADV2_DENY_PATTERNS_FILE:-${SCRIPT_DIR}/../config/leadv2-deny-patterns.yaml}"

INPUT="$(cat 2>/dev/null || true)"
[[ -z "$INPUT" ]] && exit 0

CMD=$(printf '%s' "$INPUT" | python3 -c "
import sys, json
try:
    r = json.loads(sys.stdin.read())
    print(r.get('tool_input', {}).get('command', ''))
except Exception:
    pass
" 2>/dev/null || true)

[[ -z "$CMD" ]] && exit 0

HAS_INLINE_ALLOW=0
if printf '%s' "$CMD" | grep -q '# deny-floor: allow'; then
  HAS_INLINE_ALLOW=1
fi

[[ -f "$PATTERNS_FILE" ]] || exit 0

# Match CMD against every enabled rule in the yaml. Simple line-based parse
# (no PyYAML dependency) — the yaml is a flat, hand-authored list under
# `rules:`, one mapping per `- name:` block.
RESULT=$(python3 -c "
import re, sys

cmd = sys.argv[1]
patterns_file = sys.argv[2]

try:
    with open(patterns_file, 'r') as f:
        lines = f.readlines()
except Exception:
    sys.exit(0)

rules = []
cur = {}
for raw in lines:
    line = raw.rstrip('\n')
    stripped = line.strip()
    if stripped.startswith('- name:'):
        if cur.get('name'):
            rules.append(cur)
        cur = {'name': stripped.split(':', 1)[1].strip().strip('\"\'')}
    elif stripped.startswith('regex:') and cur:
        val = stripped.split(':', 1)[1].strip()
        if (val.startswith(\"'\") and val.endswith(\"'\")) or (val.startswith('\"') and val.endswith('\"')):
            val = val[1:-1]
        cur['regex'] = val
    elif stripped.startswith('enabled:') and cur:
        val = stripped.split(':', 1)[1].strip().lower()
        cur['enabled'] = (val == 'true')
    elif stripped.startswith('allow_inline_override:') and cur:
        val = stripped.split(':', 1)[1].strip().lower()
        cur['allow_inline_override'] = (val == 'true')
    elif stripped.startswith('message:') and cur:
        val = stripped.split(':', 1)[1].strip()
        if (val.startswith(\"'\") and val.endswith(\"'\")) or (val.startswith('\"') and val.endswith('\"')):
            val = val[1:-1]
        cur['message'] = val
if cur.get('name'):
    rules.append(cur)

for r in rules:
    if not r.get('enabled', False):
        continue
    regex = r.get('regex')
    if not regex:
        continue
    try:
        if re.search(regex, cmd, re.IGNORECASE):
            allow_override = 'true' if r.get('allow_inline_override', False) else 'false'
            print(r.get('name', 'unknown') + '|' + allow_override + '|' + r.get('message', 'Blocked by deny-floor.'))
            sys.exit(0)
    except re.error:
        continue
" "$CMD" "$PATTERNS_FILE" 2>/dev/null || true)

[[ -z "$RESULT" ]] && exit 0

RULE_NAME="${RESULT%%|*}"
REST="${RESULT#*|}"
RULE_ALLOW_OVERRIDE="${REST%%|*}"
RULE_MSG="${REST#*|}"

# Inline override only bypasses rules explicitly marked
# allow_inline_override: true (SOFT rules). CATASTROPHIC rules ignore the
# inline comment entirely — only LEADV2_DENY_FLOOR=0 bypasses those.
if [[ "$HAS_INLINE_ALLOW" == "1" && "$RULE_ALLOW_OVERRIDE" == "true" ]]; then
  exit 0
fi

cat <<MSG >&2
[leadv2-deny-floor] BLOCKED: command matches deny-floor rule '${RULE_NAME}'.
${RULE_MSG}

This floor applies even under Codex danger-full-access — it is not a review
heuristic, it is a hard pre-execution stop on irreversible operations.

If this is a genuine false positive:
$(if [[ "$RULE_ALLOW_OVERRIDE" == "true" ]]; then
  printf -- '  - append "# deny-floor: allow" to the command (rare, one-off), or\n'
else
  printf -- '  - this rule is CATASTROPHIC-tier: the inline "# deny-floor: allow" comment does NOT bypass it,\n'
fi)
  - use ask-lead.sh to raise an off_limits/decision conflict for a durable fix.
MSG
exit 2
