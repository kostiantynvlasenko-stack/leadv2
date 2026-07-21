#!/usr/bin/env bash
# Reproducible, no-model/no-network core regression suite for the leadv2
# plugin. Covers manifest loading, shell syntax, provider routing/runners,
# supervisor isolation, active registry, and Phase-8 completion guards.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$PLUGIN_ROOT/../.." && pwd)"
PASS=0
FAIL=0

run_check() {
  local name="$1"
  shift
  printf -- '\n[CORE-OFFLINE] %s\n' "$name"
  if "$@"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf -- '[CORE-OFFLINE] FAILED: %s\n' "$name" >&2
  fi
}

syntax_all() {
  local file
  while IFS= read -r file; do
    bash -n "$file"
  done < <(find "$PLUGIN_ROOT" -type f -name '*.sh' -print | sort)
}

validate_plugin() {
  if ! command -v claude >/dev/null 2>&1; then
    printf -- '[CORE-OFFLINE] claude CLI unavailable; manifest validation cannot run\n' >&2
    return 1
  fi
  claude plugin validate "$PLUGIN_ROOT"
}

run_check "all plugin shell syntax" syntax_all
run_check "portable temp helper stress" bash "$TEST_DIR/test-leadv2-temp-stress.sh"
run_check "Claude plugin manifest/components" validate_plugin
run_check "provider/model router" bash "$TEST_DIR/test-session-route.sh"
run_check "Codex full-cycle runner" bash "$TEST_DIR/test-codex-session-runner.sh"
run_check "autonomous session spawner" bash "$TEST_DIR/test-session-spawner.sh"
run_check "hook token + mode isolation" bash "$TEST_DIR/test-hook-token-mode-isolation.sh"
run_check "main model/live quota" bash "$TEST_DIR/test-main-model-check.sh"
run_check "active registry fail-closed" bash "$TEST_DIR/test-active-registry-failclosed.sh"
run_check "active registry phase updates" bash "$TEST_DIR/test-active-registry-update-phase.sh"
run_check "fanout classifier/runner guard" bash "$TEST_DIR/test-fanout-classify-guard.sh"
run_check "supervisor fail-closed" bash "$TEST_DIR/test-supervise-failclosed.sh"
run_check "supervisor reconciliation" bash "$TEST_DIR/test-supervise-v2.sh"
run_check "supervisor/lead PID isolation" bash "$PLUGIN_ROOT/tests/test-supervise-fanout-guard.sh"
run_check "Phase-8 task schema" bash "$TEST_DIR/test-leadv2-phase8-assert-a2-schema.sh"
run_check "Phase-8 merge/completion proof" bash "$PLUGIN_ROOT/tests/test-deploy-merge-blocker-gate.sh"
run_check "subsession model downgrade" bash "$TEST_DIR/test-leadv2-model-arg-rebuild.sh"
run_check "plugin sync quarantine/dry-run safety" bash "$TEST_DIR/test-drift-guard-quarantine-perimeter.sh"
run_check "skill lint" bash "$TEST_DIR/test-leadv2-skill-lint.sh"

printf -- '\n[CORE-OFFLINE] suites passed=%d failed=%d repo=%s\n' "$PASS" "$FAIL" "$REPO_ROOT"
(( FAIL == 0 ))
