#!/usr/bin/env bash
# PreToolUse:Agent — routing guard.
# Two policies:
#   1. LEAD path: WARN-ONLY when architect/critic/security-auditor spawned on sonnet.
#      Recommends Codex-first (or Opus-only on m3-market) per codex-policy.yaml.
#      NEVER blocks (exits 0). Safe for all repos including m3-market.
#   2. SUBAGENT NESTED-SPAWN path (v2.1.172+): caller has agent_type in hook input.
#      Policy loaded from config/nested-spawn-policy.yaml (per-repo override wins).
#      Base allowlist: Explore|general-purpose with explicit model=haiku|sonnet.
#      ESCALATION path: types/models outside base allowlist allowed ONLY when
#        docs/handoff/<LEADV2_TASK_ID>/escalation-budget.yaml exists with used < max_escalations
#        and requested type/model appear in allowed_types/allowed_models.
#      DENY all other nested spawns with actionable message (exits 2).
#      Audit: every verdict appended to docs/leadv2/tasks/$LEADV2_TASK_ID/nested-spawns.log
#             (or docs/leadv2/nested-spawns.log when LEADV2_TASK_ID unset).
#      HARDENED CONTRACT (behind LEADV2_NESTED_DEPTH_GATE, default ON; "0" = unchanged):
#        a. DEPTH: max_depth=1 -- a caller that is itself explore|general-purpose
#           (i.e. already a nested sub-run) may not spawn further. reason: route.subrun.depth_exceeded
#        b. TOOL-CLASS: write-capable roles (developer, frontend-developer, postgres-pro,
#           devops-engineer, architect, product-owner) can never be a nested spawn target,
#           even via escalation budget. reason: route.subrun.write_role_denied
#        c. COUNT: max_nested_per_task (default 3), counted from the task audit log.
#           reason: route.subrun.count_exceeded
#      FAIL-SAFE: any internal parse error falls back to built-in defaults
#      (max_depth=1, max_nested_per_task=3) -- never a hard crash of the spawn pipeline.
set -euo pipefail
trap 'exit 0' ERR

INPUT="$(cat 2>/dev/null || true)"
[[ -z "$INPUT" ]] && exit 0

# Resolve plugin root for policy loading
if [[ -n "${CLAUDE_PLUGIN_ROOT:-}" ]]; then
  _LV2_ROOT="${CLAUDE_PLUGIN_ROOT}"
else
  _LV2_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

# Parse fields from hook input JSON: agent_type (present for subagents, absent for lead),
# tool_input.subagent_type, tool_input.model, cwd
# NOTE: use python3 -c passing INPUT via argv to avoid heredoc+pipe stdin conflict.
PARSED="$(python3 -c "
import sys, json
try:
    d = json.loads(sys.argv[1])
    inp = d.get('tool_input') or {}
    caller_agent_type = (d.get('agent_type') or '').strip().lower()
    stype = (inp.get('subagent_type') or '').strip().lower()
    model = (inp.get('model') or '').strip().lower()
    cwd   = (d.get('cwd') or '').strip()
    print(caller_agent_type)
    print(stype)
    print(model)
    print(cwd)
except Exception:
    pass
" "$INPUT" 2>/dev/null || true)"

CALLER_AGENT_TYPE="$(printf -- '%s' "$PARSED" | sed -n '1p')"
SUBAGENT_TYPE="$(printf -- '%s' "$PARSED" | sed -n '2p')"
MODEL="$(printf -- '%s' "$PARSED" | sed -n '3p')"
CWD_FROM_INPUT="$(printf -- '%s' "$PARSED" | sed -n '4p')"

# ── NESTED-SPAWN POLICY (caller is a subagent) ────────────────────────────────
# agent_type is injected by Claude Code only for subagent callers; lead has no agent_type.
if [[ -n "$CALLER_AGENT_TYPE" ]]; then

  # ── Resolve repo root ──────────────────────────────────────────────────────
  _REPO_ROOT=""
  _check_dir="${CWD_FROM_INPUT:-$PWD}"
  while [[ "$_check_dir" != "/" ]]; do
    if [[ -d "$_check_dir/.git" ]]; then
      _REPO_ROOT="$_check_dir"
      break
    fi
    _check_dir="$(dirname "$_check_dir")"
  done
  [[ -z "$_REPO_ROOT" ]] && _REPO_ROOT="${CWD_FROM_INPUT:-$PWD}"

  # Sanitize LEADV2_TASK_ID for filesystem use (strip chars outside A-Za-z0-9._-)
  SAFE_TASK_ID="$(printf -- '%s' "${LEADV2_TASK_ID:-}" | tr -cd 'A-Za-z0-9._-')"

  # ── Audit log helper ───────────────────────────────────────────────────────
  # FIX-NESTED-COUNT-01: writes to GLOBAL log always; also writes to per-task
  # log when LEADV2_TASK_ID is set so leadv2-scorecard-write.sh counts correctly.
  _audit_log() {
    local verdict="$1" reason="$2"
    local ts; ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    local line
    line="$(printf -- '%s caller=%s target=%s model=%s verdict=%s reason=%s\n' \
      "$ts" "$CALLER_AGENT_TYPE" "$SUBAGENT_TYPE" "$MODEL" "$verdict" "$reason")"

    # Always write to global cross-task forensic log
    local global_log_dir="${_REPO_ROOT}/docs/leadv2"
    mkdir -p "$global_log_dir" 2>/dev/null || true
    printf -- '%s\n' "$line" >> "${global_log_dir}/nested-spawns.log" 2>/dev/null || true

    # Also write to per-task log when LEADV2_TASK_ID is set (sanitized — see SAFE_TASK_ID)
    if [[ -n "$SAFE_TASK_ID" ]]; then
      local task_log_dir="${_REPO_ROOT}/docs/leadv2/tasks/${SAFE_TASK_ID}"
      mkdir -p "$task_log_dir" 2>/dev/null || true
      printf -- '%s\n' "$line" >> "${task_log_dir}/nested-spawns.log" 2>/dev/null || true
    fi
  }

  # ── Load policy ────────────────────────────────────────────────────────────
  # Per-repo override wins; fall back to plugin default; then built-in.
  _POLICY_PER_REPO="${_REPO_ROOT}/.claude/leadv2-overrides/nested-spawn-policy.yaml"
  _POLICY_DEFAULT="${_LV2_ROOT}/config/nested-spawn-policy.yaml"

  _POLICY_SRC=""
  if [[ -f "$_POLICY_PER_REPO" ]]; then
    _POLICY_SRC="$_POLICY_PER_REPO"
  elif [[ -f "$_POLICY_DEFAULT" ]]; then
    _POLICY_SRC="$_POLICY_DEFAULT"
  fi

  # ── HARDENED CONTRACT (gaps #1/#2/#3) ──────────────────────────────────────
  # Kill-switch: LEADV2_NESTED_DEPTH_GATE default "1" (ON). "0" -> unchanged
  # pre-existing base_allowlist behavior only (skip all three checks below).
  # FAIL-SAFE: any parse error here falls back to the built-in defaults
  # (max_depth=1, max_nested_per_task=3) rather than crashing the spawn pipeline.
  _DEPTH_GATE="${LEADV2_NESTED_DEPTH_GATE:-1}"
  if [[ "$_DEPTH_GATE" != "0" ]]; then
    _EXT_POLICY="$(python3 -c "
import sys
policy_src = sys.argv[1] if len(sys.argv) > 1 else ''
max_depth, max_nested, tool_class = 1, 3, 'read_only'
try:
    if policy_src:
        import yaml
        with open(policy_src) as f:
            p = yaml.safe_load(f) or {}
        if isinstance(p, dict):
            max_depth = int(p.get('max_depth', max_depth))
            max_nested = int(p.get('max_nested_per_task', max_nested))
            tool_class = str(p.get('tool_class', tool_class))
except Exception:
    pass
print(max_depth)
print(max_nested)
print(tool_class)
" "${_POLICY_SRC:-}" 2>/dev/null || printf -- '1\n8\nread_only\n')"

    _MAX_DEPTH="$(printf -- '%s' "$_EXT_POLICY" | sed -n '1p')"
    _MAX_SUBRUNS="$(printf -- '%s' "$_EXT_POLICY" | sed -n '2p')"
    [[ "$_MAX_DEPTH" =~ ^[0-9]+$ ]] || _MAX_DEPTH=1
    [[ "$_MAX_SUBRUNS" =~ ^[0-9]+$ ]] || _MAX_SUBRUNS=8

    # Gap #2 — TOOL-CLASS WHITELIST: write-capable roles can never be spawned as
    # a nested sub-run, regardless of base_allowlist or escalation budget.
    case "$SUBAGENT_TYPE" in
      developer|frontend-developer|postgres-pro|devops-engineer|architect|product-owner)
        _audit_log "deny" "route.subrun.write_role_denied"
        printf -- '[leadv2-routing-guard] DENIED nested spawn: subagent_type="%s" is a write-capable role — nested sub-runs are READ/PLAN/PROBE only (Explore, general-purpose). Return blocker to lead.\n' "$SUBAGENT_TYPE" >&2
        exit 2
        ;;
    esac

    # Gap #1 — DEPTH CAP: if the caller is itself already an Explore/general-
    # purpose sub-run (i.e. it was spawned via this same nested-spawn path),
    # it must not spawn a further nested sub-run. max_depth=1 enforced.
    if [[ "$_MAX_DEPTH" -le 1 ]]; then
      case "$CALLER_AGENT_TYPE" in
        explore|general-purpose)
          _audit_log "deny" "route.subrun.depth_exceeded"
          printf -- '[leadv2-routing-guard] DENIED nested spawn: caller "%s" is itself a nested sub-run (max_depth=%s) — cannot spawn further. Return blocker to lead.\n' "$CALLER_AGENT_TYPE" "$_MAX_DEPTH" >&2
          exit 2
          ;;
      esac
    fi
  fi

  # Parse policy: check if stype+model is allowed for this caller. Returns ALLOW or DENY.
  _POLICY_RESULT="$(python3 -c "
import sys

caller    = sys.argv[1]
stype_req = sys.argv[2]
model_req = sys.argv[3]
policy_src = sys.argv[4] if len(sys.argv) > 4 else ''

BASE_DEFAULT = [
    {'subagent_type': 'explore',         'models': ['haiku', 'sonnet'], 'max_per_task': 3},
    {'subagent_type': 'general-purpose', 'models': ['haiku', 'sonnet'], 'max_per_task': 3},
]
PER_CALLER_DEFAULT = {}

policy = None
if policy_src:
    try:
        try:
            import yaml
            with open(policy_src) as f:
                policy = yaml.safe_load(f)
        except ImportError:
            pass
    except Exception:
        pass

if not isinstance(policy, dict):
    base_list = BASE_DEFAULT
    per_caller = PER_CALLER_DEFAULT
else:
    base_list = policy.get('base_allowlist') or BASE_DEFAULT
    per_caller = policy.get('per_caller') or PER_CALLER_DEFAULT

effective = list(base_list)
if isinstance(per_caller, dict) and caller in per_caller:
    caller_entries = per_caller[caller]
    if isinstance(caller_entries, list):
        effective = caller_entries

for entry in effective:
    if not isinstance(entry, dict):
        continue
    et = (entry.get('subagent_type') or '').lower()
    models = [m.lower() for m in (entry.get('models') or [])]
    model_match = any(m in model_req for m in models)
    if et == stype_req and model_match:
        print('ALLOW')
        sys.exit(0)
print('DENY')
" "$CALLER_AGENT_TYPE" "$SUBAGENT_TYPE" "$MODEL" "${_POLICY_SRC:-}" 2>/dev/null || echo "DENY")"

  if [[ "$_POLICY_RESULT" == "ALLOW" ]]; then
    # Count and record an allowed task-scoped spawn under one lock. Taskless
    # probes deliberately skip this quota: the global log is cross-task
    # forensic history and must not become a permanent shared cap.
    if [[ "$_DEPTH_GATE" != "0" ]]; then
      if [[ -n "$SAFE_TASK_ID" ]]; then
        _COUNT_LOG="${_REPO_ROOT}/docs/leadv2/tasks/${SAFE_TASK_ID}/nested-spawns.log"
        if ! mkdir -p "$(dirname "$_COUNT_LOG")" 2>/dev/null || ! touch "$_COUNT_LOG" 2>/dev/null; then
          _audit_log "deny" "route.subrun.count_log_unavailable"
          printf -- '[leadv2-routing-guard] DENIED nested spawn: task audit log unavailable — return blocker to lead.\n' >&2
          exit 2
        fi
        _ALLOW_LINE="$(printf -- '%s caller=%s target=%s model=%s verdict=allow reason=policy_base' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$CALLER_AGENT_TYPE" "$SUBAGENT_TYPE" "$MODEL")"
        _LOCK_RC=0
        _LOCK_RESULT="$(flock -x "$_COUNT_LOG" bash -c '
          log="$1" max="$2" line="$3"
          count="$(grep -Ec "verdict=(allow|escalation)" "$log" 2>/dev/null || printf 0)"
          case "$count" in (""|*[!0-9]*) exit 3;; esac
          if [ "$count" -ge "$max" ]; then printf "%s" "$count"; exit 2; fi
          printf "%s\\n" "$line" >> "$log" || exit 3
          printf "%s" "$count"
        ' bash "$_COUNT_LOG" "$_MAX_SUBRUNS" "$_ALLOW_LINE" 2>/dev/null)" || _LOCK_RC=$?
        if [[ "$_LOCK_RC" -ne 0 ]]; then
          _PRIOR_COUNT="${_LOCK_RESULT:-unknown}"
          if [[ "$_LOCK_RC" -eq 2 ]]; then
            _audit_log "deny" "route.subrun.count_exceeded"
            printf -- '[leadv2-routing-guard] DENIED nested spawn: task "%s" reached max_nested_per_task=%s (prior=%s) — return blocker to lead.\n' "$SAFE_TASK_ID" "$_MAX_SUBRUNS" "$_PRIOR_COUNT" >&2
          else
            _audit_log "deny" "route.subrun.count_log_unavailable"
            printf -- '[leadv2-routing-guard] DENIED nested spawn: task audit lock failed — return blocker to lead.\n' >&2
          fi
          exit 2
        fi
        # Do not call _audit_log here: it would append a second task record.
        _GLOBAL_LOG="${_REPO_ROOT}/docs/leadv2/nested-spawns.log"
        if ! mkdir -p "$(dirname "$_GLOBAL_LOG")" 2>/dev/null || ! printf -- '%s\n' "$_ALLOW_LINE" >> "$_GLOBAL_LOG" 2>/dev/null; then
          printf -- '[leadv2-routing-guard] DENIED nested spawn: global audit log unavailable — return blocker to lead.\n' >&2
          exit 2
        fi
        exit 0
      fi
    fi

    # No task id: record forensics, but never read the cross-task history as a cap.
    _audit_log "allow" "policy_base"
    exit 0  # allowed nested discovery probe
  fi

  # ── ESCALATION path ────────────────────────────────────────────────────────
  # Request is outside base allowlist. Check escalation budget.
  # Use sanitized SAFE_TASK_ID (see above) for any filesystem path use.
  TASK_ID="$SAFE_TASK_ID"

  if [[ -z "$TASK_ID" ]]; then
    _audit_log "deny" "escalation_no_task_id"
    printf -- '[leadv2-routing-guard] DENIED nested spawn: escalation budget requires LEADV2_TASK_ID (not set).\n' >&2
    printf -- 'Got subagent_type="%s" model="%s". Return blocker to lead.\n' "$SUBAGENT_TYPE" "$MODEL" >&2
    exit 2
  fi

  BUDGET_FILE="${_REPO_ROOT}/docs/handoff/${TASK_ID}/escalation-budget.yaml"

  if [[ ! -f "$BUDGET_FILE" ]]; then
    _audit_log "deny" "escalation_budget_absent"
    printf -- '[leadv2-routing-guard] DENIED nested spawn: escalation budget absent — return blocker to lead.\n' >&2
    printf -- 'Task: %s. Requested: subagent_type="%s" model="%s".\n' "$TASK_ID" "$SUBAGENT_TYPE" "$MODEL" >&2
    printf -- 'Lead can issue: docs/handoff/%s/escalation-budget.yaml\n' "$TASK_ID" >&2
    exit 2
  fi

  # Atomic flock read-check-increment on budget file
  BUDGET_LOCK="${_REPO_ROOT}/docs/handoff/${TASK_ID}/.escalation-budget.lock"

  BUDGET_RESULT="$(
    (
      flock -x 9 2>/dev/null || true
      python3 /dev/stdin "$BUDGET_FILE" "$SUBAGENT_TYPE" "$MODEL" <<'BUDGET_PY'
import sys
from pathlib import Path

budget_path = sys.argv[1]
stype_req   = sys.argv[2].lower()
model_req   = sys.argv[3].lower()

try:
    try:
        import yaml
        data = yaml.safe_load(Path(budget_path).read_text()) or {}
    except ImportError:
        import re
        src = Path(budget_path).read_text()
        def _parse_int(key, text, default=0):
            m = re.search(rf'{key}\s*:\s*(\d+)', text)
            return int(m.group(1)) if m else default
        def _parse_list(key, text):
            m = re.search(rf'{key}\s*:\s*\[([^\]]*)\]', text)
            if not m:
                m2 = re.search(rf'{key}\s*:((?:\s*-\s*.+)+)', text)
                if m2:
                    return [x.strip().strip('-').strip().strip('"\'') for x in m2.group(1).strip().splitlines()]
                return []
            return [x.strip().strip('"\'') for x in m.group(1).split(',')]
        data = {
            'max_escalations': _parse_int('max_escalations', src, 1),
            'used': _parse_int('used', src, 0),
            'allowed_types': _parse_list('allowed_types', src),
            'allowed_models': _parse_list('allowed_models', src),
        }

    max_esc = int(data.get('max_escalations', 1))
    used    = int(data.get('used', 0))
    allowed_types  = [t.lower() for t in (data.get('allowed_types') or [])]
    allowed_models = [m.lower() for m in (data.get('allowed_models') or [])]

    if used >= max_esc:
        print('EXHAUSTED')
        sys.exit(0)

    if stype_req not in allowed_types:
        print(f'TYPE_NOT_ALLOWED:{stype_req}')
        sys.exit(0)

    model_ok = any(am in model_req for am in allowed_models)
    if not model_ok:
        print(f'MODEL_NOT_ALLOWED:{model_req}')
        sys.exit(0)

    # All checks passed: increment used atomically
    data['used'] = used + 1
    try:
        import yaml
        Path(budget_path).write_text(yaml.dump(data, default_flow_style=False))
    except ImportError:
        import re
        src2 = Path(budget_path).read_text()
        new_src = re.sub(r'used\s*:\s*\d+', f'used: {used + 1}', src2)
        if f'used: {used + 1}' not in new_src:
            new_src = src2.rstrip() + f'\nused: {used + 1}\n'
        Path(budget_path).write_text(new_src)

    print(f'ALLOW:{used + 1}/{max_esc}')

except Exception as e:
    print(f'ERROR:{e}')
BUDGET_PY
    ) 9>"$BUDGET_LOCK" 2>/dev/null
  )"

  case "$BUDGET_RESULT" in
    ALLOW:*)
      _audit_log "escalation" "budget_ok:${BUDGET_RESULT}"
      exit 0
      ;;
    EXHAUSTED)
      _audit_log "deny" "escalation_budget_exhausted"
      printf -- '[leadv2-routing-guard] DENIED nested spawn: escalation budget exhausted — return blocker to lead.\n' >&2
      printf -- 'Task: %s subagent_type="%s" model="%s"\n' "$TASK_ID" "$SUBAGENT_TYPE" "$MODEL" >&2
      exit 2
      ;;
    TYPE_NOT_ALLOWED:*)
      _audit_log "deny" "escalation_type_not_in_budget"
      printf -- '[leadv2-routing-guard] DENIED nested spawn: type "%s" not in escalation-budget allowed_types — return blocker to lead.\n' "$SUBAGENT_TYPE" >&2
      printf -- 'Task: %s\n' "$TASK_ID" >&2
      exit 2
      ;;
    MODEL_NOT_ALLOWED:*)
      _audit_log "deny" "escalation_model_not_in_budget"
      printf -- '[leadv2-routing-guard] DENIED nested spawn: model "%s" not in escalation-budget allowed_models — return blocker to lead.\n' "$MODEL" >&2
      printf -- 'Task: %s\n' "$TASK_ID" >&2
      exit 2
      ;;
    ERROR:*|"")
      # Corrupt or unreadable budget → deny (fail-safe, never fail-open)
      _audit_log "deny" "escalation_budget_corrupt_or_unreadable"
      printf -- '[leadv2-routing-guard] DENIED nested spawn: escalation-budget.yaml unreadable or corrupt — return blocker to lead.\n' >&2
      printf -- 'Task: %s file: %s\n' "$TASK_ID" "$BUDGET_FILE" >&2
      exit 2
      ;;
    *)
      _audit_log "deny" "escalation_unexpected:${BUDGET_RESULT}"
      printf -- '[leadv2-routing-guard] DENIED nested spawn: unexpected budget result — return blocker to lead.\n' >&2
      exit 2
      ;;
  esac
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
  printf -- '[leadv2-routing-guard] ADVISORY: %s spawned on sonnet during plan/review.\n' "$SUBAGENT_TYPE" >&2
  printf -- 'Preferred: route plan/review brain to Codex first (zero Claude quota):\n' >&2
  printf -- '  bash ~/.claude/scripts/codex-task.sh <prompt>              # Phase 2 plan\n' >&2
  printf -- '  bash ~/.claude/scripts/codex-task.sh adversarial-review    # Phase 5 review\n' >&2
  printf -- 'Or use Agent(%s, model=opus) for high-stakes plan/review.\n' "$SUBAGENT_TYPE" >&2
  printf -- 'Sonnet %s is valid for review R2/R3 rounds (feedback_review_routing).\n' "$SUBAGENT_TYPE" >&2
  printf -- 'See: ${CLAUDE_PLUGIN_ROOT}/docs/routing-enforcement.md\n' >&2
else
  printf -- '[leadv2-routing-guard] ADVISORY: %s spawned on sonnet during plan/review.\n' "$SUBAGENT_TYPE" >&2
  printf -- 'Codex is DISABLED in this repo (codex_enabled: false in codex-policy.yaml).\n' >&2
  printf -- 'Use Agent(%s, model=opus) for plan/review -- NOT sonnet.\n' "$SUBAGENT_TYPE" >&2
  printf -- 'See: ${CLAUDE_PLUGIN_ROOT}/docs/routing-enforcement.md\n' >&2
fi

# Always allow — warn only
exit 0
