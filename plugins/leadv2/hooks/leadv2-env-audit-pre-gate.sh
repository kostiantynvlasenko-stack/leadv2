#!/usr/bin/env bash
# leadv2-env-audit-pre-gate.sh
# PreToolUse hook: catch missing .env vars before deploy.
# BUG-POSTS-01 + OPS-BOOTSTRAP failed because PE_GROUNDING_GATE_ENABLED /
# SUPABASE_SERVICE_ROLE_KEY were in code but absent from bootstrap+control-sync.
#
# Trigger: PreToolUse Bash when command matches deploy-latest.sh or deploy.sh
# Override: ENV_AUDIT_OVERRIDE=1 to allow despite findings.
#
# Hook mode: reads JSON stdin, emits JSON stdout.
# Manual mode: bash leadv2-env-audit-pre-gate.sh
#
# Fix BUG-ENV-AUDIT-NOISE-01:
#   1. ${VAR:-default} references are optional -- excluded from critical check.
#   2. PE_TEST_* and PE_EPOCH_* vars are dev/test allowlist -- silently skipped.
#   3. Only bare ${VAR} / $VAR (no default) AND not in allowlist -> flagged.

set -euo pipefail
trap 'exit 0' ERR

HOOK_NAME="leadv2-env-audit-pre-gate"
REPO="/Users/kostiantyn.vlasenko/Projects/persona-engine"

# ── PO-064: profiling ───────────────────────────────────────────────────────
_HOOK_START_MS=0
if [[ "${LEADV2_HOOK_PROFILE:-0}" == "1" ]]; then
  _HOOK_START_MS=$(python3 -c "import time; print(int(time.time()*1000))" 2>/dev/null || echo 0)
fi
_hook_profile_end() {
  if [[ "${LEADV2_HOOK_PROFILE:-0}" == "1" && "$_HOOK_START_MS" -gt 0 ]]; then
    local end_ms
    end_ms=$(python3 -c "import time; print(int(time.time()*1000))" 2>/dev/null || echo 0)
    local dur=$(( end_ms - _HOOK_START_MS ))
    mkdir -p "$HOME/.claude/state/leadv2"
    printf '%s,%s\n' "$HOOK_NAME" "$dur" \
      >> "$HOME/.claude/state/leadv2/hook-profile.log"
  fi
}
trap '_hook_profile_end; exit 0' EXIT

log_block() {
  printf -- '[%s] BLOCK: %s\n' "$HOOK_NAME" "$*" >&2
}

# -- known shell builtins / system vars to exclude --------------------------------

KNOWN_BUILTINS=(
  HOME PATH USER PWD CWD SHELL TERM HOSTNAME PYTHONPATH
  OLDPWD SHLVL LOGNAME TMPDIR LANG LC_ALL LC_CTYPE
  IFS BASH BASH_VERSION EUID UID GID PPID LINENO SECONDS
  RANDOM PIPESTATUS FUNCNAME BASH_SOURCE BASH_LINENO
  PS1 PS2 PS3 PS4 PROMPT_COMMAND HISTFILE HISTSIZE HISTFILESIZE
  VIRTUAL_ENV CONDA_DEFAULT_ENV CONDA_PREFIX
  NVM_DIR NODE_PATH npm_config_prefix
  JAVA_HOME GOPATH GOROOT
  SSH_AUTH_SOCK SSH_AGENT_PID
  DISPLAY XTERM_VERSION
  LEADV2_TASK_ID LEADV2_MAIN_MODEL DRY_RUN DEBUG VERBOSE
  ENV_AUDIT_OVERRIDE CI GITHUB_ACTIONS RUNNER_OS
)

builtin_set() {
  local var="$1"
  for b in "${KNOWN_BUILTINS[@]}"; do
    [[ "$b" == "$var" ]] && return 0
  done
  return 1
}

# -- dev/test allowlist: silently skipped regardless of whitelist -----------------
# Covers PE_TEST_*, PE_EPOCH_*, and specific known dev vars.

dev_test_var() {
  local var="$1"
  case "$var" in
    PE_TEST_*|PE_EPOCH_*|PE_TEST_NO_SLEEP|PE_EPOCH_OVERRIDE)
      return 0
      ;;
  esac
  return 1
}

# -- mode detection ---------------------------------------------------------------

MANUAL_MODE=0
if [[ $# -gt 0 ]]; then
  MANUAL_MODE=1
else
  INPUT=$(cat)

  TOOL_CMD=$(printf -- '%s' "$INPUT" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('tool_input', {}).get('command', ''))
except Exception:
    print('')
" 2>/dev/null || true)

  case "$TOOL_CMD" in
    *"deploy-latest.sh"*|*"deploy.sh"*) : ;;
    *)
      printf -- '{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "allow"}}\n'
      exit 0
      ;;
  esac
fi

# -- override check ---------------------------------------------------------------

INLINE_OVERRIDE=0
if [[ "$MANUAL_MODE" -eq 0 ]] && [[ "$TOOL_CMD" == *"ENV_AUDIT_OVERRIDE=1"* ]]; then
  INLINE_OVERRIDE=1
fi

if [[ "${ENV_AUDIT_OVERRIDE:-0}" == "1" ]] || [[ "$INLINE_OVERRIDE" -eq 1 ]]; then
  printf -- '[%s] ENV_AUDIT_OVERRIDE=1 -- skipping audit\n' "$HOOK_NAME" >&2
  if [[ "$MANUAL_MODE" -eq 0 ]]; then
    printf -- '{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "allow"}}\n'
  fi
  exit 0
fi

# -- extract CODE_VARS from platform/ and agent/ ----------------------------------
# Only collect bare ${VAR} / $VAR references WITHOUT a :- default.
# ${VAR:-...} are optional (have a fallback) and must NOT be flagged.

CODE_VARS_FILE=$(mktemp)
trap 'rm -f "$CODE_VARS_FILE"' EXIT

# Bash/shell: match full token, exclude any that contain ":-" (optional-with-default).
grep -roh --include="*.sh" --include="*.py" --include="*.env*" \
  -E '\$\{[A-Z][A-Z0-9_]{1,}[^}]*\}|\$[A-Z][A-Z0-9_]{1,}' \
  "$REPO/platform/" "$REPO/agent/" 2>/dev/null \
  | grep -v ':-' \
  | grep -oE '[A-Z][A-Z0-9_]{1,}' \
  | sort -u > "$CODE_VARS_FILE" || true

# Python: os.environ.get("VAR") and os.environ["VAR"] -- always required.
grep -roh --include="*.py" \
  -E 'os\.environ(?:\.get)?\("([A-Z][A-Z0-9_]{1,})"' \
  "$REPO/platform/" "$REPO/agent/" 2>/dev/null \
  | grep -oE '"[A-Z][A-Z0-9_]{1,}"' \
  | tr -d '"' \
  | sort -u >> "$CODE_VARS_FILE" || true

sort -u "$CODE_VARS_FILE" -o "$CODE_VARS_FILE"

# -- extract MANAGED_VARS from bootstrap + control-sync + .env.example -----------

MANAGED_VARS_FILE=$(mktemp)
trap 'rm -f "$CODE_VARS_FILE" "$MANAGED_VARS_FILE"' EXIT

for f in \
  "$REPO/agent/deploy/bootstrap.sh" \
  "$REPO/agent/deploy/control-sync.sh" \
  "$REPO/agent/deploy/control-sync.timer" \
  "$REPO/.env.example" \
  "$REPO/agent/.env.example"
do
  [[ -f "$f" ]] || continue
  grep -oE '^[A-Z][A-Z0-9_]+=|export [A-Z][A-Z0-9_]+=|\$\{?([A-Z][A-Z0-9_]{1,})\}?' "$f" 2>/dev/null \
    | grep -oE '[A-Z][A-Z0-9_]{1,}' \
    | sort -u >> "$MANAGED_VARS_FILE" || true
done

find "$REPO/personas" -name ".env.example" 2>/dev/null | while IFS= read -r f; do
  grep -oE '^[A-Z][A-Z0-9_]+=' "$f" 2>/dev/null | tr -d '=' >> "$MANAGED_VARS_FILE" || true
done

sort -u "$MANAGED_VARS_FILE" -o "$MANAGED_VARS_FILE"

# -- compute MISSING = CODE_VARS - MANAGED_VARS - builtins - dev_test allowlist --

MISSING=()
while IFS= read -r var; do
  [[ -z "$var" ]] && continue
  builtin_set "$var" && continue
  dev_test_var "$var" && continue
  grep -qxF "$var" "$MANAGED_VARS_FILE" && continue
  MISSING+=("$var")
done < "$CODE_VARS_FILE"

# -- filter to sensitive prefixes only --------------------------------------------

CRITICAL_MISSING=()
for var in "${MISSING[@]}"; do
  case "$var" in
    PE_*|SUPABASE_*|THREADS_*|ANTHROPIC_*|OPENAI_*|QDRANT_*|PADDLE_*)
      CRITICAL_MISSING+=("$var")
      ;;
  esac
done

# -- emit result ------------------------------------------------------------------

if [[ ${#CRITICAL_MISSING[@]} -eq 0 ]]; then
  if [[ "$MANUAL_MODE" -eq 1 ]]; then
    printf -- '[%s] No critical missing env vars found\n' "$HOOK_NAME" >&2
    exit 0
  fi
  printf -- '{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "allow"}}\n'
  exit 0
fi

MISSING_LIST=$(printf -- '%s\n' "${CRITICAL_MISSING[@]}" | tr '\n' ' ')
REASON="Env audit: vars referenced in code but absent from bootstrap/control-sync: $MISSING_LIST -- set ENV_AUDIT_OVERRIDE=1 to bypass"
log_block "$REASON"

if [[ "$MANUAL_MODE" -eq 1 ]]; then
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
