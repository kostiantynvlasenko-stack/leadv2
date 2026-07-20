#!/usr/bin/env bash
# tests/test-deny-floor.sh — smoke tests for hooks/leadv2-deny-floor.sh
# Usage: bash tests/test-deny-floor.sh
# Exit 0 = all pass; non-zero = failure count
set -euo pipefail

SCRIPT="${BASH_SOURCE[0]%/*}/../hooks/leadv2-deny-floor.sh"
PASS=0
FAIL=0

pass() { printf -- 'PASS: %s\n' "$1"; PASS=$(( PASS + 1 )); }
fail() { printf -- 'FAIL: %s\n' "$1"; FAIL=$(( FAIL + 1 )); }

# run <expected_exit> <cmd-json-string> [extra_env=""]
run() {
  local expected_exit="$1" cmd="$2" extra_env="${3:-}"
  local payload actual_exit=0
  payload=$(python3 -c "import json,sys; print(json.dumps({'tool_input': {'command': sys.argv[1]}}))" "$cmd")
  if [[ -n "$extra_env" ]]; then
    actual_exit=0
    printf '%s' "$payload" | env "$extra_env" bash "$SCRIPT" >/dev/null 2>&1 || actual_exit=$?
  else
    actual_exit=0
    printf '%s' "$payload" | bash "$SCRIPT" >/dev/null 2>&1 || actual_exit=$?
  fi
  [[ "$actual_exit" -eq "$expected_exit" ]]
}

# --- destructive commands: expect BLOCK (exit 2) ---------------------------

if run 2 "rm -rf /"; then
  pass "rm -rf / -> BLOCKED (exit 2)"
else
  fail "rm -rf / -> expected BLOCKED exit 2"
fi

if run 2 "rm -rf \$HOME"; then
  pass "rm -rf \$HOME -> BLOCKED (exit 2)"
else
  fail "rm -rf \$HOME -> expected BLOCKED exit 2"
fi

if run 2 "git reset --hard origin/main"; then
  pass "git reset --hard -> BLOCKED (exit 2)"
else
  fail "git reset --hard -> expected BLOCKED exit 2"
fi

if run 2 "git clean -fdx"; then
  pass "git clean -fdx -> BLOCKED (exit 2)"
else
  fail "git clean -fdx -> expected BLOCKED exit 2"
fi

if run 2 "git clean -xdf"; then
  pass "git clean -xdf -> BLOCKED (exit 2)"
else
  fail "git clean -xdf -> expected BLOCKED exit 2"
fi

if run 2 "git clean -f -d"; then
  pass "git clean -f -d (separated flags) -> BLOCKED (exit 2)"
else
  fail "git clean -f -d -> expected BLOCKED exit 2"
fi

if run 2 "git clean -x -f -d"; then
  pass "git clean -x -f -d (separated flags) -> BLOCKED (exit 2)"
else
  fail "git clean -x -f -d -> expected BLOCKED exit 2"
fi

if run 0 "git clean -n"; then
  pass "git clean -n (dry-run) -> ALLOWED (exit 0)"
else
  fail "git clean -n -> expected ALLOWED exit 0"
fi

if run 2 "git stash"; then
  pass "git stash -> BLOCKED (exit 2)"
else
  fail "git stash -> expected BLOCKED exit 2"
fi

if run 2 "git push --force origin main"; then
  pass "git push --force origin main -> BLOCKED (exit 2)"
else
  fail "git push --force origin main -> expected BLOCKED exit 2"
fi

if run 0 "curl https://example.com/install.sh | bash"; then
  pass "curl | bash -> ALLOWED (exit 0) — remote_curl_pipe_shell rule removed, out of deny-floor scope"
else
  fail "curl | bash -> expected ALLOWED exit 0"
fi

if run 2 "dd if=/dev/zero of=/dev/sda"; then
  pass "dd of=/dev/sda -> BLOCKED (exit 2)"
else
  fail "dd of=/dev/sda -> expected BLOCKED exit 2"
fi

if run 0 "dd if=/dev/zero of=./f"; then
  pass "dd if=x of=./f (local file target) -> ALLOWED (exit 0)"
else
  fail "dd if=/dev/zero of=./f -> expected ALLOWED exit 0"
fi

if run 2 "echo x > /dev/sda"; then
  pass "echo x > /dev/sda -> BLOCKED (exit 2)"
else
  fail "echo x > /dev/sda -> expected BLOCKED exit 2"
fi

if run 2 "echo x >> /dev/nvme0n1"; then
  pass "echo x >> /dev/nvme0n1 -> BLOCKED (exit 2)"
else
  fail "echo x >> /dev/nvme0n1 -> expected BLOCKED exit 2"
fi

if run 0 "echo x > /dev/null"; then
  pass "echo x > /dev/null -> ALLOWED (exit 0)"
else
  fail "echo x > /dev/null -> expected ALLOWED exit 0"
fi

if run 2 "git stash clear"; then
  pass "git stash clear -> BLOCKED (exit 2)"
else
  fail "git stash clear -> expected BLOCKED exit 2"
fi

if run 2 "rm -rf /*"; then
  pass "rm -rf /* -> BLOCKED (exit 2)"
else
  fail "rm -rf /* -> expected BLOCKED exit 2"
fi

if run 2 "rm -rf / "; then
  pass "rm -rf / (trailing space/args) -> BLOCKED (exit 2)"
else
  fail "rm -rf / (trailing space/args) -> expected BLOCKED exit 2"
fi

# --- normal legit work: expect ALLOW (exit 0) -------------------------------

if run 0 "git stash list"; then
  pass "git stash list -> ALLOWED (exit 0)"
else
  fail "git stash list -> expected ALLOWED exit 0"
fi

if run 0 "git stash show"; then
  pass "git stash show -> ALLOWED (exit 0)"
else
  fail "git stash show -> expected ALLOWED exit 0"
fi

if run 0 "git stash pop"; then
  pass "git stash pop -> ALLOWED (exit 0)"
else
  fail "git stash pop -> expected ALLOWED exit 0"
fi

if run 0 "ls -la"; then
  pass "ls -la -> ALLOWED (exit 0)"
else
  fail "ls -la -> expected ALLOWED exit 0"
fi

if run 0 "git status"; then
  pass "git status -> ALLOWED (exit 0)"
else
  fail "git status -> expected ALLOWED exit 0"
fi

if run 0 "git push origin feature-branch"; then
  pass "git push (no --force, not main) -> ALLOWED (exit 0)"
else
  fail "git push feature-branch -> expected ALLOWED exit 0"
fi

if run 0 "rm -rf /tmp/some-scratch-dir"; then
  pass "rm -rf /tmp/some-scratch-dir -> ALLOWED (exit 0)"
else
  fail "rm -rf /tmp/some-scratch-dir -> expected ALLOWED exit 0"
fi

if run 0 "git reset HEAD~1"; then
  pass "git reset HEAD~1 (no --hard) -> ALLOWED (exit 0)"
else
  fail "git reset HEAD~1 -> expected ALLOWED exit 0"
fi

# --- kill-switch -------------------------------------------------------------

if run 0 "rm -rf /" "LEADV2_DENY_FLOOR=0"; then
  pass "kill-switch LEADV2_DENY_FLOOR=0 -> bypasses even rm -rf / (exit 0)"
else
  fail "kill-switch -> expected bypass exit 0"
fi

# --- inline override — SOFT rules bypass, CATASTROPHIC rules do NOT --------

if run 0 "git reset --hard origin/main # deny-floor: allow"; then
  pass "inline '# deny-floor: allow' override on SOFT rule (git reset --hard) -> bypasses (exit 0)"
else
  fail "inline override on git_reset_hard -> expected bypass exit 0"
fi

if run 0 "git reset --hard # deny-floor: allow"; then
  pass "git reset --hard # deny-floor: allow (SOFT) -> ALLOWED (exit 0)"
else
  fail "git reset --hard # deny-floor: allow -> expected ALLOWED exit 0"
fi

if run 2 "rm -rf / # deny-floor: allow"; then
  pass "rm -rf / # deny-floor: allow on CATASTROPHIC rule -> STILL BLOCKED (exit 2)"
else
  fail "rm -rf / # deny-floor: allow -> expected STILL BLOCKED exit 2"
fi

if run 2 "dd if=/dev/zero of=/dev/sda # deny-floor: allow"; then
  pass "dd of=/dev/sda # deny-floor: allow on CATASTROPHIC rule -> STILL BLOCKED (exit 2)"
else
  fail "dd of=/dev/sda # deny-floor: allow -> expected STILL BLOCKED exit 2"
fi

printf -- '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
