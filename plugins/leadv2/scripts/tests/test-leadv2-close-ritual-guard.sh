#!/usr/bin/env bash
# test-leadv2-close-ritual-guard.sh — unit test for leadv2-close-ritual-guard.sh
# Pipes fake PreToolUse JSON into the hook and asserts exit codes.
# Run from any directory; uses mktemp CWD so no closed/*.yaml exists.
set -euo pipefail

HOOK="$(cd "$(dirname "$0")/../.." && pwd)/hooks/leadv2-close-ritual-guard.sh"

if [[ ! -f "$HOOK" ]]; then
  printf 'ERROR: hook not found at %s\n' "$HOOK" >&2
  exit 1
fi

TMPDIR_CWD="$(mktemp -d)"
# shellcheck disable=SC2064
trap "rm -rf '${TMPDIR_CWD}'" EXIT

pass=0
fail=0

# Build valid JSON from a commit message using python3 for safe escaping.
make_json() {
  python3 -c "
import json,sys
cmd=sys.argv[1]; cwd=sys.argv[2]
print(json.dumps({'tool_input':{'command':cmd},'cwd':cwd}))
" "$1" "$TMPDIR_CWD"
}

# NOTE on protocol: the hook ALWAYS exits 0 (see leadv2-close-ritual-guard.sh
# lines 62-64) — blocking is communicated via stdout JSON
# {"hookSpecificOutput":{"permissionDecision":"deny",...}}, exit-2/stderr was
# dropped because Claude Code's PreToolUse hook protocol silently loses the
# reason on exit 2 (same pattern as leadv2-codex-nopoll-guard.sh). So a
# passing case must assert exit==0 AND the correct allow/deny verdict in
# stdout — asserting exit code alone would be tautological (always 0).
run_case() {
  local label="$1"
  local msg="$2"
  local expect_verdict="$3"   # "allow" or "deny"
  local extra_env="${4:-}"

  local json out="" actual_exit=0 verdict="allow"
  json="$(make_json "$msg")"

  if [[ -n "$extra_env" ]]; then
    out="$(env "$extra_env" bash "$HOOK" <<< "$json" 2>/dev/null)" || actual_exit=$?
  else
    out="$(bash "$HOOK" <<< "$json" 2>/dev/null)" || actual_exit=$?
  fi

  printf '%s' "$out" | grep -q '"permissionDecision":"deny"' && verdict="deny"

  if [[ "$actual_exit" == "0" && "$verdict" == "$expect_verdict" ]]; then
    printf 'PASS  [%s]\n' "$label"
    pass=$(( pass + 1 ))
  else
    printf 'FAIL  [%s] — expected exit 0/%s, got exit %s/%s\n' "$label" "$expect_verdict" "$actual_exit" "$verdict"
    fail=$(( fail + 1 ))
  fi
}

# NEGATIVE cases (must allow — no block)
run_case "neg:fix-close-leak"     'git commit -m "fix: close DB connection leak in FIX-123"'  allow
run_case "neg:docs-closing-notes" 'git commit -m "docs: closing notes for ABC-9"'             allow
run_case "neg:feat-close-button"  'git commit -m "feat: add close button"'                    allow
run_case "neg:chore-cleanup"      'git commit -m "chore: cleanup deps"'                       allow
run_case "neg:non-commit"         'git status'                                                 allow

# POSITIVE cases (must deny — no closed/*.yaml exists in tmpdir)
run_case "pos:chore-close-zzz999" 'git commit -m "chore: close ZZZ-999"'  deny
run_case "pos:docs-close-fix99"   'git commit -m "docs: close FIX-99"'    deny
run_case "pos:fix-close-task1"    'git commit -m "fix: close TASK-1"'     deny

# ESCAPE hatch: LEADV2_SKIP_CLOSE_GUARD=1 must allow
run_case "escape:skip-guard" 'git commit -m "chore: close ZZZ-999"' allow "LEADV2_SKIP_CLOSE_GUARD=1"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
