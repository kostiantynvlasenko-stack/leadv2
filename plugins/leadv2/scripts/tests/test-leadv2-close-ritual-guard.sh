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

run_case() {
  local label="$1"
  local msg="$2"
  local expect_exit="$3"
  local extra_env="${4:-}"

  local json actual_exit=0
  json="$(make_json "$msg")"

  if [[ -n "$extra_env" ]]; then
    env "$extra_env" bash "$HOOK" <<< "$json" >/dev/null 2>&1 || actual_exit=$?
  else
    bash "$HOOK" <<< "$json" >/dev/null 2>&1 || actual_exit=$?
  fi

  if [[ "$actual_exit" == "$expect_exit" ]]; then
    printf 'PASS  [%s]\n' "$label"
    pass=$(( pass + 1 ))
  else
    printf 'FAIL  [%s] — expected exit %s, got %s\n' "$label" "$expect_exit" "$actual_exit"
    fail=$(( fail + 1 ))
  fi
}

# NEGATIVE cases (must exit 0 — no block)
run_case "neg:fix-close-leak"     'git commit -m "fix: close DB connection leak in FIX-123"'  0
run_case "neg:docs-closing-notes" 'git commit -m "docs: closing notes for ABC-9"'             0
run_case "neg:feat-close-button"  'git commit -m "feat: add close button"'                    0
run_case "neg:chore-cleanup"      'git commit -m "chore: cleanup deps"'                       0
run_case "neg:non-commit"         'git status'                                                 0

# POSITIVE cases (must exit 2 — no closed/*.yaml exists in tmpdir)
run_case "pos:chore-close-zzz999" 'git commit -m "chore: close ZZZ-999"'  2
run_case "pos:docs-close-fix99"   'git commit -m "docs: close FIX-99"'    2
run_case "pos:fix-close-task1"    'git commit -m "fix: close TASK-1"'     2

# ESCAPE hatch: LEADV2_SKIP_CLOSE_GUARD=1 must exit 0
run_case "escape:skip-guard" 'git commit -m "chore: close ZZZ-999"' 0 "LEADV2_SKIP_CLOSE_GUARD=1"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
