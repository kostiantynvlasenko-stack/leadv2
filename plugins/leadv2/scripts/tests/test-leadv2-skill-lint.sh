#!/usr/bin/env bash
# tests/test-leadv2-skill-lint.sh — unit tests for leadv2-skill-lint.sh
# (deterministic ZERO-LLM linter for skill/agent-config files).
#
# Coverage:
#   (a) bad fixture (dup frontmatter key, placeholder description, unbounded
#       loop+spawn language, undeclared tool) -> exit 2 (HIGH present)
#   (b) clean fixture (well-formed frontmatter, real description, capped
#       iteration, declared tools) -> exit 0
#   (c) missing file -> exit 1 (usage/internal error), not silently exit 0
#   (d) shellcheck passes on the linter itself
#
# Run: bash scripts/tests/test-leadv2-skill-lint.sh
# Exit 0 = all pass; non-zero = failures found.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
LINTER="${SCRIPTS_DIR}/leadv2-skill-lint.sh"
FIXTURES="${SCRIPT_DIR}/fixtures"

PASS=0
FAIL=0
ERRORS=()

log()  { printf -- '[TEST] %s\n' "$*"; }
pass() { PASS=$(( PASS + 1 )); log "PASS: $1"; }
fail() { FAIL=$(( FAIL + 1 )); ERRORS+=("FAIL: $1"); log "FAIL: $1"; }

if bash -n "$LINTER" 2>/dev/null; then
  pass "bash -n syntax check: leadv2-skill-lint.sh"
else
  fail "bash -n syntax check: leadv2-skill-lint.sh"
fi

if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck -x "$LINTER" >/dev/null 2>&1; then
    pass "shellcheck: leadv2-skill-lint.sh"
  else
    fail "shellcheck: leadv2-skill-lint.sh"
  fi
else
  log "shellcheck not installed — skipping shellcheck check"
fi

rc=0
bash "$LINTER" "${FIXTURES}/skill-lint-bad/SKILL.md" >/tmp/skill-lint-bad.out 2>&1 || rc=$?
if [[ "$rc" -eq 2 ]]; then
  pass "bad fixture -> exit 2 (HIGH finding present)"
else
  fail "bad fixture -> expected exit 2, got $rc"
fi
if grep -q 'frontmatter-duplicate-key:HIGH' /tmp/skill-lint-bad.out; then
  pass "bad fixture -> duplicate frontmatter key detected"
else
  fail "bad fixture -> duplicate frontmatter key NOT detected"
fi
if grep -q 'loop-no-termination:HIGH' /tmp/skill-lint-bad.out; then
  pass "bad fixture -> unbounded loop+spawn detected"
else
  fail "bad fixture -> unbounded loop+spawn NOT detected"
fi

rc=0
bash "$LINTER" "${FIXTURES}/skill-lint-clean/SKILL.md" >/tmp/skill-lint-clean.out 2>&1 || rc=$?
if [[ "$rc" -eq 0 ]]; then
  pass "clean fixture -> exit 0"
else
  fail "clean fixture -> expected exit 0, got $rc (output: $(cat /tmp/skill-lint-clean.out))"
fi

rc=0
bash "$LINTER" "${FIXTURES}/does-not-exist/SKILL.md" >/tmp/skill-lint-missing.out 2>&1 || rc=$?
if [[ "$rc" -eq 1 ]]; then
  pass "missing file -> exit 1 (not silently 0)"
else
  fail "missing file -> expected exit 1, got $rc"
fi

rm -f /tmp/skill-lint-bad.out /tmp/skill-lint-clean.out /tmp/skill-lint-missing.out

log "----"
log "PASS=$PASS FAIL=$FAIL"
if [[ "$FAIL" -gt 0 ]]; then
  printf '%s\n' "${ERRORS[@]}"
  exit 1
fi
exit 0
