#!/usr/bin/env bash
# leadv2-session-route.sh — deterministic provider/model router for complete
# background /leadv2 sessions. It never calls an LLM. High-risk work fails
# closed to Claude; routine work may use Codex when its runtime, skill, and
# quota headroom are available.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
PROJECT_ROOT="${LEADV2_PROJECT_ROOT:-${CLAUDE_PROJECT_DIR:-${PROJECT_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}}}"
readonly PROJECT_ROOT

log_error() { printf -- '[leadv2-session-route] ERROR: %s\n' "$*" >&2; }

usage() {
  cat >&2 <<'EOF'
Usage: leadv2-session-route.sh --class <Light|Standard|Heavy|Strategic>
       [--risk-tags <csv>] [--suggested-model <model>]
       [--suggested-effort <effort>] [--provider <auto|claude|codex>]
EOF
  exit 1
}

TASK_CLASS="Standard"
RISK_TAGS=""
SUGGESTED_MODEL="sonnet"
SUGGESTED_EFFORT="medium"
PROVIDER_REQUEST="${LEADV2_SESSION_PROVIDER:-auto}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --class) TASK_CLASS="${2:-}"; shift 2 ;;
    --risk-tags) RISK_TAGS="${2:-}"; shift 2 ;;
    --suggested-model) SUGGESTED_MODEL="${2:-}"; shift 2 ;;
    --suggested-effort) SUGGESTED_EFFORT="${2:-}"; shift 2 ;;
    --provider) PROVIDER_REQUEST="${2:-}"; shift 2 ;;
    -h|--help) usage ;;
    *) log_error "unknown arg: $1"; usage ;;
  esac
done

case "$PROVIDER_REQUEST" in
  auto|claude|codex) ;;
  *) log_error "provider must be auto, claude, or codex (got: $PROVIDER_REQUEST)"; exit 1 ;;
esac

# Defaults are intentionally usable without YAML/PyYAML. The canonical config
# and a repo override may replace them, while env vars remain the last word.
CODEX_ENABLED="true"
CODEX_REQUIRE_SKILL="true"
CODEX_MAX_USED_PERCENT="85"
CODEX_LIGHT_MODEL="gpt-5.6-luna"
CODEX_LIGHT_EFFORT="low"
CODEX_STANDARD_MODEL="gpt-5.6-terra"
CODEX_STANDARD_EFFORT="medium"
CLAUDE_LIGHT_MODEL="sonnet"
CLAUDE_LIGHT_EFFORT="medium"
CLAUDE_STANDARD_MODEL="sonnet"
CLAUDE_STANDARD_EFFORT="medium"
CLAUDE_HEAVY_MODEL="opus"
CLAUDE_HEAVY_EFFORT="high"
HIGH_RISK_TAGS="auth,rls,safety,publish,security,arch"

_config_file="${LEADV2_SESSION_ROUTING_CONFIG:-}"
if [[ -z "$_config_file" && -f "$PROJECT_ROOT/.claude/leadv2-overrides/session-routing.yaml" ]]; then
  _config_file="$PROJECT_ROOT/.claude/leadv2-overrides/session-routing.yaml"
elif [[ -z "$_config_file" && -n "${CLAUDE_PLUGIN_ROOT:-}" && -f "${CLAUDE_PLUGIN_ROOT}/config/session-routing.yaml" ]]; then
  _config_file="${CLAUDE_PLUGIN_ROOT}/config/session-routing.yaml"
elif [[ -z "$_config_file" && -f "$SCRIPT_DIR/../config/session-routing.yaml" ]]; then
  _config_file="$SCRIPT_DIR/../config/session-routing.yaml"
fi

if [[ -n "$_config_file" && -f "$_config_file" ]]; then
  while IFS=$'\t' read -r _key _value; do
    case "$_key" in
      codex_enabled) CODEX_ENABLED="$_value" ;;
      codex_require_skill) CODEX_REQUIRE_SKILL="$_value" ;;
      codex_max_used_percent) CODEX_MAX_USED_PERCENT="$_value" ;;
      codex_light_model) CODEX_LIGHT_MODEL="$_value" ;;
      codex_light_effort) CODEX_LIGHT_EFFORT="$_value" ;;
      codex_standard_model) CODEX_STANDARD_MODEL="$_value" ;;
      codex_standard_effort) CODEX_STANDARD_EFFORT="$_value" ;;
      claude_light_model) CLAUDE_LIGHT_MODEL="$_value" ;;
      claude_light_effort) CLAUDE_LIGHT_EFFORT="$_value" ;;
      claude_standard_model) CLAUDE_STANDARD_MODEL="$_value" ;;
      claude_standard_effort) CLAUDE_STANDARD_EFFORT="$_value" ;;
      claude_heavy_model) CLAUDE_HEAVY_MODEL="$_value" ;;
      claude_heavy_effort) CLAUDE_HEAVY_EFFORT="$_value" ;;
      high_risk_tags) HIGH_RISK_TAGS="$_value" ;;
    esac
  done < <(python3 - "$_config_file" <<'PYEOF' 2>/dev/null || true
import sys
try:
    import yaml
    data = yaml.safe_load(open(sys.argv[1], encoding="utf-8")) or {}
except Exception:
    raise SystemExit(0)

codex = data.get("codex") or {}
claude = data.get("claude") or {}
cm = codex.get("models") or {}
am = claude.get("models") or {}
high = data.get("high_risk") or {}

values = {
    "codex_enabled": codex.get("enabled"),
    "codex_require_skill": codex.get("require_leadv2_skill"),
    "codex_max_used_percent": codex.get("max_used_percent"),
    "codex_light_model": (cm.get("light") or {}).get("model"),
    "codex_light_effort": (cm.get("light") or {}).get("effort"),
    "codex_standard_model": (cm.get("standard") or {}).get("model"),
    "codex_standard_effort": (cm.get("standard") or {}).get("effort"),
    "claude_light_model": (am.get("light") or {}).get("model"),
    "claude_light_effort": (am.get("light") or {}).get("effort"),
    "claude_standard_model": (am.get("standard") or {}).get("model"),
    "claude_standard_effort": (am.get("standard") or {}).get("effort"),
    "claude_heavy_model": (am.get("heavy") or {}).get("model"),
    "claude_heavy_effort": (am.get("heavy") or {}).get("effort"),
    "high_risk_tags": ",".join(str(x) for x in (high.get("tags") or [])),
}
for key, value in values.items():
    if value is not None and value != "":
        print(f"{key}\t{str(value).lower() if isinstance(value, bool) else value}")
PYEOF
  )
fi

CODEX_ENABLED="${LEADV2_CODEX_ENABLED:-$CODEX_ENABLED}"
CODEX_REQUIRE_SKILL="${LEADV2_CODEX_REQUIRE_SKILL:-$CODEX_REQUIRE_SKILL}"
CODEX_MAX_USED_PERCENT="${LEADV2_CODEX_MAX_USED_PERCENT:-$CODEX_MAX_USED_PERCENT}"
CODEX_LIGHT_MODEL="${LEADV2_CODEX_LIGHT_MODEL:-$CODEX_LIGHT_MODEL}"
CODEX_LIGHT_EFFORT="${LEADV2_CODEX_LIGHT_EFFORT:-$CODEX_LIGHT_EFFORT}"
CODEX_STANDARD_MODEL="${LEADV2_CODEX_STANDARD_MODEL:-$CODEX_STANDARD_MODEL}"
CODEX_STANDARD_EFFORT="${LEADV2_CODEX_STANDARD_EFFORT:-$CODEX_STANDARD_EFFORT}"
HIGH_RISK_TAGS="${LEADV2_HIGH_RISK_TAGS:-$HIGH_RISK_TAGS}"

if ! [[ "$CODEX_MAX_USED_PERCENT" =~ ^[0-9]+$ ]] || (( CODEX_MAX_USED_PERCENT < 1 || CODEX_MAX_USED_PERCENT > 100 )); then
  log_error "codex max_used_percent must be an integer in 1..100"
  exit 1
fi

_class_l="$(printf '%s' "$TASK_CLASS" | tr '[:upper:]' '[:lower:]')"
_risk_l=",$(printf '%s' "$RISK_TAGS" | tr '[:upper:]' '[:lower:]' | tr -d ' '),"
_high_risk=false
if [[ "$_class_l" == "heavy" || "$_class_l" == "strategic" ]]; then
  _high_risk=true
else
  IFS=',' read -r -a _guard_tags <<< "$HIGH_RISK_TAGS"
  for _tag in "${_guard_tags[@]}"; do
    [[ -z "$_tag" ]] && continue
    if [[ "$_risk_l" == *",${_tag},"* ]]; then
      _high_risk=true
      break
    fi
  done
fi

_claude_model="$CLAUDE_STANDARD_MODEL"
_claude_effort="$CLAUDE_STANDARD_EFFORT"
if [[ "$_class_l" == "light" ]]; then
  _claude_model="$CLAUDE_LIGHT_MODEL"
  _claude_effort="$CLAUDE_LIGHT_EFFORT"
elif [[ "$_high_risk" == "true" ]]; then
  _claude_model="$CLAUDE_HEAVY_MODEL"
  _claude_effort="$CLAUDE_HEAVY_EFFORT"
elif [[ -n "$SUGGESTED_MODEL" ]]; then
  _claude_model="$SUGGESTED_MODEL"
  _claude_effort="${SUGGESTED_EFFORT:-$CLAUDE_STANDARD_EFFORT}"
fi

_codex_model="$CODEX_STANDARD_MODEL"
_codex_effort="$CODEX_STANDARD_EFFORT"
if [[ "$_class_l" == "light" ]]; then
  _codex_model="$CODEX_LIGHT_MODEL"
  _codex_effort="$CODEX_LIGHT_EFFORT"
fi

# An explicit/safety-forced Claude route does not need a Codex login probe or
# three-provider quota request. Besides latency, those probes created noisy
# auth failures during perfectly valid Claude-only launches. Emit the final
# route immediately and mark the skipped telemetry honestly.
if [[ "$_high_risk" == "true" && "${LEADV2_ALLOW_CODEX_HIGH_RISK:-0}" != "1" ]]; then
  printf 'provider=claude\n'
  printf 'model=%s\n' "$_claude_model"
  printf 'effort=%s\n' "$_claude_effort"
  printf 'reason=%s\n' 'high-risk class/tags force Claude; Codex full-session routing is blocked'
  printf 'high_risk=true\n'
  printf 'codex_available=not_probed\n'
  printf 'codex_used_percent=unknown\n'
  printf 'anthropic_used_percent=unknown\n'
  exit 0
elif [[ "$PROVIDER_REQUEST" == "claude" ]]; then
  printf 'provider=claude\n'
  printf 'model=%s\n' "$_claude_model"
  printf 'effort=%s\n' "$_claude_effort"
  printf 'reason=%s\n' 'explicit provider override: claude'
  printf 'high_risk=%s\n' "$_high_risk"
  printf 'codex_available=not_probed\n'
  printf 'codex_used_percent=unknown\n'
  printf 'anthropic_used_percent=unknown\n'
  exit 0
fi

CODEX_BIN="${LEADV2_CODEX_BIN:-codex}"
_codex_available=true
_codex_unavailable_reason=""
if [[ "$CODEX_ENABLED" != "true" && "$CODEX_ENABLED" != "1" ]]; then
  _codex_available=false
  _codex_unavailable_reason="disabled by policy"
elif ! command -v "$CODEX_BIN" >/dev/null 2>&1; then
  _codex_available=false
  _codex_unavailable_reason="codex binary unavailable"
elif [[ "${LEADV2_CODEX_SKIP_LOGIN_CHECK:-0}" != "1" ]] && ! "$CODEX_BIN" login status >/dev/null 2>&1; then
  _codex_available=false
  _codex_unavailable_reason="codex login unavailable"
fi

_skill_ready=false
if [[ "${LEADV2_CODEX_SKILL_READY:-}" == "1" ]]; then
  _skill_ready=true
elif [[ -n "${LEADV2_CODEX_SKILL_PATH:-}" && -f "${LEADV2_CODEX_SKILL_PATH}" ]]; then
  _skill_ready=true
else
  for _skill in \
    "$PROJECT_ROOT/.agents/skills/source-command-leadv2/SKILL.md" \
    "$PROJECT_ROOT/.agents/skills/leadv2/SKILL.md" \
    "$HOME/.agents/skills/source-command-leadv2/SKILL.md" \
    "$HOME/.codex/skills/source-command-leadv2/SKILL.md"; do
    if [[ -f "$_skill" ]]; then
      _skill_ready=true
      break
    fi
  done
fi
if [[ "$CODEX_REQUIRE_SKILL" == "true" || "$CODEX_REQUIRE_SKILL" == "1" ]]; then
  if [[ "$_skill_ready" != "true" ]]; then
    _codex_available=false
    _codex_unavailable_reason="Codex leadv2 skill unavailable"
  fi
fi

_codex_used=""
_anthropic_used=""
QUOTA_LIVE="${LEADV2_QUOTA_LIVE:-$SCRIPT_DIR/leadv2-quota-live.sh}"
if [[ -x "$QUOTA_LIVE" ]]; then
  _quota_json="$($QUOTA_LIVE json 2>/dev/null || true)"
  if [[ -n "$_quota_json" ]]; then
    IFS=$'\t' read -r _codex_used _anthropic_used < <(python3 - "$_quota_json" <<'PYEOF' 2>/dev/null || true
import json, sys
try:
    d = json.loads(sys.argv[1])
except Exception:
    print("\t")
    raise SystemExit(0)

codex = d.get("codex") or {}
codex_vals = [w.get("used_percent") for w in (codex.get("windows") or []) if isinstance(w, dict)]
codex_vals = [float(v) for v in codex_vals if isinstance(v, (int, float))]

anth = d.get("anthropic") or {}
anth_vals = []
for account in anth.get("accounts") or []:
    if not isinstance(account, dict):
        continue
    for key in ("five_hour_pct", "seven_day_pct"):
        value = account.get(key)
        if isinstance(value, (int, float)):
            anth_vals.append(float(value))

def fmt(values):
    if not values:
        return ""
    value = max(values)
    return str(int(value)) if value.is_integer() else str(value)

print(f"{fmt(codex_vals)}\t{fmt(anth_vals)}")
PYEOF
    )
  fi
fi

_codex_quota_ok=true
if [[ -n "$_codex_used" ]]; then
  if ! awk -v used="$_codex_used" -v max="$CODEX_MAX_USED_PERCENT" 'BEGIN { exit !(used < max) }'; then
    _codex_quota_ok=false
  fi
fi

_provider="claude"
_model="$_claude_model"
_effort="$_claude_effort"
_reason=""

if [[ "$_high_risk" == "true" && "${LEADV2_ALLOW_CODEX_HIGH_RISK:-0}" != "1" ]]; then
  _reason="high-risk class/tags force Claude; Codex full-session routing is blocked"
elif [[ "$PROVIDER_REQUEST" == "claude" ]]; then
  _reason="explicit provider override: claude"
elif [[ "$_codex_available" != "true" ]]; then
  _reason="Codex unavailable (${_codex_unavailable_reason}); Claude fallback"
elif [[ "$_codex_quota_ok" != "true" ]]; then
  _reason="Codex quota ${_codex_used}% reached policy threshold ${CODEX_MAX_USED_PERCENT}%; Claude fallback"
elif [[ "$PROVIDER_REQUEST" == "codex" || "$PROVIDER_REQUEST" == "auto" ]]; then
  _provider="codex"
  _model="$_codex_model"
  _effort="$_codex_effort"
  if [[ "$PROVIDER_REQUEST" == "codex" ]]; then
    _reason="explicit provider override: codex"
  else
    _reason="routine ${TASK_CLASS} task routed to Codex to preserve Claude quota"
  fi
fi

printf 'provider=%s\n' "$_provider"
printf 'model=%s\n' "$_model"
printf 'effort=%s\n' "$_effort"
printf 'reason=%s\n' "$_reason"
printf 'high_risk=%s\n' "$_high_risk"
printf 'codex_available=%s\n' "$_codex_available"
printf 'codex_used_percent=%s\n' "${_codex_used:-unknown}"
printf 'anthropic_used_percent=%s\n' "${_anthropic_used:-unknown}"
