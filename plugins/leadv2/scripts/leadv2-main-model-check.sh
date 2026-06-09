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
#   require_prompt_caching      → CACHE_DIR /tmp/leadv2-cache/ writable
#   require_summary_full_split  → .claude/skills/leadv2-subagent-protocol/SKILL.md mentions .summary.md
#   require_diff_only_reviews   → .claude/scripts/leadv2-codex-planner.sh exists
#   require_mcp_memoization     → .claude/scripts/leadv2-mcp-cache.sh exists
#   daily budget                → leadv2-daily-budget.sh --check passes

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
readonly PROJECT_ROOT

readonly MAIN_MODEL_YAML="$PROJECT_ROOT/.claude/ref/leadv2-main-model.yaml"
readonly QUOTA_SCRIPT="$SCRIPT_DIR/leadv2-quota-status.sh"
readonly CACHE_DIR="/tmp/leadv2-cache"

log()        { printf '[leadv2-main-model-check] %s\n' "$*" >&2; }
log_warn()   { printf '[leadv2-main-model-check] WARN: %s\n' "$*" >&2; }
log_info()   { printf '[leadv2-main-model-check] INFO: %s\n' "$*" >&2; }
fallback()   { log_warn "$1 — falling back to sonnet"; printf 'sonnet\n'; exit 0; }

# ---------------------------------------------------------------------------
# 0. If main-model.yaml missing → default sonnet (backward compat)
# ---------------------------------------------------------------------------
if [[ ! -f "$MAIN_MODEL_YAML" ]]; then
  log_info "main-model.yaml not found — defaulting to sonnet"
  printf 'sonnet\n'
  exit 0
fi

# ---------------------------------------------------------------------------
# 1. Parse main_model field
# ---------------------------------------------------------------------------
MAIN_MODEL=$(python3 - "$MAIN_MODEL_YAML" <<'PY'
import sys, yaml
cfg = yaml.safe_load(open(sys.argv[1])) or {}
print(cfg.get("main_model", "sonnet"))
PY
)

if [[ "$MAIN_MODEL" != "opus" ]]; then
  if [[ "${LEADV2_FORCE_OPUS_LEAD:-0}" == "1" ]]; then
    log_info "main_model=${MAIN_MODEL} but LEADV2_FORCE_OPUS_LEAD=1 — falling through to guardrail checks"
  else
    log_info "main_model=${MAIN_MODEL} — no guardrail checks needed"
    printf '%s\n' "$MAIN_MODEL"
    exit 0
  fi
fi

log_info "main_model=$MAIN_MODEL — verifying guardrails..."

# ---------------------------------------------------------------------------
# 2. Load guardrail config
# ---------------------------------------------------------------------------
GUARDRAILS=$(python3 - "$MAIN_MODEL_YAML" <<'PY'
import sys, yaml, json
cfg = yaml.safe_load(open(sys.argv[1])) or {}
g = cfg.get("opus_mode_guardrails", {})
print(json.dumps(g))
PY
)

get_guard() {
  printf '%s' "$GUARDRAILS" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('$1',''))"
}

# ---------------------------------------------------------------------------
# 3. Check require_prompt_caching
# ---------------------------------------------------------------------------
if [[ "$(get_guard require_prompt_caching)" == "True" ]]; then
  mkdir -p "$CACHE_DIR" 2>/dev/null || true
  if [[ ! -d "$CACHE_DIR" ]] || [[ ! -w "$CACHE_DIR" ]]; then
    fallback "require_prompt_caching: cache dir $CACHE_DIR not writable"
  fi
  log_info "require_prompt_caching: OK ($CACHE_DIR writable)"
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
# 7. Quota check (replaces $-budget; reads ~/.claude/burn/history.db)
# ---------------------------------------------------------------------------
if [[ -f "$QUOTA_SCRIPT" ]]; then
  if ! bash "$QUOTA_SCRIPT" --check 2>/dev/null; then
    fallback "5h / weekly quota exhausted (see leadv2-quota-status.sh --report)"
  fi
  log_info "quota: OK"
else
  log_warn "leadv2-quota-status.sh not found — skipping quota check"
fi

# ---------------------------------------------------------------------------
# All checks passed — honour LEADV2_FORCE_OPUS_LEAD override or default to sonnet
# ---------------------------------------------------------------------------
log_info "All guardrails satisfied"
if [[ "${LEADV2_FORCE_OPUS_LEAD:-0}" == "1" ]]; then
  log_info "LEADV2_FORCE_OPUS_LEAD=1 — main model: $MAIN_MODEL"
  printf '%s\n' "$MAIN_MODEL"
else
  log_info "LEADV2_FORCE_OPUS_LEAD not set — defaulting to sonnet"
  printf 'sonnet\n'
fi
exit 0
