#!/usr/bin/env bash
set -euo pipefail
# leadv2-main-model-check.sh — Verify Opus mode guardrails; emit selected model name.
#
# Called at the very start of Phase 0 Intake.
# If main_model=opus: verify all opus_mode_guardrails conditions, check daily budget.
# If any guardrail missing → fall back to sonnet with WARN.
#
# Usage: leadv2-main-model-check.sh
# Output: model name on stdout (opus|sonnet)
# Exit: 0 always (fallback is safe)
#
# Guardrail checks:
#   require_prompt_caching      → Claude Code prompt caching is not disabled
#   require_summary_full_split  → .claude/skills/leadv2-subagent-protocol/SKILL.md mentions .summary.md
#   require_diff_only_reviews   → .claude/scripts/leadv2-codex-planner.sh exists
#   require_mcp_memoization     → .claude/scripts/leadv2-mcp-cache.sh exists
#   daily budget                → leadv2-daily-budget.sh --check passes

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
readonly PROJECT_ROOT

readonly MAIN_MODEL_YAML="$PROJECT_ROOT/.claude/ref/leadv2-main-model.yaml"
readonly QUOTA_SCRIPT="${LEADV2_QUOTA_LIVE:-$SCRIPT_DIR/leadv2-quota-live.sh}"

log()        { printf '[leadv2-main-model-check] %s\n' "$*" >&2; }
log_warn()   { printf '[leadv2-main-model-check] WARN: %s\n' "$*" >&2; }
log_info()   { printf '[leadv2-main-model-check] INFO: %s\n' "$*" >&2; }
fallback()   { log_warn "$1 — falling back to sonnet"; printf 'sonnet\n'; exit 0; }

# ---------------------------------------------------------------------------
# 0. If main-model.yaml missing → default sonnet (backward compat)
# ---------------------------------------------------------------------------
if [[ ! -f "$MAIN_MODEL_YAML" && "${LEADV2_FORCE_OPUS_LEAD:-0}" != "1" ]]; then
  log_info "main-model.yaml not found — defaulting to sonnet"
  printf 'sonnet\n'
  exit 0
fi

# ---------------------------------------------------------------------------
# 1. Parse main_model field
# ---------------------------------------------------------------------------
if [[ -f "$MAIN_MODEL_YAML" ]]; then
  MAIN_MODEL=$(python3 - "$MAIN_MODEL_YAML" <<'PY'
import sys, yaml
cfg = yaml.safe_load(open(sys.argv[1])) or {}
print(cfg.get("main_model", "sonnet"))
PY
  )
else
  MAIN_MODEL="opus"
fi

if [[ "${LEADV2_FORCE_OPUS_LEAD:-0}" == "1" ]]; then
  MAIN_MODEL="opus"
fi

if [[ "$MAIN_MODEL" != "opus" ]]; then
  log_info "main_model=${MAIN_MODEL} — no Opus guardrail checks needed"
  printf '%s\n' "$MAIN_MODEL"
  exit 0
fi

log_info "main_model=$MAIN_MODEL — verifying guardrails..."

# ---------------------------------------------------------------------------
# 2. Load guardrail config
# ---------------------------------------------------------------------------
if [[ -f "$MAIN_MODEL_YAML" ]]; then
  GUARDRAILS=$(python3 - "$MAIN_MODEL_YAML" <<'PY'
import sys, yaml, json
cfg = yaml.safe_load(open(sys.argv[1])) or {}
g = cfg.get("opus_mode_guardrails", {})
print(json.dumps(g))
PY
  )
else
  GUARDRAILS='{}'
  log_warn "forced Opus without main-model.yaml — only runtime quota guard can be verified"
fi

get_guard() {
  printf '%s' "$GUARDRAILS" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('$1',''))"
}

# ---------------------------------------------------------------------------
# 3. Check require_prompt_caching
# ---------------------------------------------------------------------------
if [[ "$(get_guard require_prompt_caching)" == "True" ]]; then
  if [[ "${DISABLE_PROMPT_CACHING:-0}" == "1" \
     || "${DISABLE_PROMPT_CACHING_OPUS:-0}" == "1" ]]; then
    fallback "require_prompt_caching: Claude Code prompt caching is disabled by environment"
  fi
  log_info "require_prompt_caching: OK (Claude Code server caching enabled; subscription sessions choose TTL automatically)"
fi

# ---------------------------------------------------------------------------
# 4. Check require_summary_full_split
# ---------------------------------------------------------------------------
if [[ "$(get_guard require_summary_full_split)" == "True" ]]; then
  SKILL_FILE="$PROJECT_ROOT/.claude/skills/leadv2-subagent-protocol/SKILL.md"
  if [[ ! -f "$SKILL_FILE" ]] || ! grep -q '\.summary\.md' "$SKILL_FILE" 2>/dev/null; then
    fallback "require_summary_full_split: subagent-protocol skill missing .summary.md reference"
  fi
  log_info "require_summary_full_split: OK"
fi

# ---------------------------------------------------------------------------
# 5. Check require_diff_only_reviews (leadv2-codex-planner.sh exists)
# ---------------------------------------------------------------------------
if [[ "$(get_guard require_diff_only_reviews)" == "True" ]]; then
  if [[ ! -f "$SCRIPT_DIR/leadv2-codex-planner.sh" ]]; then
    fallback "require_diff_only_reviews: leadv2-codex-planner.sh not found (R6-W2c not deployed)"
  fi
  log_info "require_diff_only_reviews: OK"
fi

# ---------------------------------------------------------------------------
# 6. Check require_mcp_memoization (leadv2-mcp-cache.sh exists)
# ---------------------------------------------------------------------------
if [[ "$(get_guard require_mcp_memoization)" == "True" ]]; then
  if [[ ! -f "$SCRIPT_DIR/leadv2-mcp-cache.sh" ]]; then
    fallback "require_mcp_memoization: leadv2-mcp-cache.sh not found (R6-W3b not deployed)"
  fi
  log_info "require_mcp_memoization: OK"
fi

# ---------------------------------------------------------------------------
# 7. Provider-owned live quota check. Raw token history is not a subscription
# allowance and must never decide whether Opus is available.
# ---------------------------------------------------------------------------
if [[ -x "$QUOTA_SCRIPT" ]]; then
  _anthropic_quota="$(bash "$QUOTA_SCRIPT" anthropic 2>/dev/null || true)"
  _anthropic_used="$(python3 - "$_anthropic_quota" <<'PY' 2>/dev/null || true
import json, sys
try:
    data = json.loads(sys.argv[1])
except Exception:
    raise SystemExit(0)
values = []
for account in data.get("accounts") or []:
    for key in ("five_hour_pct", "seven_day_pct"):
        value = account.get(key)
        if isinstance(value, (int, float)):
            values.append(float(value))
if values:
    print(max(values))
PY
  )"
  _quota_max="${LEADV2_OPUS_MAX_USED_PERCENT:-95}"
  if [[ -n "$_anthropic_used" ]] && ! awk -v used="$_anthropic_used" -v max="$_quota_max" 'BEGIN { exit !(used < max) }'; then
    fallback "Anthropic live quota ${_anthropic_used}% reached Opus threshold ${_quota_max}%"
  elif [[ -n "$_anthropic_used" ]]; then
    log_info "Anthropic live quota: ${_anthropic_used}% used (<${_quota_max}%)"
  else
    log_warn "Anthropic live quota unknown — preserving requested model; router will keep telemetry honest"
  fi
else
  log_warn "leadv2-quota-live.sh not found — skipping quota check"
fi

# ---------------------------------------------------------------------------
# All checks passed — honor the requested/configured main model.
# ---------------------------------------------------------------------------
log_info "All guardrails satisfied"
log_info "main model: $MAIN_MODEL"
printf '%s\n' "$MAIN_MODEL"
exit 0
