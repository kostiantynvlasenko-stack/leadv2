#!/usr/bin/env bash
# Regression guard: a Codex lead launched by the session runner must execute
# phases itself, never recurse into a runner/dispatcher.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SKILL="$PLUGIN_ROOT/codex-skills/source-command-leadv2/SKILL.md"
RUNNER="$PLUGIN_ROOT/scripts/leadv2-codex-session-runner.sh"
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf -- '[TEST] PASS: %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf -- '[TEST] FAIL: %s\n' "$1"; }

require_all() {
  local file="$1" label="$2" needle
  shift 2
  for needle in "$@"; do
    if ! grep -Fq -- "$needle" "$file"; then
      fail "$label missing: $needle"
      return
    fi
  done
  pass "$label forbids launcher self-invocation"
}

require_all "$SKILL" "skill" \
  "Child-session boundary — NEVER recurse" \
  "Never invoke" \
  "leadv2-codex-session-runner.sh" \
  "leadv2-session-runner.sh" \
  "leadv2-fanout.sh" \
  "leadv2-supervise.sh" \
  "per-phase helper scripts"
require_all "$RUNNER" "fresh and resume prompts" \
  "You ARE ALREADY the leadv2 headless child session" \
  "ALREADY-RUNNING leadv2 child session" \
  "CODEX-LEAD RECURSION" \
  "never session launchers"

printf -- '[TEST] Results: PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
