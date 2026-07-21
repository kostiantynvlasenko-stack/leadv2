#!/usr/bin/env bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/leadv2-temp.sh"
# tests/test-leadv2-model-arg-rebuild.sh — Integration test for the T8
# latent-bug fix in claude-subsession.sh (formerly
# test-leadv2-cooldown-recovery.sh — renamed after the SPLIT decision; T8b
# will reuse the old name for the redesigned recovery feature).
#
# History: T8 originally tried to ship a cooldown/TTL auto-recovery feature
# on top of this fix. Round-2 review BLOCKED the recovery half (unreachable
# ceiling_status=="ok" gate + incoherent cross-process force state). Founder
# decision: SPLIT — ship the latent-bug fix now (this file), move recovery
# design to a new task (T8b). All `_cooldown_expired` / `LEADV2_COOLDOWN_*`
# code and tests have been removed; consult-site-1 and consult-site-2 in
# claude-subsession.sh are back to their exact pre-T8 HEAD form.
#
# What's left, and what this file proves: `CLAUDE_ARGS=(... --model "$MODEL"
# ...)` froze --model's VALUE at construction time, BEFORE _check_cost_ceiling
# (where the 60%-downgrade decision lives) ever ran — so that decision could
# never reach the launched `claude` process. This was a real latent bug
# pre-dating T8, unconditional, no flag. Fixed by rebuilding the --model
# element of CLAUDE_ARGS AFTER _check_cost_ceiling runs (self-locating loop,
# not a magic index).
#
# The single integration test sources the REAL claude-subsession.sh under
# LEADV2_DRY_RUN=1 (D5 chokepoint — exits 0 right before run_subsession, so
# `claude` is NEVER invoked) with a full fixture (routing.yaml, role file,
# mission file, costs.yaml), captures the ACTUAL value that lands in the
# --model element of CLAUDE_ARGS, and drives the real
# _check_cost_ceiling -> CLAUDE_ARGS -> launch-value path end to end: THIS
# spawn's own fresh 60%-ceiling breach must make the downgraded tier
# (sonnet) actually reach --model.
#
# Run: bash scripts/tests/test-leadv2-model-arg-rebuild.sh
# Exit 0 = all pass; non-zero = failures found.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUBSESSION_SH="${SCRIPT_DIR}/../claude-subsession.sh"

PASS=0
FAIL=0
ERRORS=()

log()  { printf -- '[TEST] %s\n' "$*"; }
pass() { PASS=$((PASS + 1)); log "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); ERRORS+=("FAIL: $1"); log "FAIL: $1"; }

# =============================================================================
# Integration harness: real _check_cost_ceiling -> CLAUDE_ARGS -> --model
# =============================================================================
#
# LEADV2_ROUTE_BANDIT is pinned to 0 (this dev machine's ambient env has it
# =1, which would otherwise let the Thompson-sampling bandit override the
# deterministic routing.yaml decision).

_it_fixture_root() {
  local root; root="$(lv2_mktemp_dir "subsession-it")"
  mkdir -p "$root/.claude/ref" "$root/.claude/agents"
  cat > "$root/.claude/ref/leadv2-routing.yaml" <<'YAML'
phases:
  build:
    single_file:
      default: opus-subsession
      tool: claude-subsession
      expected_cost_usd: 0.30
      expected_tokens: 60000
stop_rules:
  cost_ceiling_per_task:
    Standard: 2.00
    warn_threshold_pct: 60
    hard_stop_threshold_pct: 95
downgrade_chain:
  opus: sonnet
  sonnet: haiku
  haiku: haiku
YAML
  cat > "$root/.claude/agents/developer.md" <<'ROLEEOF'
---
model: sonnet
---
Integration-test developer role body.
ROLEEOF
  printf 'Integration-test mission body.\n' > "$root/mission.md"
  printf '%s' "$root"
}

# _it_run_subsession — sources the REAL script, captures the final --model
# value from CLAUDE_ARGS.
# Args: $1=task_id $2=--model value $3=costs.yaml content $4=extra env (space-
#       separated NAME=VALUE assignments, applied via export before sourcing)
# Prints the captured --model value to stdout.
_it_run_subsession() {
  local task_id="$1" model_arg="$2" costs_content="$3" extra_env="${4:-}"
  local root; root="$(_it_fixture_root)"
  mkdir -p "$root/docs/handoff/$task_id"
  printf '%s' "$costs_content" > "$root/docs/handoff/$task_id/costs.yaml"

  local capture; capture="$(lv2_mktemp_file "subsession-it-capture" "tmp")"

  (
    set +e
    if [[ -n "$extra_env" ]]; then
      # shellcheck disable=SC2086,SC2163
      export $extra_env
    fi
    export PROJECT_ROOT="$root"
    export LEADV2_ROUTE_BANDIT=0
    export LEADV2_TASK_CLASS="Standard"
    export LEADV2_DRY_RUN=1
    trap 'printf "%s\n" "${CLAUDE_ARGS[@]:-__NO_ARGS__}" > "'"$capture"'"' EXIT
    # shellcheck disable=SC1090
    source "$SUBSESSION_SH" --role developer --model "$model_arg" \
      --task-id "$task_id" --mission-file "$root/mission.md" --wait >/dev/null 2>&1
  )

  # Extract the token immediately after the "--model" line in the captured array dump.
  local result
  result="$(awk '/^--model$/{getline; print; exit}' "$capture" 2>/dev/null)"
  rm -rf "$root" "$capture"
  printf '%s' "$result"
}

# ── Test 1: THIS spawn's own fresh 60% breach -> downgrade reaches --model ──
test_1_downgrade_reaches_model() {
  log "Test 1: burn>=60% THIS spawn -> --model=sonnet (downgrade reaches launch)"
  # T8b: the fresh-trip decision is now windowed-burn-derived, so the cost row
  # needs a parseable in-window timestamp (design §3) — a row with no
  # timestamp can never contribute to windowed_burn and would leave
  # recovery_status/downgrade_active "unknown" (fail-safe HOLD), not "over".
  local costs="- role: developer
  cost_usd: 1.5
  timestamp: $(date -u +%FT%TZ)
"
  local got
  got="$(_it_run_subsession "IT-01" "opus" "$costs" "")"
  if [[ "$got" == "sonnet" ]]; then
    pass "fresh 60% breach -> --model=sonnet reaches launch (dead wire fixed)"
  else
    fail "expected --model=sonnet, got '${got}' (rebuild wire may still be dead)"
  fi
}

# ── Test 2: bash -n syntax check on patched claude-subsession.sh ──────────
test_2_syntax_check() {
  log "Test 2: bash -n syntax check on claude-subsession.sh"
  if bash -n "$SUBSESSION_SH" 2>/dev/null; then
    pass "bash -n syntax OK"
  else
    fail "bash -n syntax check failed"
  fi
}

test_1_downgrade_reaches_model
test_2_syntax_check

echo ""
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
if [[ "$FAIL" -gt 0 ]]; then
  printf '%s\n' "${ERRORS[@]}"
  exit 1
fi
exit 0
