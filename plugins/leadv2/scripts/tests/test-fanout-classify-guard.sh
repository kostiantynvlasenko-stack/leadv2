#!/usr/bin/env bash
# tests/test-fanout-classify-guard.sh — SUPERVISE-V2-01 fix-1 (critic C2):
# leadv2-fanout.sh had ZERO test coverage before this fix. Covers the two
# concrete regressions the review caught:
#   1. classify_task(): a missing/non-executable leadv2-fanout-classify.sh
#      used to silently force-escalate EVERY task to Heavy/opus (via a bare
#      except-Exception branch with no stderr message). Fixed: existence
#      guard -> loud WARN -> safe fallback (existing class or Standard),
#      never a silent Heavy escalation.
#   2. launch_headless(): a missing/non-executable leadv2-session-runner.sh
#      must fail closed. A raw one-shot fallback cannot prove Phase 0..8 or
#      the canonical Phase-8 completion proof.
#
# Tests:
#   1. bash -n syntax check (fanout.sh + the two promoted scripts)
#   2. classify script present -> Standard (no risk keywords), no WARN
#   3. classify script hidden -> WARN on stderr, class falls back to
#      Standard/existing (NOT Heavy) -- calls the REAL fanout.sh --dry-run,
#      not a reimplementation
#   4. session-runner hidden -> real --headless launch is refused loudly
#
# Portable: no GNU-only date/sed -i/timeout/flock. Sandboxed via
# LEADV2_PROJECT_ROOT / LEADV2_STATE_ROOT / LEADV2_FANOUT_CLAUDE_BIN /
# LEADV2_FANOUT_TMUX_SESSION env overrides -- never touches the real repo's
# docs/leadv2/active.yaml or a real "leadv2" tmux session.
# Run: bash scripts/tests/test-fanout-classify-guard.sh
# Exit 0 = all pass; non-zero = failures found.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
FANOUT_SH="${SCRIPTS_ROOT}/leadv2-fanout.sh"
CLASSIFY_SH="${SCRIPTS_ROOT}/leadv2-fanout-classify.sh"
RUNNER_SH="${SCRIPTS_ROOT}/leadv2-session-runner.sh"

PASS=0; FAIL=0; ERRORS=()
log()  { printf -- '[TEST] %s\n' "$*"; }
pass() { PASS=$((PASS + 1)); log "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); ERRORS+=("FAIL: $1"); log "FAIL: $1"; }

_new_sandbox() {
  local d
  d="$(mktemp -d /tmp/fanoutcg-test-XXXXXX)"
  mkdir -p "${d}/proj/docs/leadv2" "${d}/state"
  cat > "${d}/proj/docs/leadv2/active.yaml" <<'YAML'
meta:
  schema_version: 2
  hard_limit: 20
  heavy_strategic_solo: true
  light_max: 3
  standard_max: 2
  rendered_at: ""
sessions: []
YAML
  cat > "${d}/proj/docs/tasks.yaml" <<YAML
tasks:
  - id: FCG-T1
    status: queued
    intent: "harmless test task, no risk keywords"
    priority: 5
YAML
  printf -- '%s' "$d"
}

test_1_syntax() {
  log "Test 1: bash -n syntax check"
  if bash -n "$FANOUT_SH" 2>/dev/null \
     && bash -n "$CLASSIFY_SH" 2>/dev/null \
     && bash -n "$RUNNER_SH" 2>/dev/null; then
    pass "Test 1: bash -n OK (fanout + classify + session-runner)"
  else
    fail "Test 1: bash -n FAILED"
  fi
}

test_2_classify_present_standard() {
  log "Test 2: classify script present -> class=Standard, no WARN"
  local sandbox out
  sandbox="$(_new_sandbox)"
  out="$(
    LEADV2_PROJECT_ROOT="${sandbox}/proj" LEADV2_STATE_ROOT="${sandbox}/state" \
      LEADV2_SKIP_DRIFT_GUARD=1 \
      bash "$FANOUT_SH" --provider claude --dry-run --tasks FCG-T1 2>&1
  )" || true
  rm -rf "$sandbox"
  if [[ "$out" == *"class=Standard"* && "$out" != *"classify script unavailable"* ]]; then
    pass "Test 2: class=Standard, classifier ran normally"
  else
    fail "Test 2: out=$out"
  fi
}

test_3_classify_missing_safe_fallback() {
  log "Test 3: classify script hidden -> loud WARN + safe fallback (NOT Heavy)"
  local sandbox out hidden
  sandbox="$(_new_sandbox)"
  hidden="${CLASSIFY_SH}.hidden-for-test"
  mv "$CLASSIFY_SH" "$hidden"
  trap 'mv "'"$hidden"'" "'"$CLASSIFY_SH"'" 2>/dev/null || true' RETURN
  out="$(
    LEADV2_PROJECT_ROOT="${sandbox}/proj" LEADV2_STATE_ROOT="${sandbox}/state" \
      LEADV2_SKIP_DRIFT_GUARD=1 \
      bash "$FANOUT_SH" --provider claude --dry-run --tasks FCG-T1 2>&1
  )" || true
  mv "$hidden" "$CLASSIFY_SH"
  trap - RETURN
  rm -rf "$sandbox"
  if [[ "$out" == *"WARN: leadv2-fanout-classify.sh missing"* && "$out" == *"class=Standard"* && "$out" != *"class=Heavy"* ]]; then
    pass "Test 3: loud WARN printed, class=Standard (no silent Heavy escalation)"
  else
    fail "Test 3: out=$out"
  fi
}

test_4_runner_missing_fails_closed() {
  log "Test 4: session-runner hidden -> real headless launch fails closed"
  local sandbox out hidden stub
  sandbox="$(_new_sandbox)"
  hidden="${RUNNER_SH}.hidden-for-test"
  mv "$RUNNER_SH" "$hidden"
  trap 'mv "'"$hidden"'" "'"$RUNNER_SH"'" 2>/dev/null || true' RETURN
  stub="${sandbox}/claude-stub.sh"
  cat > "$stub" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
  chmod +x "$stub"
  out="$(
    LEADV2_PROJECT_ROOT="${sandbox}/proj" LEADV2_STATE_ROOT="${sandbox}/state" \
      LEADV2_SKIP_DRIFT_GUARD=1 \
      LEADV2_FANOUT_CLAUDE_BIN="$stub" \
      bash "$FANOUT_SH" --provider claude --headless --tasks FCG-T1 2>&1
  )" || true
  mv "$hidden" "$RUNNER_SH"
  trap - RETURN
  rm -rf "$sandbox"
  if [[ "$out" == *"ERROR: leadv2-session-runner.sh missing/not executable"* && "$out" != *"headless launch: task=FCG-T1"* ]]; then
    pass "Test 4: missing completion runner refused the launch"
  else
    fail "Test 4: out=$out"
  fi
}

main() {
  log "=== leadv2-fanout.sh classify/runner existence-guard tests ==="
  log "fanout: $FANOUT_SH"
  echo ""
  test_1_syntax
  test_2_classify_present_standard
  test_3_classify_missing_safe_fallback
  test_4_runner_missing_fails_closed
  echo ""
  log "=== Results: PASS=$PASS FAIL=$FAIL ==="
  if [[ "${#ERRORS[@]}" -gt 0 ]]; then
    log "Failures:"
    for e in "${ERRORS[@]}"; do log "  $e"; done
    exit 1
  fi
  log "All tests passed."
  exit 0
}

main "$@"
