#!/usr/bin/env bash
# tests/test-leadv2-router-recovery.sh — T8b ROUTING-TIER-RECOVERY-REDESIGN.
# Covers docs/handoff/ROUTING-TIER-RECOVERY-REDESIGN/design.md §6 T1-T12.
#
# Path resolved relative to tests/ dir (../leadv2-router.sh, ../claude-subsession.sh)
# like the sibling test-leadv2-*.sh files — NOT co-located with the scripts
# themselves (that was the T11 gotcha, see test-leadv2-model-arg-rebuild.sh header).
#
# Most tests drive leadv2-router.sh DIRECTLY with an EMPTY inherited env
# (env -i) against a temp fixture (routing.yaml + costs.yaml), asserting on
# the new recovery_status/downgrade_active/force_model/fresh_trip/hard_stop
# keys. T8b also sources the REAL claude-subsession.sh under LEADV2_DRY_RUN=1
# (same harness pattern as test-leadv2-model-arg-rebuild.sh) to prove the
# consumer side (inherited-force-kept-on-unknown) end to end.
#
# Run: bash scripts/tests/test-leadv2-router-recovery.sh
# Exit 0 = all pass; non-zero = failures found.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROUTER_SH="${SCRIPT_DIR}/../leadv2-router.sh"
SUBSESSION_SH="${SCRIPT_DIR}/../claude-subsession.sh"

PASS=0
FAIL=0
ERRORS=()

log()  { printf -- '[TEST] %s\n' "$*"; }
pass() { PASS=$((PASS + 1)); log "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); ERRORS+=("FAIL: $1"); log "FAIL: $1"; }

# ── fixture helpers ──────────────────────────────────────────────────────────
_fixture_root() {
  local root; root="$(mktemp -d /tmp/router-recovery-XXXXXX)"
  mkdir -p "$root/.claude/ref"
  cat > "$root/.claude/ref/leadv2-routing.yaml" <<'YAML'
phases:
  build:
    single_file:
      default: opus-subsession
      tool: claude-subsession
      expected_cost_usd: 0.05
      expected_tokens: 10000
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

_kv() { printf '%s\n' "$2" | grep "^$1=" | cut -d= -f2; }

# _run_router root task_id [EXTRA_ENV=VAL ...] — EMPTY inherited env (env -i)
# except PATH+PROJECT_ROOT, so tests prove behavior is derived from the
# costs.yaml file, never from inherited env (design §2 rehydration guarantee).
_run_router() {
  local root="$1" task_id="$2"; shift 2
  env -i PATH="$PATH" PROJECT_ROOT="$root" "$@" \
    bash "$ROUTER_SH" --phase build --step single_file \
    --task-id "$task_id" --class Standard 2>/dev/null
}

_iso() { # _iso <seconds-ago> (negative = future)
  python3 -c "
from datetime import datetime, timedelta, timezone
print((datetime.now(timezone.utc) - timedelta(seconds=$1)).strftime('%Y-%m-%dT%H:%M:%SZ'))
"
}

_write_costs() {
  local root="$1" task_id="$2" content="$3"
  mkdir -p "$root/docs/handoff/$task_id"
  printf '%s' "$content" > "$root/docs/handoff/$task_id/costs.yaml"
}

_dg_event() { # _dg_event <ts-seconds-ago> <to_model>
  printf -- '- downgrade_event:\n    timestamp: %s\n    reason: cost_ceiling_60pct\n    from_model: opus\n    to_model: %s\n    affected_role: developer\n    burn_usd: 1.5\n    ceiling_usd: 2.00\n' "$(_iso "$1")" "$2"
}

_dg_event_no_to_model() { # G-3 fix-round-4: malformed row, valid timestamp, NO to_model key
  printf -- '- downgrade_event:\n    timestamp: %s\n    reason: cost_ceiling_60pct\n    from_model: opus\n    affected_role: developer\n    burn_usd: 1.5\n    ceiling_usd: 2.00\n' "$(_iso "$1")"
}

# _assert_template_placeholders <command_template> — G-4 fix-round-4: locks
# G-5 forever. A POSITIVE fixed-string check for the exact double-brace
# tokens is sufficient proof they were never collapsed: if fix-round-3's
# f-string bug reappeared, the output would contain single-brace {role} etc,
# and the literal substring {{role}} (two real braces on each side) could
# not be present at all.
_assert_template_placeholders() {
  local cmpl="$1"
  printf '%s' "$cmpl" | grep -qF -- '{{role}}' \
    && printf '%s' "$cmpl" | grep -qF -- '{{task_id}}' \
    && printf '%s' "$cmpl" | grep -qF -- '{{mission}}'
}

_cost_row() { # _cost_row <cost_usd> <ts-seconds-ago-or-empty>
  if [[ -n "${2:-}" ]]; then
    printf -- '- role: developer\n  cost_usd: %s\n  timestamp: %s\n' "$1" "$(_iso "$2")"
  else
    printf -- '- role: developer\n  cost_usd: %s\n' "$1"
  fi
}

# ── T1: downgrade persists across spawn (2 empty-env probes, seeded event) ──
test_t1_persists_across_spawn() {
  local root; root="$(_fixture_root)"
  local costs; costs="$(_dg_event 3000 sonnet)"$'\n'"$(_cost_row 1.5 60)"
  _write_costs "$root" "T1" "$costs"

  local out1 out2 fm1 fm2 da1 da2
  out1="$(_run_router "$root" "T1")"
  out2="$(_run_router "$root" "T1")"
  fm1="$(_kv force_model "$out1")"; da1="$(_kv downgrade_active "$out1")"
  fm2="$(_kv force_model "$out2")"; da2="$(_kv downgrade_active "$out2")"

  if [[ "$da1" == "true" && "$fm1" == "sonnet" && "$da2" == "true" && "$fm2" == "sonnet" ]]; then
    pass "T1: downgrade persists across 2 empty-env spawns (force_model=sonnet both times)"
  else
    fail "T1: expected true/sonnet twice, got (${da1}/${fm1}) then (${da2}/${fm2})"
  fi
  rm -rf "$root"
}

# ── T2/T3: recovery on genuine window-drop, then re-trip ────────────────────
test_t2_t3_recovery_then_retrip() {
  local root; root="$(_fixture_root)"
  local costs; costs="$(_dg_event 700 sonnet)"$'\n'"$(_cost_row 1.5 3000)"
  _write_costs "$root" "T2" "$costs"

  local out rs da fm
  out="$(_run_router "$root" "T2" LEADV2_COOLDOWN_RECOVERY=1)"
  rs="$(_kv recovery_status "$out")"; da="$(_kv downgrade_active "$out")"; fm="$(_kv force_model "$out")"
  if [[ "$rs" == "ok" && "$da" == "false" && -z "$fm" ]]; then
    pass "T2: old row aged out of window + flag on + dwell elapsed -> recovers (force_model cleared)"
  else
    fail "T2: expected ok/false/empty, got ${rs}/${da}/'${fm}'"
  fi

  local costs2; costs2="${costs}"$'\n'"$(_cost_row 1.5 30)"
  _write_costs "$root" "T2" "$costs2"
  out="$(_run_router "$root" "T2" LEADV2_COOLDOWN_RECOVERY=1)"
  da="$(_kv downgrade_active "$out")"; fm="$(_kv force_model "$out")"
  if [[ "$da" == "true" && "$fm" == "sonnet" ]]; then
    pass "T3: fresh in-window burn re-trips force_model=sonnet"
  else
    fail "T3: expected true/sonnet, got ${da}/'${fm}'"
  fi
  rm -rf "$root"
}

# ── T4: hysteresis dead-band [recover_pct, warn_pct) holds, never recovers ──
test_t4_hysteresis_dead_band() {
  local root; root="$(_fixture_root)"
  # dead-band $ range with ceiling=2.00: [0.10, 1.20). 0.50 falls inside.
  local costs; costs="$(_dg_event 700 sonnet)"$'\n'"$(_cost_row 0.5 60)"
  _write_costs "$root" "T4" "$costs"
  local out rs da
  out="$(_run_router "$root" "T4" LEADV2_COOLDOWN_RECOVERY=1)"
  rs="$(_kv recovery_status "$out")"; da="$(_kv downgrade_active "$out")"
  if [[ "$rs" == "over" && "$da" == "true" ]]; then
    pass "T4: windowed burn in dead-band [5%,60%) -> over, holds (no recover)"
  else
    fail "T4: expected over/true, got ${rs}/${da}"
  fi
  rm -rf "$root"
}

# ── T5: corrupt YAML -> unknown/unknown (HOLD) ──────────────────────────────
test_t5_corrupt_yaml_unknown() {
  local root; root="$(_fixture_root)"
  mkdir -p "$root/docs/handoff/T5"
  printf ': not: valid: yaml: [[[' > "$root/docs/handoff/T5/costs.yaml"
  local out rs da
  out="$(_run_router "$root" "T5")"
  rs="$(_kv recovery_status "$out")"; da="$(_kv downgrade_active "$out")"
  if [[ "$rs" == "unknown" && "$da" == "unknown" ]]; then
    pass "T5: corrupt YAML -> unknown/unknown (HOLD)"
  else
    fail "T5: expected unknown/unknown, got ${rs}/${da}"
  fi
  rm -rf "$root"
}

# ── T6: cost row missing timestamp -> unknown, force_model=to_model kept ───
test_t6_missing_timestamp_holds_to_model() {
  local root; root="$(_fixture_root)"
  local costs; costs="$(_dg_event 700 sonnet)"$'\n'"$(_cost_row 0.5 "")"
  _write_costs "$root" "T6" "$costs"
  local out rs da fm
  out="$(_run_router "$root" "T6" LEADV2_COOLDOWN_RECOVERY=1)"
  rs="$(_kv recovery_status "$out")"; da="$(_kv downgrade_active "$out")"; fm="$(_kv force_model "$out")"
  # fix-round-5: an EXISTING downgrade_event (active=True, bound before the
  # cost-row ts-parse failure) now correctly reports downgrade_active="true"
  # instead of colliding with day-0's "unknown" (was the round-5 Critical).
  if [[ "$rs" == "unknown" && "$da" == "true" && "$fm" == "sonnet" ]]; then
    pass "T6 (fix-round-5): cost row missing timestamp, EXISTING active downgrade -> unknown/true, force_model=to_model (not sentinel)"
  else
    fail "T6: expected unknown/true/sonnet, got ${rs}/${da}/'${fm}'"
  fi
  rm -rf "$root"
}

# ── T7: clock-skew future timestamp -> unknown, force_model=to_model kept ──
test_t7_future_ts_holds() {
  local root; root="$(_fixture_root)"
  local costs; costs="$(_dg_event 700 sonnet)"$'\n'"$(_cost_row 0.5 -600)"
  _write_costs "$root" "T7" "$costs"
  local out rs da fm
  out="$(_run_router "$root" "T7" LEADV2_COOLDOWN_RECOVERY=1)"
  rs="$(_kv recovery_status "$out")"; da="$(_kv downgrade_active "$out")"; fm="$(_kv force_model "$out")"
  # fix-round-5: EXISTING active downgrade -> "true", not day-0-colliding "unknown".
  if [[ "$rs" == "unknown" && "$da" == "true" && "$fm" == "sonnet" ]]; then
    pass "T7 (fix-round-5): clock-skew (future cost-row ts), EXISTING active downgrade -> unknown/true, force_model=to_model"
  else
    fail "T7: expected unknown/true/sonnet, got ${rs}/${da}/'${fm}'"
  fi
  rm -rf "$root"
}

# ── T8: missing costs.yaml -> unknown (router) + inherited force kept (consumer) ──
test_t8_missing_file_keeps_inherited() {
  local root; root="$(_fixture_root)"
  local out rs da
  out="$(_run_router "$root" "T8-NOFILE")"
  rs="$(_kv recovery_status "$out")"; da="$(_kv downgrade_active "$out")"
  if [[ "$rs" == "unknown" && "$da" == "unknown" ]]; then
    pass "T8a: missing costs.yaml -> unknown/unknown (router side, design row 1)"
  else
    fail "T8a: expected unknown/unknown, got ${rs}/${da}"
  fi

  mkdir -p "$root/.claude/agents"
  cat > "$root/.claude/agents/developer.md" <<'ROLEEOF'
---
model: sonnet
---
recovery-test developer role body.
ROLEEOF
  printf 'mission body\n' > "$root/mission.md"
  local capture; capture="$(mktemp /tmp/router-recovery-capture-XXXXXX)"
  (
    set +e
    export PROJECT_ROOT="$root"
    export LEADV2_ROUTE_BANDIT=0
    export LEADV2_TASK_CLASS="Standard"
    export LEADV2_DRY_RUN=1
    export LEADV2_FORCE_MODEL="sonnet"
    export LEADV2_FORCE_MODEL_TASK="T8-NOFILE"   # H2: force must be task-scoped to be honored
    trap 'printf "%s\n" "${CLAUDE_ARGS[@]:-__NO_ARGS__}" > "'"$capture"'"' EXIT
    # shellcheck disable=SC1090
    source "$SUBSESSION_SH" --role developer --model "opus" \
      --task-id "T8-NOFILE" --mission-file "$root/mission.md" --wait >/dev/null 2>&1
  )
  local got
  got="$(awk '/^--model$/{getline; print; exit}' "$capture" 2>/dev/null)"
  rm -f "$capture"
  if [[ "$got" == "sonnet" ]]; then
    pass "T8b: missing costs.yaml -> recovery_status=unknown -> inherited LEADV2_FORCE_MODEL kept (--model=sonnet, not cleared)"
  else
    fail "T8b: expected --model=sonnet (inherited kept on unknown), got '${got}'"
  fi
  rm -rf "$root"
}

# ── T9: hard-stop (cumulative >= 95%) never recovers, even if windowed=ok ──
test_t9_hard_stop_never_recovers() {
  local root; root="$(_fixture_root)"
  local costs; costs="$(_dg_event 700 sonnet)"$'\n'"$(_cost_row 1.95 3000)"
  _write_costs "$root" "T9" "$costs"
  local out hs da fm
  out="$(_run_router "$root" "T9" LEADV2_COOLDOWN_RECOVERY=1)"
  hs="$(_kv hard_stop "$out")"; da="$(_kv downgrade_active "$out")"; fm="$(_kv force_model "$out")"
  if [[ "$hs" == "true" && "$da" == "true" && "$fm" == "sonnet" ]]; then
    pass "T9: cumulative >= 95% -> hard_stop=true, recovery blocked despite windowed being low"
  else
    fail "T9: expected true/true/sonnet, got ${hs}/${da}/'${fm}'"
  fi
  rm -rf "$root"
}

# ── T10: min-dwell blocks recovery even when windowed is genuinely ok ──────
test_t10_min_dwell_blocks_recovery() {
  local root; root="$(_fixture_root)"
  local costs; costs="$(_dg_event 10 sonnet)"$'\n'"$(_cost_row 0.05 3000)"
  _write_costs "$root" "T10" "$costs"
  local out da fm
  out="$(_run_router "$root" "T10" LEADV2_COOLDOWN_RECOVERY=1)"
  da="$(_kv downgrade_active "$out")"; fm="$(_kv force_model "$out")"
  if [[ "$da" == "true" && "$fm" == "sonnet" ]]; then
    pass "T10: downgrade_ts 10s ago (< 300s min-dwell) -> holds despite windowed=ok"
  else
    fail "T10: expected true/sonnet, got ${da}/'${fm}'"
  fi
  rm -rf "$root"
}

# ── T11: LEADV2_COOLDOWN_RECOVERY unset (default 0) -> never clears ────────
test_t11_flag_off_never_clears() {
  local root; root="$(_fixture_root)"
  local costs; costs="$(_dg_event 700 sonnet)"$'\n'"$(_cost_row 0.05 3000)"
  _write_costs "$root" "T11" "$costs"
  local out da fm
  out="$(_run_router "$root" "T11")"   # LEADV2_COOLDOWN_RECOVERY intentionally NOT set
  da="$(_kv downgrade_active "$out")"; fm="$(_kv force_model "$out")"
  if [[ "$da" == "true" && "$fm" == "sonnet" ]]; then
    pass "T11: LEADV2_COOLDOWN_RECOVERY unset -> never clears even when windowed is ok"
  else
    fail "T11: expected true/sonnet (flag-off fail-safe), got ${da}/'${fm}'"
  fi
  rm -rf "$root"
}

# ── T12: TOCTOU — concurrent cost-flush-style append + router read ─────────
# H4(b) fix-round-1 REWRITE: the old version accepted "ok" OR "over" — but
# "ok" is ALSO what an unlocked/torn read (seeing only the pre-append row)
# would produce, so it never actually proved the lock. Tightened: with
# ceiling=2.00, recover_pct=5% -> $0.10, a torn read (sees only the $0.05
# pre-append row) stays "ok" (0.05<0.10); the COMPLETE post-append state
# (0.05+0.10=$0.15) crosses into the dead-band -> "over". Asserting
# recovery_status MUST be "over" proves the reader observed the FULL
# post-append file, i.e. flock -s genuinely blocked for the writer's -x hold.
test_t12_toctou_concurrent_lock() {
  local root; root="$(_fixture_root)"
  local costs; costs="$(_cost_row 0.05 60)"
  _write_costs "$root" "T12" "$costs"
  local lock_file="$root/docs/handoff/T12/.cost-flush.lock"

  (
    flock -x 9
    sleep 1
    printf -- '\n%s' "$(_cost_row 0.10 30)" >> "$root/docs/handoff/T12/costs.yaml"
  ) 9>"$lock_file" &
  local writer_pid=$!

  sleep 0.2
  local out rs
  out="$(_run_router "$root" "T12")"
  rs="$(_kv recovery_status "$out")"
  wait "$writer_pid"

  if [[ "$rs" == "over" ]]; then
    pass "T12: router blocked on flock -s for the writer's -x hold -> observed COMPLETE post-append state (over), not a torn read"
  else
    fail "T12: expected 'over' (proves complete-state read, not torn) — 'ok' would mean a torn/partial read slipped through; got '${rs}'"
  fi
  rm -rf "$root"
}

# ── T13: empty cost_rows (downgrade_event only, zero cost rows) -> unknown ──
test_t13_empty_cost_rows_unknown() {
  local root; root="$(_fixture_root)"
  local costs; costs="$(_dg_event 700 sonnet)"
  _write_costs "$root" "T13" "$costs"
  local out rs da fm
  out="$(_run_router "$root" "T13" LEADV2_COOLDOWN_RECOVERY=1)"
  rs="$(_kv recovery_status "$out")"; da="$(_kv downgrade_active "$out")"; fm="$(_kv force_model "$out")"
  # fix-round-5: EXISTING active downgrade -> "true", not day-0-colliding "unknown".
  if [[ "$rs" == "unknown" && "$da" == "true" && "$fm" == "sonnet" ]]; then
    pass "T13 (C1/fix-round-5): empty cost_rows, EXISTING active downgrade -> unknown/true, force_model=to_model kept"
  else
    fail "T13: expected unknown/true/sonnet, got ${rs}/${da}/'${fm}'"
  fi
  rm -rf "$root"
}

# ── T14: mixed valid-ts + missing-ts cost rows -> unknown (never averages) ──
test_t14_mixed_missing_ts_unknown() {
  local root; root="$(_fixture_root)"
  local costs; costs="$(_dg_event 700 sonnet)"$'\n'"$(_cost_row 0.5 60)"$'\n'"$(_cost_row 0.3 "")"
  _write_costs "$root" "T14" "$costs"
  local out rs da fm
  out="$(_run_router "$root" "T14" LEADV2_COOLDOWN_RECOVERY=1)"
  rs="$(_kv recovery_status "$out")"; da="$(_kv downgrade_active "$out")"; fm="$(_kv force_model "$out")"
  # fix-round-5: EXISTING active downgrade -> "true", not day-0-colliding "unknown".
  if [[ "$rs" == "unknown" && "$da" == "true" && "$fm" == "sonnet" ]]; then
    pass "T14 (C1/fix-round-5): one valid-ts + one missing-ts row, EXISTING active downgrade -> unknown/true (a single ts failure poisons the windowed read, but the active-downgrade signal itself is preserved)"
  else
    fail "T14: expected unknown/true/sonnet, got ${rs}/${da}/'${fm}'"
  fi
  rm -rf "$root"
}

# ── T15: fully-corrupt costs.yaml -> no premium spawn (drive the real router) ──
test_t15_corrupt_no_premium_spawn() {
  local root; root="$(_fixture_root)"
  mkdir -p "$root/docs/handoff/T15"
  printf ': not: valid: yaml: [[[' > "$root/docs/handoff/T15/costs.yaml"
  local out model hs br
  out="$(_run_router "$root" "T15")"
  model="$(_kv model "$out")"
  hs="$(_kv hard_stop "$out")"
  br="$(_kv burn_readable "$out")"
  if [[ "$model" != "opus" && "$hs" == "true" && "$br" == "false" ]]; then
    pass "T15 (C3): corrupt costs.yaml -> burn_readable=false, hard_stop=true, model capped to '${model}' (NOT opus/premium)"
  else
    fail "T15: expected model!=opus + hard_stop=true + burn_readable=false, got model='${model}' hard_stop=${hs} burn_readable=${br}"
  fi
  rm -rf "$root"
}

# ── T16: flock itself fails (shimmed) -> HOLD, never an unlocked/torn read ──
test_t16_flock_fail_holds() {
  local root; root="$(_fixture_root)"
  local costs; costs="$(_dg_event 700 sonnet)"$'\n'"$(_cost_row 0.05 60)"
  _write_costs "$root" "T16" "$costs"

  # Shim `flock` to always fail — a real, valid, readable costs.yaml sits
  # right there; if the reader used it anyway (unlocked), recovery_status
  # would come back "ok" (0.05 < $0.10 recover threshold). Any value other
  # than "unknown" here means a torn/unlocked read slipped through C2.
  local fakebin="$root/fakebin"
  mkdir -p "$fakebin"
  printf '#!/bin/sh\nexit 1\n' > "$fakebin/flock"
  chmod +x "$fakebin/flock"

  local out rs da fm
  out="$(env -i PATH="${fakebin}:${PATH}" PROJECT_ROOT="$root"     bash "$ROUTER_SH" --phase build --step single_file     --task-id "T16" --class Standard 2>/dev/null)"
  rs="$(_kv recovery_status "$out")"; da="$(_kv downgrade_active "$out")"; fm="$(_kv force_model "$out")"
  # Note: force_model is __HOLD__ here (not the seeded to_model=sonnet) —
  # lock failure short-circuits BEFORE any read, including the downgrade_event
  # row itself. That is intentionally MORE conservative than a mid-parse
  # failure (T6/T7, where the read under lock DID succeed and to_model was
  # captured) — lock-fail means we trust nothing from the file, full stop.
  if [[ "$rs" == "unknown" && "$da" == "unknown" && "$fm" == "__HOLD__" ]]; then
    pass "T16 (C2): shimmed always-failing flock -> unknown/unknown/__HOLD__ (zero trust in the file's contents, not even to_model — no unlocked read despite a valid readable file sitting right there)"
  else
    fail "T16: expected unknown/unknown/__HOLD__ (HOLD, no torn read), got ${rs}/${da}/'${fm}'"
  fi
  rm -rf "$root"
}

# ── T17: lock held by another process -> bounded wait, HOLD, never a hang ──
test_t17_lock_timeout_no_hang() {
  local root; root="$(_fixture_root)"
  local costs; costs="$(_dg_event 700 sonnet)"$'\n'"$(_cost_row 0.05 60)"
  _write_costs "$root" "T17" "$costs"
  local lock_file="$root/docs/handoff/T17/.cost-flush.lock"

  ( flock -x 9; sleep 5 ) 9>"$lock_file" &
  local holder_pid=$!
  sleep 0.2

  local start_ts end_ts elapsed out rs
  start_ts=$(date +%s)
  out="$(env -i PATH="$PATH" PROJECT_ROOT="$root" LEADV2_LOCK_WAIT_SEC=1     timeout 4 bash "$ROUTER_SH" --phase build --step single_file     --task-id "T17" --class Standard 2>/dev/null)"
  end_ts=$(date +%s)
  elapsed=$(( end_ts - start_ts ))
  rs="$(_kv recovery_status "$out")"

  kill "$holder_pid" 2>/dev/null || true
  wait "$holder_pid" 2>/dev/null || true

  if [[ "$elapsed" -lt 4 && "$rs" == "unknown" ]]; then
    pass "T17 (H1): LEADV2_LOCK_WAIT_SEC=1 against a held lock -> returned in ${elapsed}s (bounded, no hang), recovery_status=unknown"
  else
    fail "T17: expected elapsed<4s and recovery_status=unknown, got elapsed=${elapsed}s rs='${rs}'"
  fi
  rm -rf "$root"
}

# ── T18: LEADV2_FORCE_MODEL from a DIFFERENT task_id is never inherited ────
test_t18_force_not_inherited_across_task() {
  local root; root="$(_fixture_root)"
  mkdir -p "$root/.claude/agents"
  cat > "$root/.claude/agents/developer.md" <<'ROLEEOF'
---
model: sonnet
---
recovery-test developer role body.
ROLEEOF
  printf 'mission body\n' > "$root/mission.md"
  local capture; capture="$(mktemp /tmp/router-recovery-capture-XXXXXX)"
  (
    set +e
    export PROJECT_ROOT="$root"
    export LEADV2_ROUTE_BANDIT=0
    export LEADV2_TASK_CLASS="Standard"
    export LEADV2_DRY_RUN=1
    export LEADV2_FORCE_MODEL="sonnet"
    export LEADV2_FORCE_MODEL_TASK="SOME-OTHER-TASK"   # H2: deliberately mismatched
    trap 'printf "%s\n" "${CLAUDE_ARGS[@]:-__NO_ARGS__}" > "'"$capture"'"' EXIT
    # shellcheck disable=SC1090
    source "$SUBSESSION_SH" --role developer --model "opus"       --task-id "T18-CURRENT-TASK" --mission-file "$root/mission.md" --wait >/dev/null 2>&1
  )
  local got
  got="$(awk '/^--model$/{getline; print; exit}' "$capture" 2>/dev/null)"
  rm -f "$capture"
  if [[ "$got" == "opus" ]]; then
    pass "T18 (H2): LEADV2_FORCE_MODEL_TASK mismatch -> force from a different task_id NOT inherited (--model stays opus)"
  else
    fail "T18: expected --model=opus (force not inherited cross-task), got '${got}'"
  fi
  rm -rf "$root"
}

# ── T19: no --task-id -> stdout byte-identical to pre-T8b (no new keys) ────
test_t19_no_task_id_byte_identical() {
  local root; root="$(_fixture_root)"
  local out
  out="$(env -i PATH="$PATH" PROJECT_ROOT="$root"     bash "$ROUTER_SH" --phase build --step single_file --class Standard 2>/dev/null)"
  if printf '%s\n' "$out" | grep -qE '^(recovery_status|force_model|downgrade_active|fresh_trip|hard_stop|burn_readable)='; then
    fail "T19 (H3): no --task-id call still emitted a T8b recovery key — NOT byte-identical to pre-T8b baseline"
  else
    pass "T19 (H3): no --task-id -> zero T8b recovery keys in stdout (byte-identical to pre-T8b baseline)"
  fi
  rm -rf "$root"
}

# ── T20: day-0/never-spent task -> premium NOT capped (F-A) ────────────────
test_t20_day0_premium_allowed() {
  local root; root="$(_fixture_root)"
  # No costs.yaml at all for this task_id — genuine day-0/never-spent probe.
  local out model cmpl
  out="$(_run_router "$root" "T20")"
  model="$(_kv model "$out")"
  cmpl="$(_kv command_template "$out")"
  # G-4 fix-round-4: strict - non-empty, EXACT tier, template agrees, AND
  # placeholders are still double-brace (locks G-5 forever).
  if [[ -n "$model" ]] && [[ "$model" == "opus-subsession" ]]      && [[ -n "$cmpl" ]] && printf '%s' "$cmpl" | grep -qF -- '--model opus '      && _assert_template_placeholders "$cmpl"; then
    pass "T20 (F-A/G-4): day-0/never-spent task -> model=${model} NOT capped, command_template agrees (--model opus), placeholders intact"
  else
    fail "T20: expected exact model=opus-subsession, --model opus in template, and intact placeholders, got model='${model}' command_template='${cmpl}'"
  fi
  rm -rf "$root"
}

# ── T21: active downgrade caps BOTH model= and command_template= (F-B/F-C) ──
test_t21_active_downgrade_caps_both_fields() {
  local root; root="$(_fixture_root)"
  local costs; costs="$(_dg_event 700 sonnet)"$'
'"$(_cost_row 0.05 3000)"
  _write_costs "$root" "T21" "$costs"
  local out model cmpl
  out="$(_run_router "$root" "T21")"
  model="$(_kv model "$out")"
  cmpl="$(_kv command_template "$out")"
  # G-4 fix-round-4: strict - non-empty, EXACT tier, template agrees, AND
  # placeholders survive the cap rewrite intact.
  if [[ -n "$model" ]] && [[ "$model" == "sonnet" ]]      && [[ -n "$cmpl" ]] && printf '%s' "$cmpl" | grep -qF -- '--model sonnet '      && ! printf '%s' "$cmpl" | grep -qF -- 'opus'      && _assert_template_placeholders "$cmpl"; then
    pass "T21 (F-B/F-C/G-4): active downgrade, opus-subsession default -> BOTH model=sonnet and command_template's --model sonnet agree, placeholders intact"
  else
    fail "T21: expected exact model=sonnet, --model sonnet in template, no opus, intact placeholders, got model='${model}' command_template='${cmpl}'"
  fi
  rm -rf "$root"
}

# ── T22: fully-corrupt costs.yaml refuses BOTH fields (F-C) ─────────────────
test_t22_corrupt_refuses_both_fields() {
  local root; root="$(_fixture_root)"
  mkdir -p "$root/docs/handoff/T22"
  printf ': not: valid: yaml: [[[' > "$root/docs/handoff/T22/costs.yaml"
  local out rc model cmpl
  out="$(_run_router "$root" "T22")"; rc=$?
  model="$(_kv model "$out")"
  cmpl="$(_kv command_template "$out")"
  # G-4 fix-round-4: strict - non-empty, EXACT tier (haiku, the SAFE_FLOOR),
  # template agrees, placeholders intact even on the refuse/corrupt path.
  if [[ "$rc" -eq 1 ]] && [[ -n "$model" ]] && [[ "$model" == "haiku" ]]      && [[ -n "$cmpl" ]] && printf '%s' "$cmpl" | grep -qF -- '--model haiku '      && ! printf '%s' "$cmpl" | grep -qF -- 'opus'      && _assert_template_placeholders "$cmpl"; then
    pass "T22 (F-C/G-4): fully-corrupt costs.yaml -> refuses (rc=1), BOTH fields exactly haiku, placeholders intact"
  else
    fail "T22: expected rc=1, exact model=haiku, --model haiku in template, intact placeholders, got rc=${rc} model='${model}' command_template='${cmpl}'"
  fi
  rm -rf "$root"
}

# ── T23: consumer fresh-process adopts router force_model on unknown (F-D) ──
test_t23_consumer_fresh_process_adopts_force() {
  local root; root="$(_fixture_root)"
  # T6/T7-style: active downgrade_event (to_model=sonnet) + a cost row with a
  # missing timestamp -> recovery_status=unknown, but force_model=sonnet is
  # still known (captured before the ts-parse failure).
  local costs; costs="$(_dg_event 700 sonnet)"$'
'"$(_cost_row 0.5 "")"
  _write_costs "$root" "T23-CURRENT-TASK" "$costs"
  mkdir -p "$root/.claude/agents"
  cat > "$root/.claude/agents/developer.md" <<'ROLEEOF'
---
model: sonnet
---
recovery-test developer role body.
ROLEEOF
  printf 'mission body
' > "$root/mission.md"
  local capture; capture="$(mktemp /tmp/router-recovery-capture-XXXXXX)"
  (
    set +e
    export PROJECT_ROOT="$root"
    export LEADV2_ROUTE_BANDIT=0
    export LEADV2_TASK_CLASS="Standard"
    export LEADV2_DRY_RUN=1
    # Deliberately NO LEADV2_FORCE_MODEL set — fresh process, nothing inherited.
    trap 'printf "%s\n" "${CLAUDE_ARGS[@]:-__NO_ARGS__}" > "'"$capture"'"' EXIT
    # shellcheck disable=SC1090
    source "$SUBSESSION_SH" --role developer --model "opus"       --task-id "T23-CURRENT-TASK" --mission-file "$root/mission.md" --wait >/dev/null 2>&1
  )
  local got
  got="$(awk '/^--model$/{getline; print; exit}' "$capture" 2>/dev/null)"
  rm -f "$capture"
  if [[ "$got" == "sonnet" ]]; then
    pass "T23 (F-D): fresh process, nothing inherited, router force_model=sonnet (unknown-but-known) -> adopted directly (--model=sonnet, not opus)"
  else
    fail "T23: expected --model=sonnet (F-D adopt-on-unknown), got '${got}'"
  fi
  rm -rf "$root"
}

# ── T24: leadv2-cost-flush.sh lock timeout -> skip, no hang, no corruption (F-E) ──
test_t24_costflush_lock_timeout() {
  local root; root="$(_fixture_root)"
  local hd="$root/docs/handoff/T24"
  mkdir -p "$hd"
  local stream="$hd/developer.stream.jsonl"
  printf '' > "$stream"
  {
    printf -- 'session_id: sess-t24
'
    printf -- 'role: developer
'
    printf -- 'model: sonnet
'
    printf -- 'stream_file: %s
' "$stream"
    printf -- 'start_epoch: %s
' "$(date +%s)"
    printf -- 'handoff_dir: %s
' "$hd"
  } > "$hd/developer.cost-pending.yaml"
  local lock_file="$hd/.cost-flush.lock"

  ( flock -x 9; sleep 5 ) 9>"$lock_file" &
  local holder_pid=$!
  sleep 0.2

  local flush_sh="${SCRIPT_DIR}/../leadv2-cost-flush.sh"
  local start_ts end_ts elapsed
  start_ts=$(date +%s)
  PROJECT_ROOT="$root" LEADV2_LOCK_WAIT_SEC=1 timeout 4 bash "$flush_sh" "$hd" >/dev/null 2>&1
  end_ts=$(date +%s)
  elapsed=$(( end_ts - start_ts ))

  kill "$holder_pid" 2>/dev/null || true
  wait "$holder_pid" 2>/dev/null || true

  if [[ "$elapsed" -lt 4 && -f "$hd/developer.cost-pending.yaml" ]]; then
    pass "T24 (F-E): cost-flush lock held elsewhere -> LEADV2_LOCK_WAIT_SEC=1 skips within ${elapsed}s (bounded, no hang), marker kept for retry (no corrupting unlocked write)"
  else
    fail "T24: expected elapsed<4s and marker file kept, got elapsed=${elapsed}s marker_exists=$([[ -f "$hd/developer.cost-pending.yaml" ]] && echo yes || echo no)"
  fi
  rm -rf "$root"
}

# ── T27: G-1 repro — active downgrade + ZERO cost rows caps BOTH fields ────
# downgrade_active resolves "unknown" (empty cost_rows raises per C1) even
# though force_model=sonnet is known — rounds 1-2's cap keyed off
# downgrade_active=="true" and silently skipped this exact shape.
test_t27_g1_active_downgrade_zero_cost_rows_caps_both() {
  local root; root="$(_fixture_root)"
  local costs; costs="$(_dg_event 700 sonnet)"   # active downgrade, zero cost rows (T13 shape)
  _write_costs "$root" "T27" "$costs"
  local out model cmpl
  out="$(_run_router "$root" "T27")"
  model="$(_kv model "$out")"
  cmpl="$(_kv command_template "$out")"
  if [[ "$model" == "sonnet" ]]      && printf '%s' "$cmpl" | grep -q -- '--model sonnet'      && ! printf '%s' "$cmpl" | grep -q -- '--model opus'; then
    pass "T27 (G-1): active downgrade + ZERO cost rows (downgrade_active=unknown, force_model=sonnet) -> BOTH fields capped to sonnet"
  else
    fail "T27: expected model=sonnet and --model sonnet (no opus), got model='${model}' command_template='${cmpl}'"
  fi
  rm -rf "$root"
}

# ── T28: G-1 repro — active downgrade + bad-timestamp row caps BOTH fields ──
test_t28_g1_active_downgrade_bad_ts_caps_both() {
  local root; root="$(_fixture_root)"
  local costs; costs="$(_dg_event 700 sonnet)"$'
'"$(_cost_row 0.5 60)"$'
'"$(_cost_row 0.3 "")"
  _write_costs "$root" "T28" "$costs"
  local out model cmpl
  out="$(_run_router "$root" "T28")"
  model="$(_kv model "$out")"
  cmpl="$(_kv command_template "$out")"
  if [[ "$model" == "sonnet" ]]      && printf '%s' "$cmpl" | grep -q -- '--model sonnet'      && ! printf '%s' "$cmpl" | grep -q -- '--model opus'; then
    pass "T28 (G-1): active downgrade + one bad-timestamp row (T14 shape, downgrade_active=unknown) -> BOTH fields capped to sonnet"
  else
    fail "T28: expected model=sonnet and --model sonnet (no opus), got model='${model}' command_template='${cmpl}'"
  fi
  rm -rf "$root"
}

# ── T25: G-2 repro — bandit ON + active downgrade never exceeds the cap ────
# Bandit is stochastic (Thompson sampling over persistent state) — rather
# than depend on it picking a SPECIFIC arm, this asserts the INVARIANT the
# choke-point exists to guarantee regardless of what bandit proposes:
# model= and command_template's --model AGREE, and neither ever exceeds the
# forced cap tier (sonnet here). This deterministically catches G-2 (bandit
# picking above the cap) and any model=/command_template= desync.
test_t25_bandit_on_active_downgrade_never_exceeds_cap() {
  local root; root="$(_fixture_root)"
  local costs; costs="$(_dg_event 700 sonnet)"$'
'"$(_cost_row 0.05 3000)"
  _write_costs "$root" "T25" "$costs"
  local out model cmpl cmpl_model
  out="$(env -i PATH="$PATH" PROJECT_ROOT="$root" LEADV2_ROUTE_BANDIT=1     LEADV2_BANDIT_ALLOWED_ARMS='["sonnet","opus"]'     bash "$ROUTER_SH" --phase build --step single_file     --task-id "T25" --class Standard 2>/dev/null)"
  model="$(_kv model "$out")"
  cmpl="$(_kv command_template "$out")"
  cmpl_model="$(printf '%s' "$cmpl" | grep -oE -- '--model [a-zA-Z-]+' | awk '{print $2}')"
  if [[ "$model" == "$cmpl_model" ]] && [[ "$model" != opus* ]] && [[ "$cmpl_model" != opus* ]]; then
    pass "T25 (G-2): bandit ON + active downgrade -> model= and command_template AGREE ('${model}'), never exceeds forced cap (sonnet), regardless of bandit's stochastic pick"
  else
    fail "T25: expected model==command_template's --model and never opus, got model='${model}' command_template_model='${cmpl_model}'"
  fi
  rm -rf "$root"
}

# ── T26: day-0 + bandit ON -> opus ships UNCAPPED in both fields (F-A/G-2) ──
test_t26_day0_bandit_no_overcorrection() {
  local root; root="$(_fixture_root)"
  local out model cmpl cmpl_model
  out="$(env -i PATH="$PATH" PROJECT_ROOT="$root" LEADV2_ROUTE_BANDIT=1     LEADV2_BANDIT_ALLOWED_ARMS='["opus"]'     bash "$ROUTER_SH" --phase build --step single_file     --task-id "T26" --class Standard 2>/dev/null)"
  model="$(_kv model "$out")"
  cmpl="$(_kv command_template "$out")"
  cmpl_model="$(printf '%s' "$cmpl" | grep -oE -- '--model [a-zA-Z-]+' | awk '{print $2}')"
  if [[ "$model" == opus* ]] && [[ "$cmpl_model" == "opus" ]]; then
    pass "T26 (F-A + G-2): day-0/never-spent + bandit ON -> opus ships UNCAPPED in both fields (no over-correction)"
  else
    fail "T26: expected model=opus* and command_template --model opus, got model='${model}' command_template_model='${cmpl_model}'"
  fi
  rm -rf "$root"
}

# ── T29: G-3 repro — malformed row (__HOLD__) on active downgrade caps to SAFE_FLOOR ──
# downgrade_active resolves "true" (a valid-timestamp row parsed far enough
# to reach the active branch), but force_model="__HOLD__" (to_model key
# missing from the malformed row). Round-3's trigger only checked
# force_model truthiness, so this fell through uncapped. Mirrors the
# consumer (claude-subsession.sh's own __HOLD__+active branch, which already
# forces haiku in this exact shape).
test_t29_g3_malformed_hold_caps_to_safe_floor() {
  local root; root="$(_fixture_root)"
  local costs; costs="$(_dg_event_no_to_model 700)"$'
'"$(_cost_row 0.05 60)"
  _write_costs "$root" "T29" "$costs"
  local out model cmpl da fm
  out="$(_run_router "$root" "T29")"
  model="$(_kv model "$out")"
  cmpl="$(_kv command_template "$out")"
  da="$(_kv downgrade_active "$out")"
  fm="$(_kv force_model "$out")"
  if [[ "$da" == "true" ]] && [[ "$fm" == "__HOLD__" ]]      && [[ -n "$model" ]] && [[ "$model" == "haiku" ]]      && [[ -n "$cmpl" ]] && printf '%s' "$cmpl" | grep -qF -- '--model haiku '      && _assert_template_placeholders "$cmpl"; then
    pass "T29 (G-3): malformed downgrade_event (valid ts, no to_model) -> downgrade_active=true, force_model=__HOLD__ -> BOTH fields capped to SAFE_FLOOR (haiku), matching consumer"
  else
    fail "T29: expected downgrade_active=true, force_model=__HOLD__, model=haiku, --model haiku in template, got da='${da}' fm='${fm}' model='${model}' command_template='${cmpl}'"
  fi
  rm -rf "$root"
}

# ── T30: fix-round-5 Critical repro — existing downgrade_event + bad ts ────
# The exact repro the round-5 reviewer pinpointed: costs.yaml EXISTS with a
# REAL downgrade_event row (not day-0), but the row's OWN timestamp is
# missing/garbage (partial write / race / hand-edit / clock skew). `active`
# is bound True before the ts-parse raise, so the except handler must report
# downgrade_active="true" (not "unknown", which would be textually identical
# to true day-0 and let G-3's =="true" check never fire). Two variants:
# (a) to_model present -> force_model=that model; (b) to_model absent too ->
# force_model=__HOLD__. BOTH must cap model=/command_template to SAFE_FLOOR
# (haiku) since the proposed base model (opus-subsession) always ranks above
# either target.
_dg_event_bad_ts() { # _dg_event_bad_ts <to_model-or-empty>
  local to_model="${1:-}"
  if [[ -n "$to_model" ]]; then
    printf -- '- downgrade_event:
    timestamp: NOT-A-TIMESTAMP
    reason: cost_ceiling_60pct
    from_model: opus
    to_model: %s
    affected_role: developer
    burn_usd: 1.5
    ceiling_usd: 2.00
' "$to_model"
  else
    printf -- '- downgrade_event:
    timestamp: NOT-A-TIMESTAMP
    reason: cost_ceiling_60pct
    from_model: opus
    affected_role: developer
    burn_usd: 1.5
    ceiling_usd: 2.00
'
  fi
}

test_t30_g3_existing_downgrade_bad_ts_caps_to_safe_floor() {
  local root; root="$(_fixture_root)"

  # Variant (a): to_model present, timestamp garbage.
  local costs_a; costs_a="$(_dg_event_bad_ts sonnet)"
  _write_costs "$root" "T30A" "$costs_a"
  local out_a da_a model_a cmpl_a
  out_a="$(_run_router "$root" "T30A")"
  da_a="$(_kv downgrade_active "$out_a")"
  model_a="$(_kv model "$out_a")"
  cmpl_a="$(_kv command_template "$out_a")"

  # Variant (b): to_model ALSO absent, timestamp garbage.
  local costs_b; costs_b="$(_dg_event_bad_ts "")"
  _write_costs "$root" "T30B" "$costs_b"
  local out_b da_b model_b cmpl_b
  out_b="$(_run_router "$root" "T30B")"
  da_b="$(_kv downgrade_active "$out_b")"
  model_b="$(_kv model "$out_b")"
  cmpl_b="$(_kv command_template "$out_b")"

  # Variant (a) caps to the KNOWN to_model (sonnet) -- the cap targets
  # the real recorded downgrade tier, not the generic floor, whenever it
  # is known (established rounds 2-4 semantics: SAFE_FLOOR is the
  # __HOLD__ fallback ONLY). Variant (b), where to_model itself is also
  # missing, correctly falls back to SAFE_FLOOR (haiku).
  if [[ "$da_a" == "true" ]] && [[ "$model_a" == "sonnet" ]] && printf '%s' "$cmpl_a" | grep -qF -- '--model sonnet ' && ! printf '%s' "$cmpl_a" | grep -qF -- 'opus' && _assert_template_placeholders "$cmpl_a" && [[ "$da_b" == "true" ]] && [[ "$model_b" == "haiku" ]] && printf '%s' "$cmpl_b" | grep -qF -- '--model haiku ' && ! printf '%s' "$cmpl_b" | grep -qF -- 'opus' && _assert_template_placeholders "$cmpl_b"; then
    pass "T30 (fix-round-5 Critical): EXISTING downgrade_event + garbage timestamp -> downgrade_active=true (not day-0-colliding unknown); to_model-known variant caps to sonnet, to_model-absent variant caps to SAFE_FLOOR (haiku) -- neither ships opus"
  else
    fail "T30: variant(a) da='${da_a}' model='${model_a}' cmpl='${cmpl_a}' | variant(b) da='${da_b}' model='${model_b}' cmpl='${cmpl_b}'"
  fi
  rm -rf "$root"
}

# ── syntax guard on both edited shared-source files ─────────────────────────
test_syntax_check() {
  if bash -n "$ROUTER_SH" 2>/dev/null && bash -n "$SUBSESSION_SH" 2>/dev/null; then
    pass "bash -n syntax OK on leadv2-router.sh + claude-subsession.sh"
  else
    fail "bash -n syntax check failed"
  fi
}

test_t1_persists_across_spawn
test_t2_t3_recovery_then_retrip
test_t4_hysteresis_dead_band
test_t5_corrupt_yaml_unknown
test_t6_missing_timestamp_holds_to_model
test_t7_future_ts_holds
test_t8_missing_file_keeps_inherited
test_t9_hard_stop_never_recovers
test_t10_min_dwell_blocks_recovery
test_t11_flag_off_never_clears
test_t12_toctou_concurrent_lock
test_t13_empty_cost_rows_unknown
test_t14_mixed_missing_ts_unknown
test_t15_corrupt_no_premium_spawn
test_t16_flock_fail_holds
test_t17_lock_timeout_no_hang
test_t18_force_not_inherited_across_task
test_t19_no_task_id_byte_identical
test_t20_day0_premium_allowed
test_t21_active_downgrade_caps_both_fields
test_t22_corrupt_refuses_both_fields
test_t23_consumer_fresh_process_adopts_force
test_t24_costflush_lock_timeout
test_t25_bandit_on_active_downgrade_never_exceeds_cap
test_t26_day0_bandit_no_overcorrection
test_t27_g1_active_downgrade_zero_cost_rows_caps_both
test_t28_g1_active_downgrade_bad_ts_caps_both
test_t29_g3_malformed_hold_caps_to_safe_floor
test_t30_g3_existing_downgrade_bad_ts_caps_to_safe_floor
test_syntax_check

echo ""
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
if [[ "$FAIL" -gt 0 ]]; then
  printf '%s\n' "${ERRORS[@]}"
  exit 1
fi
exit 0
