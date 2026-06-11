#!/usr/bin/env bash
# PreToolUse:Agent — routing guard.
# Two policies:
#   1. LEAD path: WARN-ONLY when architect/critic/security-auditor spawned on sonnet.
#      Recommends Codex-first (or Opus-only on m3-market) per codex-policy.yaml.
#      NEVER blocks (exits 0). Safe for all repos including m3-market.
#   2. SUBAGENT NESTED-SPAWN path (v2.1.172+): caller has agent_type in hook input.
#      ALLOW only Explore|general-purpose with explicit model=haiku|sonnet.
#      DENY all other nested spawns with actionable message (exits 2).
set -euo pipefail
trap 'exit 0' ERR

INPUT="$(cat 2>/dev/null || true)"
[[ -z "$INPUT" ]] && exit 0

# Parse fields from hook input JSON: agent_type (present for subagents, absent for lead),
# tool_input.subagent_type, tool_input.model
# NOTE: use python3 -c passing INPUT via argv to avoid heredoc+pipe stdin conflict.
PARSED="$(python3 -c "
import sys, json
try:
    d = json.loads(sys.argv[1])
    inp = d.get('tool_input') or {}
    caller_agent_type = (d.get('agent_type') or '').strip().lower()
    stype = (inp.get('subagent_type') or '').strip().lower()
    model = (inp.get('model') or '').strip().lower()
    print(caller_agent_type)
    print(stype)
    print(model)
except Exception:
    pass
" "$INPUT" 2>/dev/null || true)"

CALLER_AGENT_TYPE="$(printf -- '%s' "$PARSED" | sed -n '1p')"
SUBAGENT_TYPE="$(printf -- '%s' "$PARSED" | sed -n '2p')"
MODEL="$(printf -- '%s' "$PARSED" | sed -n '3p')"

# ── NESTED-SPAWN POLICY (caller is a subagent) ────────────────────────────────
# agent_type is injected by Claude Code only for subagent callers; lead has no agent_type.
if [[ -n "$CALLER_AGENT_TYPE" ]]; then
  # Allow only: (Explore OR general-purpose) AND model explicitly haiku OR sonnet
  STYPE_OK="false"
  MODEL_OK="false"
  case "$SUBAGENT_TYPE" in
    explore|general-purpose) STYPE_OK="true" ;;
  esac
  case "$MODEL" in
    *haiku*|*sonnet*) MODEL_OK="true" ;;
  esac

  if [[ "$STYPE_OK" == "true" && "$MODEL_OK" == "true" ]]; then
    exit 0  # allowed nested discovery probe
  fi

  cat >&2 <<MSG
[leadv2-routing-guard] DENIED nested spawn.
nested spawns: Explore/general-purpose with explicit model=haiku|sonnet only.
Got subagent_type="${SUBAGENT_TYPE}" model="${MODEL}". Use ask-lead.sh graph proxy for other discovery.
MSG
  exit 2
fi

# ── LEAD PATH (no agent_type → caller is lead) ────────────────────────────────
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
