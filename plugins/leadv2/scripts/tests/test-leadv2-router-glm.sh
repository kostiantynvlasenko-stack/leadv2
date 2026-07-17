#!/usr/bin/env bash
# tests/test-leadv2-router-glm.sh — ROUTER-HAS-NO-GLM-ARM-01 (fix-round-2).
# Covers docs/handoff/ROUTER-HAS-NO-GLM-ARM-01/critic-review.md findings 1-6:
#   glm default arm, all 5 glm_policy sonnet_exceptions (incl. the H5
#   glm_lock_busy_no_second_channel predicate that was declared-but-dead),
#   the opus_only_mission_kinds ban, the C1 safety_touched field, the C2
#   allowed_arms derivation, the C3 cost-ceiling floor-erosion regression,
#   and two untouched-baseline guards (simple_edit=haiku, plan/heavy=opus
#   triad).
#
# Drives leadv2-router.sh DIRECTLY against a temp fixture (own routing.yaml,
# own PROJECT_ROOT) with an EMPTY inherited env (env -i) — same harness
# pattern as test-leadv2-router-recovery.sh. Never touches the live repo's
# .claude/ref/leadv2-routing.yaml.
#
# Run: bash .claude/scripts/tests/test-leadv2-router-glm.sh
# Exit 0 = all pass; non-zero = failures found.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROUTER_SH="${SCRIPT_DIR}/../leadv2-router.sh"

PASS=0
FAIL=0
ERRORS=()

log()  { printf -- '[TEST] %s\n' "$*"; }
pass() { PASS=$((PASS + 1)); log "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); ERRORS+=("FAIL: $1"); log "FAIL: $1"; }

# ── fixture ──────────────────────────────────────────────────────────────────
_fixture_root() {
  local root; root="$(mktemp -d /tmp/router-glm-XXXXXX)"
  mkdir -p "$root/.claude/ref"
  cat > "$root/.claude/ref/leadv2-routing.yaml" <<'YAML'
phases:
  build:
    simple_edit:
      default: haiku+agent-tool
      tool: agent-tool
      expected_cost_usd: 0.02
      expected_tokens: 4000
    single_file:
      default: glm+agent-tool
      tool: agent-tool
      allowed_arms: [glm, sonnet, opus]
      expected_cost_usd: 0.08
      expected_tokens: 15000
  plan:
    heavy:
      default: opus+codex+critic-opus
      tool: agent-tool+codex-task
      expected_cost_usd: 2.00
      expected_tokens: 400000
  glm_policy:
    policy_id: GLM-FIRST-01
    policy_version: 1
    opus_only_mission_kinds: [architecture, design, safety]
    sonnet_exceptions:
      - id: safety_gate_publish_payments
        when: protected_path
      - id: integration_critical_4subsystems
        when: subsystem_count>=4 or needs_midflight_interaction
      - id: ui_design_judgment
        when: ui_design_judgment
      - id: glm_failed_twice
        when: glm_failure_count>=2
      - id: glm_lock_busy_no_second_channel
        when: glm_lock_busy
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
  printf '%s' "$root"
}

# ── helpers ──────────────────────────────────────────────────────────────────
_kv() { printf '%s\n' "$2" | grep "^$1=" | cut -d= -f2; }           # simple scalar fields
_cmpl() { printf '%s\n' "$1" | grep '^command_template=' | cut -d= -f2-; }  # may contain '='
_route_val() { grep "^  ${2}:" "$1" 2>/dev/null | tail -1 | cut -d: -f2- | sed 's/^ //'; }

_write_costs() {
  local root="$1" task_id="$2" content="$3"
  mkdir -p "$root/docs/handoff/$task_id"
  printf '%s' "$content" > "$root/docs/handoff/$task_id/costs.yaml"
}

# _run_router root phase step class signals task_id [EXTRA_ENV=VAL ...]
_run_router() {
  local root="$1" phase="$2" step="$3" class="$4" signals="$5" task_id="$6"; shift 6
  local args=(--phase "$phase" --step "$step" --class "$class" --signals "$signals")
  [[ -n "$task_id" ]] && args+=(--task-id "$task_id")
  env -i PATH="$PATH" PROJECT_ROOT="$root" "$@" \
    bash "$ROUTER_SH" "${args[@]}" 2>/dev/null
}

# ── T1: glm default (no signals) ────────────────────────────────────────────
test_t1_glm_default() {
  local root; root="$(_fixture_root)"
  local out; out="$(_run_router "$root" build single_file Standard '{}' "")"
  local model reason rule
  model="$(_kv model "$out")"; reason="$(_kv routing_reason "$out")"; rule="$(_kv glm_exception_rule "$out")"
  if [[ "$model" == "glm+agent-tool" && "$reason" == "glm_default" && "$rule" == "null" ]]; then
    pass "T1: no signals -> glm+agent-tool / glm_default / null"
  else
    fail "T1: got model=${model} reason=${reason} rule=${rule}"
  fi
  rm -rf "$root"
}

# ── T2-T8: the 5 glm_policy sonnet_exceptions (7 predicate variants) ───────
_assert_exception() {
  local desc="$1" signals="$2" expect_rule="$3"
  local root; root="$(_fixture_root)"
  local out; out="$(_run_router "$root" build single_file Standard "$signals" "")"
  local model reason rule
  model="$(_kv model "$out")"; reason="$(_kv routing_reason "$out")"; rule="$(_kv glm_exception_rule "$out")"
  if [[ "$model" == "sonnet+agent-tool" && "$reason" == "sonnet_exception" && "$rule" == "$expect_rule" ]]; then
    pass "$desc: sonnet+agent-tool / sonnet_exception / ${expect_rule}"
  else
    fail "$desc: expected sonnet+agent-tool/sonnet_exception/${expect_rule}, got ${model}/${reason}/${rule}"
  fi
  rm -rf "$root"
}

test_t2_safety_touched() { _assert_exception "T2 safety_touched" '{"safety_touched":true}' "safety_gate_publish_payments"; }
test_t3_protected_path() { _assert_exception "T3 protected_path" '{"protected_path":true}' "safety_gate_publish_payments"; }
test_t4_subsystem_count() { _assert_exception "T4 subsystem_count>=4" '{"subsystem_count":4}' "integration_critical_4subsystems"; }
test_t5_midflight() { _assert_exception "T5 needs_midflight_interaction" '{"needs_midflight_interaction":true}' "integration_critical_4subsystems"; }
test_t6_ui_design() { _assert_exception "T6 ui_design_judgment" '{"ui_design_judgment":true}' "ui_design_judgment"; }
test_t7_glm_failed_twice() { _assert_exception "T7 glm_failure_count>=2" '{"glm_failure_count":2}' "glm_failed_twice"; }
# H5: glm_lock_busy_no_second_channel was DECLARED in routing.yaml with zero
# reading predicate in router.sh — the exact disease this task kills.
test_t8_glm_lock_busy() { _assert_exception "T8 (H5) glm_lock_busy" '{"glm_lock_busy":true}' "glm_lock_busy_no_second_channel"; }

# ── T9: opus_only_mission_kinds ban (glm never chosen for these) ───────────
test_t9_opus_mission_kind_ban() {
  local root; root="$(_fixture_root)"
  local kind
  for kind in architecture safety; do
    local out model reason rule
    out="$(_run_router "$root" build single_file Standard "{\"mission_kind\":\"${kind}\"}" "")"
    model="$(_kv model "$out")"; reason="$(_kv routing_reason "$out")"; rule="$(_kv glm_exception_rule "$out")"
    if [[ "$model" == "opus+agent-tool" && "$reason" == "opus_mission_kind" && "$rule" == "null" ]]; then
      pass "T9 (${kind}): opus+agent-tool / opus_mission_kind / null — glm banned"
    else
      fail "T9 (${kind}): expected opus+agent-tool/opus_mission_kind/null, got ${model}/${reason}/${rule}"
    fi
  done
  rm -rf "$root"
}

# ── T10: C1 regression — safety_touched field derived from fired-rule id ───
test_t10_c1_safety_touched_field() {
  local root; root="$(_fixture_root)"
  _run_router "$root" build single_file Standard '{"safety_touched":true}' "T10" >/dev/null
  local rd="$root/docs/handoff/T10/route-decisions.yaml"
  local st rule
  st="$(_route_val "$rd" safety_touched)"; rule="$(_route_val "$rd" glm_exception_rule)"
  if [[ "$st" == "true" && "$rule" == "safety_gate_publish_payments" ]]; then
    pass "T10a (C1): safety exception fired -> row safety_touched=true, glm_exception_rule=safety_gate_publish_payments (no longer disagree)"
  else
    fail "T10a: expected true/safety_gate_publish_payments, got ${st}/${rule}"
  fi
  rm -rf "$root"

  # Regression guard: the OLD bug derived safety_touched from signals.risk=='critical'
  # even when no glm_policy rule fired — prove that no longer happens.
  root="$(_fixture_root)"
  _run_router "$root" build single_file Standard '{"risk":"critical"}' "T10b" >/dev/null
  rd="$root/docs/handoff/T10b/route-decisions.yaml"
  st="$(_route_val "$rd" safety_touched)"; rule="$(_route_val "$rd" glm_exception_rule)"
  if [[ "$st" == "false" && "$rule" == "null" ]]; then
    pass "T10b (C1 regression): signals.risk=critical with no glm_policy rule fired -> safety_touched=false (old bug would say true)"
  else
    fail "T10b: expected false/null, got ${st}/${rule}"
  fi
  rm -rf "$root"
}

# ── T11: C2 regression — allowed_arms derived from resolver, not a blind re-read ─
test_t11_c2_allowed_arms() {
  local root; root="$(_fixture_root)"
  _run_router "$root" build single_file Standard '{"safety_touched":true}' "T11a" LEADV2_ROUTE_BANDIT=1 >/dev/null
  local rd="$root/docs/handoff/T11a/route-decisions.yaml"
  local allowed chosen
  allowed="$(_route_val "$rd" allowed_arms)"; chosen="$(_route_val "$rd" chosen_arm)"
  if [[ "$allowed" == '["sonnet"]' && "$chosen" == "sonnet+agent-tool" ]]; then
    pass "T11a (C2): mandatory exception fired -> allowed_arms=[\"sonnet\"], chosen_arm inside it (old bug: allowed=[\"glm\"], heuristic=sonnet)"
  else
    fail "T11a: expected allowed_arms=[\"sonnet\"] chosen_arm=sonnet+agent-tool, got allowed=${allowed} chosen=${chosen}"
  fi
  rm -rf "$root"

  root="$(_fixture_root)"
  _run_router "$root" build single_file Standard '{}' "T11b" LEADV2_ROUTE_BANDIT=1 >/dev/null
  rd="$root/docs/handoff/T11b/route-decisions.yaml"
  allowed="$(_route_val "$rd" allowed_arms)"
  if [[ "$allowed" == *'"glm"'* ]]; then
    pass "T11b (C2): glm_default -> allowed_arms contains the heuristic arm \"glm\" (${allowed})"
  else
    fail "T11b: expected allowed_arms to contain \"glm\", got ${allowed}"
  fi
  rm -rf "$root"
}

# ── T12: C3 regression — cost-ceiling must not erode the resolver's floor ──
test_t12_c3_ceiling_preserves_floor() {
  local root; root="$(_fixture_root)"
  # 1.3 / 2.00 Standard ceiling = 65% -> lands in the warn band [60%,95%),
  # the exact zone the legacy downgrade block used to demote sonnet->haiku
  # and (via the reconcile block) erase routing_reason/glm_exception_rule.
  _write_costs "$root" "T12" $'- role: developer\n  cost_usd: 1.3\n'
  local out; out="$(_run_router "$root" build single_file Standard '{"safety_touched":true}' "T12")"
  local model downgrade
  model="$(_kv model "$out")"; downgrade="$(_kv downgrade_applied "$out")"
  local rd="$root/docs/handoff/T12/route-decisions.yaml"
  local reason rule
  reason="$(_route_val "$rd" routing_reason)"; rule="$(_route_val "$rd" glm_exception_rule)"
  if [[ "$model" == "sonnet+agent-tool" && "$downgrade" == "false" \
        && "$reason" == "sonnet_exception" && "$rule" == "safety_gate_publish_payments" ]]; then
    pass "T12 (C3): 65% burn + safety exception -> arm stays sonnet (not haiku), downgrade_applied=false, rule id survives"
  else
    fail "T12: expected sonnet+agent-tool/false/sonnet_exception/safety_gate_publish_payments, got ${model}/${downgrade}/${reason}/${rule}"
  fi
  rm -rf "$root"
}

# ── T13: simple_edit unchanged (haiku, no glm_policy involvement) ──────────
test_t13_simple_edit_unchanged() {
  local root; root="$(_fixture_root)"
  local out; out="$(_run_router "$root" build simple_edit Light '{}' "")"
  local model; model="$(_kv model "$out")"
  if [[ "$model" == "haiku+agent-tool" ]]; then
    pass "T13: build/simple_edit unchanged -> haiku+agent-tool"
  else
    fail "T13: expected haiku+agent-tool, got ${model}"
  fi
  rm -rf "$root"
}

# ── T14: plan/heavy unchanged (opus triad, base != glm, resolver skipped) ──
test_t14_plan_heavy_unchanged() {
  local root; root="$(_fixture_root)"
  local out; out="$(_run_router "$root" plan heavy Heavy '{}' "")"
  local model; model="$(_kv model "$out")"
  if [[ "$model" == "opus+codex+critic-opus" ]]; then
    pass "T14: plan/heavy unchanged -> opus+codex+critic-opus"
  else
    fail "T14: expected opus+codex+critic-opus, got ${model}"
  fi
  rm -rf "$root"
}

# ── T15: H6 — glm command_template quotes survive the bash->python handoff ─
test_t15_h6_glm_quotes_preserved() {
  local root; root="$(_fixture_root)"
  local out cmpl; out="$(_run_router "$root" build single_file Standard '{}' "")"
  cmpl="$(_cmpl "$out")"
  if printf '%s' "$cmpl" | grep -qF -- '"@{{mission_file}}"'; then
    pass "T15 (H6): command_template preserves quoted \"@{{mission_file}}\" (${cmpl})"
  else
    fail "T15 (H6): quotes stripped, got '${cmpl}'"
  fi
  local qcount
  qcount="$(printf '%s' "$cmpl" | od -c | grep -o '"' | wc -l | tr -d ' ')"
  if [[ "$qcount" -ge 2 ]]; then
    pass "T15b (H6): od -c confirms >=2 literal \" bytes in command_template"
  else
    fail "T15b (H6): od -c found ${qcount} \" bytes, expected >=2"
  fi
  rm -rf "$root"
}

# ── T16: stderr must be clean — no bash-level quote/parse noise ────────────
# fix-round-2 self-catch: an earlier draft of the H6 comment used backticks
# inside the resolve_effective_model python3 -c "..." double-quoted string.
# Bash performs backtick command substitution INSIDE double quotes even in
# what is, from python's point of view, a comment line — this produced
# "unexpected EOF while looking for matching `"'" and literally tried to run
# the shell builtin `bg` on every single router call (glm branch or not).
# 2>/dev/null in every other test here would hide this class of bug — this
# is the one test that keeps stderr and asserts it is free of that noise.
test_t16_stderr_clean() {
  local root; root="$(_fixture_root)"
  local err; err="$(mktemp /tmp/router-glm-stderr-XXXXXX)"
  env -i PATH="$PATH" PROJECT_ROOT="$root" \
    bash "$ROUTER_SH" --phase build --step single_file --class Standard --signals '{}' \
    >/dev/null 2>"$err"
  if grep -qiE 'unexpected EOF|command substitution|no job control|syntax error' "$err"; then
    fail "T16: router stderr contains bash parse/quote noise: $(cat "$err")"
  else
    pass "T16: router stderr clean on default glm dispatch (no backtick/quote leakage)"
  fi
  rm -f "$err"
  rm -rf "$root"
}

# ── T17: fix-round-3 — bandit must never escape the glm_default arm ────────
# Probabilistic regression guard for ROUTER-HAS-NO-GLM-ARM-01 fix-round-3:
# Thompson sampling on the free-choice glm_default path used to be handed
# routing.yaml's allowed_arms:[glm,sonnet,opus] and could explore into
# sonnet/opus while routing_reason kept reporting glm_default — silently
# routing default dev spawns onto Claude quota while the record lied about
# why. A single run passes by luck; >=12 runs make the probabilistic escape
# visible (fix-round-2's live repro showed 8/12 non-glm on this exact route).
test_t17_bandit_cannot_escape_glm_default() {
  local root; root="$(_fixture_root)"
  local n non_glm=0 total=12
  for n in $(seq 1 "$total"); do
    local out model reason
    out="$(_run_router "$root" build single_file Standard '{}' "" LEADV2_ROUTE_BANDIT=1)"
    model="$(_kv model "$out")"; reason="$(_kv routing_reason "$out")"
    if [[ "$reason" == "glm_default" && "$model" != "glm+agent-tool" ]]; then
      non_glm=$((non_glm + 1))
      log "T17 violation on run ${n}: model=${model} routing_reason=${reason}"
    elif [[ "$reason" != "glm_default" ]]; then
      fail "T17: run ${n} unexpectedly changed routing_reason to ${reason} (expected glm_default with no signals)"
      rm -rf "$root"
      return
    fi
  done
  if [[ "$non_glm" -eq 0 ]]; then
    pass "T17: ${total}/${total} runs stayed model=glm+agent-tool under routing_reason=glm_default (bandit cannot escape)"
  else
    fail "T17: ${non_glm}/${total} runs had non-glm model while routing_reason=glm_default — bandit escaped the mandatory glm arm"
  fi
  rm -rf "$root"
}

# ── syntax guard ─────────────────────────────────────────────────────────────
test_syntax_check() {
  if bash -n "$ROUTER_SH" 2>/dev/null; then
    pass "bash -n syntax OK on leadv2-router.sh"
  else
    fail "bash -n syntax check failed"
  fi
}

test_t1_glm_default
test_t2_safety_touched
test_t3_protected_path
test_t4_subsystem_count
test_t5_midflight
test_t6_ui_design
test_t7_glm_failed_twice
test_t8_glm_lock_busy
test_t9_opus_mission_kind_ban
test_t10_c1_safety_touched_field
test_t11_c2_allowed_arms
test_t12_c3_ceiling_preserves_floor
test_t13_simple_edit_unchanged
test_t14_plan_heavy_unchanged
test_t15_h6_glm_quotes_preserved
test_t16_stderr_clean
test_t17_bandit_cannot_escape_glm_default
test_syntax_check

echo ""
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
if [[ "$FAIL" -gt 0 ]]; then
  printf '%s\n' "${ERRORS[@]}"
  exit 1
fi
exit 0
