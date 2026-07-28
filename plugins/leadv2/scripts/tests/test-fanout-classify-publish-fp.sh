#!/usr/bin/env bash
# tests/test-fanout-classify-publish-fp.sh — RISK-TAG-FP-01 (2026-07-28):
# leadv2-fanout-classify.sh's [publish] risk group used a bare-word
# "publish|deploy" regex that false-fired on ordinary NOUN mentions
# (publish_slots table name, "the legacy comment publisher", "claim/publish
# code path"), forcing a non-bypassable HARD collision that serialized
# read-only lanes. Fixed to require an ACTION context (verb + article/
# preposition/target), while preserving the fail-closed bias: a genuinely
# publishing/deploying task must still classify Heavy.
#
# Calls the REAL leadv2-fanout-classify.sh directly (no reimplementation of
# the regex). Portable: no GNU-only date/sed -i/timeout/flock.
# Run: bash scripts/tests/test-fanout-classify-publish-fp.sh
# Exit 0 = all pass; non-zero = failures found.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CLASSIFY_SH="${SCRIPTS_ROOT}/leadv2-fanout-classify.sh"

PASS=0; FAIL=0; ERRORS=()
log()  { printf -- '[TEST] %s\n' "$*"; }
pass() { PASS=$((PASS + 1)); log "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); ERRORS+=("FAIL: $1"); log "FAIL: $1"; }

# _assert_no_publish_tag <label> <intent>
_assert_no_publish_tag() {
  local label="$1" intent="$2" out risk_tags
  out="$(bash "$CLASSIFY_SH" --intent "$intent")"
  risk_tags="$(printf '%s\n' "$out" | grep '^risk_tags=' | cut -d= -f2-)"
  if [[ "$risk_tags" != *"publish"* ]]; then
    pass "$label: risk_tags=[${risk_tags}] does not include publish"
  else
    fail "$label: expected NO publish tag, got risk_tags=[${risk_tags}] (intent=${intent})"
  fi
}

# _assert_publish_tag <label> <intent>
_assert_publish_tag() {
  local label="$1" intent="$2" out risk_tags class
  out="$(bash "$CLASSIFY_SH" --intent "$intent")"
  risk_tags="$(printf '%s\n' "$out" | grep '^risk_tags=' | cut -d= -f2-)"
  class="$(printf '%s\n' "$out" | grep '^launch_class=' | cut -d= -f2-)"
  if [[ "$risk_tags" == *"publish"* && "$class" == "Heavy" ]]; then
    pass "$label: risk_tags=[${risk_tags}] class=${class}"
  else
    fail "$label: expected publish tag + Heavy, got risk_tags=[${risk_tags}] class=${class} (intent=${intent})"
  fi
}

test_1_syntax() {
  log "Test 1: bash -n syntax check"
  if bash -n "$CLASSIFY_SH" 2>/dev/null; then
    pass "Test 1: bash -n OK"
  else
    fail "Test 1: bash -n FAILED"
  fi
}

main() {
  log "=== leadv2-fanout-classify.sh [publish] false-positive regression tests ==="
  echo ""
  test_1_syntax

  # MUST-PASS: mentions, not actions -> no publish tag
  _assert_no_publish_tag "FP-1 publish_slots table mention" \
    "platform/probes/outbox-funnel.sh returns HTTP 400 on its main slot-count query ... query publish_slots by tenant_id"
  _assert_no_publish_tag "FP-2 legacy comment publisher mention" \
    "assemble the exact deletion inventory for the legacy comment publisher ... file:line list of every legacy claim/publish code path"

  # MUST-PASS: genuine actions -> publish tag preserved (fail-closed)
  _assert_publish_tag "TP-1 deploy to prod VPS" \
    "flip PE_OUTBOX_MODE=enforce in prod .env and deploy to the VPS"
  _assert_publish_tag "TP-2 production migration" \
    "production migration adding a NOT NULL column"
  _assert_publish_tag "TP-3 publish a comment" \
    "publish a comment to Threads from the live persona"

  # Regression guard: existing test-fanout-heavy-max-collision.sh intents
  # must still fire (do not widen the false negative while fixing the FP).
  _assert_publish_tag "REG-1 deploy a schema migration to prod (HMC-B1)" \
    "deploy a schema migration to prod"
  _assert_publish_tag "REG-2 publish a data migration (HMC-B2)" \
    "publish a data migration"

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
