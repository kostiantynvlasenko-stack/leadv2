#!/usr/bin/env bash
# confidence-score.sh — Deterministic autopilot confidence scorer
#
# Reads CONFIDENCE_SCORE_* env vars, applies deduction logic, and emits a
# single JSON line to stdout: { "confidence": <float>, "chosen_action": "<enum>", "rationale": "<str>" }
#
# Always exits 0. Errors go to stderr; on error confidence=0.0 + chosen_action=escalate.
#
# Env vars (all optional except CONFIDENCE_SCORE_PROPOSED_ACTION and CONFIDENCE_SCORE_INV_ID):
#   CONFIDENCE_SCORE_RECENT_BREACH_COUNT  (int, default 0)
#   CONFIDENCE_SCORE_BREACH_CLASS         (string, default "")
#   CONFIDENCE_SCORE_PROPOSED_ACTION      (string, required)
#   CONFIDENCE_SCORE_COOLDOWN_ACTIVE      (true|false, default false)
#   CONFIDENCE_SCORE_GIT_DIFF_SENSITIVE   (true|false, default false)
#   CONFIDENCE_SCORE_FLAG_TOGGLE_COUNT    (int, default 0)
#   CONFIDENCE_SCORE_INV_ID               (string, required for hard_limit check)
#   CONFIDENCE_SCORE_POLICY_FILE          (path, default .claude/leadv2-overrides/stability-policy.yaml)

SHELL=/bin/bash
set -uo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
readonly DEFAULT_POLICY_FILE="$PROJECT_ROOT/.claude/leadv2-overrides/stability-policy.yaml"

POLICY_FILE="${CONFIDENCE_SCORE_POLICY_FILE:-$DEFAULT_POLICY_FILE}"

# ---------------------------------------------------------------------------
# Logging (stderr only)
# ---------------------------------------------------------------------------
log()       { printf -- '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2; }
log_info()  { log "INFO: $*"; }
log_error() { log "ERROR: $*"; }

# ---------------------------------------------------------------------------
# Emit error result and exit 0
# ---------------------------------------------------------------------------
emit_error() {
  local reason="$1"
  log_error "$reason"
  printf -- '{"confidence": 0.0, "chosen_action": "escalate", "rationale": "error: %s"}\n' "$reason"
  exit 0
}

# ---------------------------------------------------------------------------
# Policy loader — copied verbatim from stability-autopilot-trigger.sh lines 94-134
# Keep in sync — extraction to autopilot-lib.sh is a follow-up.
# ---------------------------------------------------------------------------
_policy_get() {
  # Usage: _policy_get <dot-path> [default]
  # Dot-path examples: confidence_threshold, whitelist.control_sync,
  #                    whitelist.systemctl_restart_units, claude_p_max_turns
  local key="$1"
  local default="${2:-}"
  python3 - "$POLICY_FILE" "$key" "$default" <<'PYEOF'
import sys, yaml

def get_nested(data, path):
    """Walk dot-separated path through parsed YAML dict/list."""
    keys = path.split('.')
    node = data
    for k in keys:
        if isinstance(node, dict):
            if k not in node:
                return None
            node = node[k]
        else:
            return None
    return node

with open(sys.argv[1]) as f:
    data = yaml.safe_load(f)

if data is None:
    data = {}

key = sys.argv[2]
default = sys.argv[3] if len(sys.argv) > 3 else ''

result = get_nested(data, key)
if result is None:
    print(default)
elif isinstance(result, list):
    print('\n'.join(str(x) for x in result))
elif isinstance(result, bool):
    print('true' if result else 'false')
else:
    print(result)
PYEOF
}

# ---------------------------------------------------------------------------
# JSON field helpers — copied verbatim from stability-autopilot-trigger.sh lines 274-276
# Keep in sync — extraction to autopilot-lib.sh is a follow-up.
# ---------------------------------------------------------------------------
json_field_float() {
  python3 -c "import sys,json; d=json.load(sys.stdin); print(float(d.get('$1',0)))"
}

# ---------------------------------------------------------------------------
# Dependency check
# ---------------------------------------------------------------------------
if ! command -v python3 >/dev/null 2>&1; then
  emit_error "python3 not found"
fi

if [[ ! -f "$POLICY_FILE" ]]; then
  emit_error "policy file not found: $POLICY_FILE"
fi

# ---------------------------------------------------------------------------
# Load policy values
# ---------------------------------------------------------------------------
CONFIDENCE_THRESHOLD="$(_policy_get confidence_threshold 0.8)"
WL_RESTART_UNITS="$(_policy_get whitelist.systemctl_restart_units '')"
WL_CLEAR_FILES="$(_policy_get whitelist.clear_state_files '')"
WL_CONTROL_SYNC="$(_policy_get whitelist.control_sync false)"
HL_INV_PATTERNS="$(_policy_get hard_limit_invariant_patterns '')"

# ---------------------------------------------------------------------------
# Read input env vars (D6)
# ---------------------------------------------------------------------------
RECENT_BREACH_COUNT="${CONFIDENCE_SCORE_RECENT_BREACH_COUNT:-0}"
BREACH_CLASS="${CONFIDENCE_SCORE_BREACH_CLASS:-}"
PROPOSED_ACTION="${CONFIDENCE_SCORE_PROPOSED_ACTION:-}"
COOLDOWN_ACTIVE="${CONFIDENCE_SCORE_COOLDOWN_ACTIVE:-false}"
GIT_DIFF_SENSITIVE="${CONFIDENCE_SCORE_GIT_DIFF_SENSITIVE:-false}"
FLAG_TOGGLE_COUNT="${CONFIDENCE_SCORE_FLAG_TOGGLE_COUNT:-0}"
INV_ID="${CONFIDENCE_SCORE_INV_ID:-}"

# Validate required inputs
if [[ -z "$PROPOSED_ACTION" ]]; then
  emit_error "CONFIDENCE_SCORE_PROPOSED_ACTION is required"
fi

if [[ -z "$INV_ID" ]]; then
  emit_error "CONFIDENCE_SCORE_INV_ID is required"
fi

# ---------------------------------------------------------------------------
# Hard-limit pattern match (D5) — mirrors trigger.sh lines 685-700
# Check inv_id and breach_class as TWO INDEPENDENT lowercased substring checks.
# A pattern that matches EITHER inv_id OR breach_class triggers escalation.
# Using separate checks (not concatenated) avoids false cross-boundary matches
# where a pattern spans the join between the two fields (e.g. pattern "id d"
# would match "some_id domain_check" via a space junction but neither field alone).
# ---------------------------------------------------------------------------
inv_pattern_match=false
if [[ -n "$HL_INV_PATTERNS" ]]; then
  lc_inv_id="$(printf -- '%s' "$INV_ID" | tr '[:upper:]' '[:lower:]')"
  lc_breach_class="$(printf -- '%s' "$BREACH_CLASS" | tr '[:upper:]' '[:lower:]')"
  while IFS= read -r pattern; do
    [[ -z "$pattern" ]] && continue
    lc_pattern="$(printf -- '%s' "$pattern" | tr '[:upper:]' '[:lower:]')"
    if [[ "$lc_inv_id" == *"$lc_pattern"* ]] || [[ "$lc_breach_class" == *"$lc_pattern"* ]]; then
      log_info "Hard-limit pattern match: '$lc_pattern' in inv_id='$lc_inv_id' or breach_class='$lc_breach_class' — forcing escalation"
      inv_pattern_match=true
      break
    fi
  done <<< "$HL_INV_PATTERNS"
fi

# Hard-limit match → immediate 0.0 + escalate (D5)
if [[ "$inv_pattern_match" == "true" ]]; then
  printf -- '{"confidence": 0.0, "chosen_action": "escalate", "rationale": "hard_limit_pattern_match: inv_id or breach_class matches HL_INV_PATTERNS"}\n'
  exit 0
fi

# ---------------------------------------------------------------------------
# Action-not-whitelisted check (D4 step 2)
# Validate proposed action is in the closed enum first
# ---------------------------------------------------------------------------
action_in_enum=false
case "$PROPOSED_ACTION" in
  systemctl_restart|control_sync|clear_state_files|escalate|noop)
    action_in_enum=true
    ;;
esac

if [[ "$action_in_enum" != "true" ]]; then
  printf -- '{"confidence": 0.0, "chosen_action": "escalate", "rationale": "action_not_whitelisted: %s is not in the closed policy enum"}\n' "$PROPOSED_ACTION"
  exit 0
fi

# Whitelist validation for specific actions
action_whitelisted=true
whitelist_fail_reason=""

case "$PROPOSED_ACTION" in
  systemctl_restart)
    # WL_RESTART_UNITS must be non-empty and proposed unit would need to be in it
    # For env-var-only mode we check if list is non-empty (unit check requires unit name arg)
    if [[ -z "$WL_RESTART_UNITS" ]]; then
      action_whitelisted=false
      whitelist_fail_reason="systemctl_restart not in WL_RESTART_UNITS (empty list)"
    fi
    ;;
  control_sync)
    if [[ "$WL_CONTROL_SYNC" != "true" ]]; then
      action_whitelisted=false
      whitelist_fail_reason="control_sync not whitelisted (WL_CONTROL_SYNC=false)"
    fi
    ;;
  clear_state_files)
    # Empty WL_CLEAR_FILES is a noop (allowed but no files to clear) — treat as whitelisted
    ;;
  escalate|noop)
    # Always whitelisted
    ;;
esac

if [[ "$action_whitelisted" != "true" ]]; then
  printf -- '{"confidence": 0.0, "chosen_action": "escalate", "rationale": "action_not_whitelisted: %s"}\n' "$whitelist_fail_reason"
  exit 0
fi

# ---------------------------------------------------------------------------
# Deduction accumulation (D3)
# Base score: 1.0; deductions are additive; clamp to [0.0, 1.0]
# ---------------------------------------------------------------------------
score="1.0"
rationale_parts=()

# recent_breach_count >= 3 → -0.3
if python3 -c "import sys; sys.exit(0 if int(sys.argv[1]) >= 3 else 1)" "$RECENT_BREACH_COUNT" 2>/dev/null; then
  score="$(python3 -c "print(max(0.0, float('$score') - 0.3))")"
  rationale_parts+=("recent_breach_count>=${RECENT_BREACH_COUNT}:-0.3")
fi

# breach_class contains "crit" (severity indicator) → -0.2
breach_class_lower="$(printf -- '%s' "$BREACH_CLASS" | tr '[:upper:]' '[:lower:]')"
if [[ "$breach_class_lower" == *"crit"* ]]; then
  score="$(python3 -c "print(max(0.0, float('$score') - 0.2))")"
  rationale_parts+=("breach_class_crit:-0.2")
fi

# cooldown_active → -0.15
if [[ "$COOLDOWN_ACTIVE" == "true" ]]; then
  score="$(python3 -c "print(max(0.0, float('$score') - 0.15))")"
  rationale_parts+=("cooldown_active:-0.15")
fi

# git_diff_sensitive → -0.1
if [[ "$GIT_DIFF_SENSITIVE" == "true" ]]; then
  score="$(python3 -c "print(max(0.0, float('$score') - 0.1))")"
  rationale_parts+=("git_diff_sensitive:-0.1")
fi

# flag_toggle_count >= 1 → -0.05
if python3 -c "import sys; sys.exit(0 if int(sys.argv[1]) >= 1 else 1)" "$FLAG_TOGGLE_COUNT" 2>/dev/null; then
  score="$(python3 -c "print(max(0.0, float('$score') - 0.05))")"
  rationale_parts+=("flag_toggle_count>=${FLAG_TOGGLE_COUNT}:-0.05")
fi

# Clamp to [0.0, 1.0]
score="$(python3 -c "print(round(max(0.0, min(1.0, float('$score'))), 4))")"

# ---------------------------------------------------------------------------
# Action mapping (D4) — ordered first-match
# ---------------------------------------------------------------------------
# Candidate derivation based on breach_class
chosen_action="escalate"

case "$BREACH_CLASS" in
  *service*)
    chosen_action="systemctl_restart"
    ;;
  *config*|*sync*)
    chosen_action="control_sync"
    ;;
  *state*|*stale*)
    chosen_action="clear_state_files"
    ;;
  *)
    chosen_action="escalate"
    ;;
esac

# Whitelist re-validate derived candidate
case "$chosen_action" in
  systemctl_restart)
    if [[ -z "$WL_RESTART_UNITS" ]]; then
      chosen_action="escalate"
    fi
    ;;
  control_sync)
    if [[ "$WL_CONTROL_SYNC" != "true" ]]; then
      chosen_action="escalate"
    fi
    ;;
esac

# Emit-validated action: HIGH-2 fix — proposed action must match derived candidate.
# Rules (ordered):
# 1. hard_limit match OR proposed not in enum/whitelist → already handled above (escalate, conf=0.0).
# 2. Derived candidate computed from breach_class above.
# 3. If PROPOSED_ACTION == derived candidate AND whitelisted → chosen_action = PROPOSED_ACTION.
# 4. If PROPOSED_ACTION != derived candidate → chosen_action = escalate (scorer disagrees with Opus).
# 5. escalate/noop proposed → use proposed directly (no derivation ambiguity).
derived_candidate="$chosen_action"
case "$PROPOSED_ACTION" in
  escalate|noop)
    chosen_action="$PROPOSED_ACTION"
    ;;
  *)
    if [[ "$PROPOSED_ACTION" == "$derived_candidate" ]]; then
      # Proposed matches derived candidate (already whitelist-re-validated above) → use it
      chosen_action="$PROPOSED_ACTION"
    else
      # Proposed/derived mismatch — deterministic scorer disagrees with Opus → do not auto-act
      chosen_action="escalate"
      rationale_parts+=("proposed_derived_mismatch:proposed=${PROPOSED_ACTION},derived=${derived_candidate}")
    fi
    ;;
esac

# ---------------------------------------------------------------------------
# Score < threshold → coerce to escalate (D3)
# ---------------------------------------------------------------------------
below_threshold=true  # default fail-safe: python3 error → escalate
if python3 -c "import sys; sys.exit(0 if float(sys.argv[1]) >= float(sys.argv[2]) else 1)" \
    "$score" "$CONFIDENCE_THRESHOLD" 2>/dev/null; then
  below_threshold=false
fi

if [[ "$below_threshold" == "true" ]]; then
  chosen_action="escalate"
  rationale_parts+=("score_below_threshold(${CONFIDENCE_THRESHOLD}):coerced_to_escalate")
fi

# ---------------------------------------------------------------------------
# Build rationale string
# ---------------------------------------------------------------------------
if [[ ${#rationale_parts[@]} -eq 0 ]]; then
  rationale="no_deductions_applied"
else
  rationale="$(IFS=','; printf -- '%s' "${rationale_parts[*]}")"
fi

# ---------------------------------------------------------------------------
# Emit JSON result
# ---------------------------------------------------------------------------
python3 - "$score" "$chosen_action" "$rationale" <<'PYEOF'
import sys, json
score = float(sys.argv[1])
action = sys.argv[2]
rationale = sys.argv[3]
print(json.dumps({"confidence": score, "chosen_action": action, "rationale": rationale}))
PYEOF
