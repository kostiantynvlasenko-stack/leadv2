#!/usr/bin/env bash
# PreToolUse:Agent — WARN-ONLY routing guard.
# Fires when architect/critic/security-auditor is spawned on sonnet during plan/review phases.
# Recommends Codex-first (or Opus-only on m3-market) per codex-policy.yaml.
# NEVER blocks (always exits 0). Safe for all repos including m3-market.
set -euo pipefail
trap 'exit 0' ERR

INPUT="$(cat 2>/dev/null || true)"
[[ -z "$INPUT" ]] && exit 0

# Parse subagent_type and model from hook input JSON
PARSED="$(printf -- '%s' "$INPUT" | python3 - 2>/dev/null <<'PY' || true
import sys, json
try:
    d = json.loads(sys.stdin.read())
    inp = d.get("tool_input") or {}
    stype = (inp.get("subagent_type") or "").strip().lower()
    model = (inp.get("model") or "").strip().lower()
    print(stype)
    print(model)
except Exception:
    pass
PY
)"

SUBAGENT_TYPE="$(printf -- '%s' "$PARSED" | sed -n '1p')"
MODEL="$(printf -- '%s' "$PARSED" | sed -n '2p')"

# Only care about these review/plan-brain roles
case "$SUBAGENT_TYPE" in
  architect|critic|security-auditor) ;;
  *) exit 0 ;;
esac

# Only warn when spawned on sonnet (not opus)
case "$MODEL" in
  *sonnet*) ;;
  *) exit 0 ;;
esac

# Resolve repo root from cwd in hook input, fall back to PWD
CWD="$(printf -- '%s' "$INPUT" | python3 -c "
import sys, json
try:
    d = json.loads(sys.stdin.read())
    print((d.get('cwd') or '').strip())
except Exception:
    pass
" 2>/dev/null || true)"
[[ -z "$CWD" ]] && CWD="$PWD"

# Walk up to find git root (repo root)
REPO_ROOT=""
_dir="$CWD"
while [[ "$_dir" != "/" ]]; do
  if [[ -d "$_dir/.git" ]]; then
    REPO_ROOT="$_dir"
    break
  fi
  _dir="$(dirname "$_dir")"
done
[[ -z "$REPO_ROOT" ]] && REPO_ROOT="$CWD"

# Read codex-policy.yaml — default: codex_enabled: true (persona-engine convention)
POLICY_FILE="$REPO_ROOT/.claude/leadv2-overrides/codex-policy.yaml"
CODEX_ENABLED="true"
if [[ -f "$POLICY_FILE" ]]; then
  _val="$(python3 -c "
import sys, re
try:
    src = open('$POLICY_FILE').read()
    m = re.search(r'codex_enabled\s*:\s*(\S+)', src)
    print(m.group(1).lower() if m else 'true')
except Exception:
    print('true')
" 2>/dev/null || echo "true")"
  CODEX_ENABLED="$_val"
fi

# Emit advisory to stderr (warn, never block)
if [[ "$CODEX_ENABLED" == "true" ]]; then
  cat >&2 <<MSG
[leadv2-routing-guard] ADVISORY: ${SUBAGENT_TYPE} spawned on sonnet during plan/review.
Preferred: route plan/review brain to Codex first (zero Claude quota):
  bash ~/.claude/scripts/codex-task.sh <prompt>              # Phase 2 plan
  bash ~/.claude/scripts/codex-task.sh adversarial-review    # Phase 5 review
Or use Agent(${SUBAGENT_TYPE}, model=opus) for high-stakes plan/review.
Sonnet ${SUBAGENT_TYPE} is valid for review R2/R3 rounds (feedback_review_routing).
See: \${CLAUDE_PLUGIN_ROOT}/docs/routing-enforcement.md
MSG
else
  cat >&2 <<MSG
[leadv2-routing-guard] ADVISORY: ${SUBAGENT_TYPE} spawned on sonnet during plan/review.
Codex is DISABLED in this repo (codex_enabled: false in codex-policy.yaml).
Use Agent(${SUBAGENT_TYPE}, model=opus) for plan/review — NOT sonnet.
See: \${CLAUDE_PLUGIN_ROOT}/docs/routing-enforcement.md
MSG
fi

# Always allow — warn only
exit 0
