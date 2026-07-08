#!/usr/bin/env bash
# tests/test-leadv2-learn-freeform-flag.sh -- REFLECT-CAUSAL-CRITIQUE-01 fix-round-2 (H2).
#
# Proves LEADV2_CAUSAL_CRITIQUE=0 (default/off) leaves leadv2-learn.js's return object shape
# byte-identical to pre-diff behavior (no `freeform_recalled` key at all), and =1 (on) adds the
# key. Runs the REAL, unmodified leadv2-learn.js source via
# fixtures/learn-freeform-flag-harness.mjs (same Function-wrap methodology as the
# causal-critique test suite).
#
# Tests:
#   1. node --check on leadv2-learn.js
#   2. flag OFF: 'freeform_recalled' NOT a key on the returned object (byte-identical)
#   3. flag ON: 'freeform_recalled' IS a key on the returned object (feature reachable)
#
# Run: bash scripts/tests/test-leadv2-learn-freeform-flag.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
WORKFLOW_JS="${PLUGIN_ROOT}/workflows/leadv2-learn.js"
HARNESS="${SCRIPT_DIR}/fixtures/learn-freeform-flag-harness.mjs"

PASS=0; FAIL=0; ERRORS=()
log()  { printf -- '[TEST] %s\n' "$*"; }
pass() { PASS=$((PASS + 1)); log "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); ERRORS+=("$1"); log "FAIL: $1"; }

FIXTURE_DIR="$(mktemp -d)"
trap 'rm -rf "$FIXTURE_DIR"' EXIT
(
  cd "$FIXTURE_DIR"
  git init -q
  git config user.email test@test.local
  git config user.name test
  mkdir -p docs/leadv2 docs/leadv2/learning-proposals
  git add -A 2>/dev/null || true
  git commit -q -m "fixture base" --allow-empty
)

if node --check "$WORKFLOW_JS" 2>/tmp/learn-synerr.log; then
  pass "leadv2-learn.js passes node --check"
else
  fail "node --check failed: $(cat /tmp/learn-synerr.log)"
fi

OFF_OUT="$(node "$HARNESS" "$FIXTURE_DIR" "$WORKFLOW_JS" off 2>/tmp/learn-off.err || true)"
if [[ -z "$OFF_OUT" ]]; then
  fail "flag-off run produced no output; stderr: $(cat /tmp/learn-off.err)"
else
  HAS_KEY_OFF=$(printf '%s' "$OFF_OUT" | python3 -c "import json,sys; print(json.load(sys.stdin)['hasKey'])")
  if [[ "$HAS_KEY_OFF" == "False" ]]; then
    pass "H2 fix: LEADV2_CAUSAL_CRITIQUE=0 -> return object has NO freeform_recalled key (byte-identical)"
  else
    fail "H2 REGRESSION: flag off but freeform_recalled key is present"
  fi
fi

ON_OUT="$(node "$HARNESS" "$FIXTURE_DIR" "$WORKFLOW_JS" on 2>/tmp/learn-on.err || true)"
if [[ -z "$ON_OUT" ]]; then
  fail "flag-on run produced no output; stderr: $(cat /tmp/learn-on.err)"
else
  HAS_KEY_ON=$(printf '%s' "$ON_OUT" | python3 -c "import json,sys; print(json.load(sys.stdin)['hasKey'])")
  if [[ "$HAS_KEY_ON" == "True" ]]; then
    pass "LEADV2_CAUSAL_CRITIQUE=1 -> return object HAS freeform_recalled key (feature reachable)"
  else
    fail "flag on but freeform_recalled key is missing -- 4th Gather leg not wired"
  fi
fi

echo ""
echo "=== leadv2-learn-freeform-flag test summary: $PASS passed, $FAIL failed ==="
if [[ $FAIL -gt 0 ]]; then
  printf '  - %s\n' "${ERRORS[@]}"
  exit 1
fi
exit 0
