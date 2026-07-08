#!/usr/bin/env bash
# test-leadv2-shadow-promotion-gate.sh -- T9 SHADOW-PROMOTION-GATE-01 (fix-round 1: strict allow-list).
# Drives the REAL `leadv2-shadow-apply.sh --promote` path end-to-end against a fresh proposal
# fixture per scenario. Uses a STUB taskbench_gate (LEADV2_TASKBENCH_GATE_SCRIPT override) so the
# test never depends on the real persona-engine-local benchmark runner.
# NOTE: this suite takes ~35s wall-clock due to the real SIGTERM-ignoring hang test (must exercise
# the actual `timeout -k 5s 30s` hard-kill, not a mocked/shortened one).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHADOW_APPLY="${SCRIPT_DIR}/../leadv2-shadow-apply.sh"
STUB_DIR="$(mktemp -d)"
trap 'rm -rf "$STUB_DIR"' EXIT

PASS=0
FAIL=0

log_pass() { PASS=$((PASS + 1)); printf -- 'PASS: %s\n' "$1"; }
log_fail() { FAIL=$((FAIL + 1)); printf -- 'FAIL: %s\n' "$1"; }

strip_ts() { sed -E 's/[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z/<TS>/g'; }

# ── stub gate fixtures ──────────────────────────────────────────────────────
cat > "${STUB_DIR}/gate-promote.sh" << 'EOF'
taskbench_gate() { printf -- '%s\n' '{"verdict":"PROMOTE","reason":"stub-promote"}'; }
EOF
cat > "${STUB_DIR}/gate-reject.sh" << 'EOF'
taskbench_gate() { printf -- '%s\n' '{"verdict":"REJECT","reason":"stub-reject-regression"}'; }
EOF
cat > "${STUB_DIR}/gate-inconclusive.sh" << 'EOF'
taskbench_gate() { printf -- '%s\n' '{"verdict":"INCONCLUSIVE","reason":"n below floor"}'; }
EOF
cat > "${STUB_DIR}/gate-badjson.sh" << 'EOF'
taskbench_gate() { printf -- '%s\n' 'not-json-at-all'; }
EOF
cat > "${STUB_DIR}/gate-sourcing-error.sh" << 'EOF'
set -e
exit 7
EOF
cat > "${STUB_DIR}/gate-hang.sh" << 'EOF'
taskbench_gate() {
  trap '' TERM
  sleep 60
  printf -- '%s\n' '{"verdict":"PROMOTE"}'
}
EOF
cat > "${STUB_DIR}/gate-orphan-grandchild.sh" << 'EOF'
taskbench_gate() {
  # fire-and-forget subprocess that INHERITS stdout (fd 1) without redirecting it, then the
  # function returns normally -- this is exactly the pipe-wedge fix-round-2 fixes: `timeout`'s
  # tracked child (this function's shell) exits immediately, but a naive $(...) capture would
  # keep blocking until this orphaned grandchild's fd 1 closes (10s later).
  ( sleep 10 ) &
  printf -- '%s\n' '{"verdict":"PROMOTE","reason":"stub-orphan-grandchild"}'
}
EOF

# ── restricted-PATH builder (simulates "jq missing" without touching the real host PATH) ────────
build_path_without_jq() {
  local dir="$1"
  mkdir -p "$dir"
  local bin real
  for bin in bash dirname python3 mktemp cp flock patch rm timeout env grep date sed; do
    real="$(command -v "$bin" 2>/dev/null)" || continue
    ln -sf "$real" "${dir}/${bin}"
  done
  printf -- '%s' "$dir"
}
NOJQ_PATH="$(build_path_without_jq "${STUB_DIR}/nojq-bin")"

# ── fixture builder: fresh isolated LEADV2_PROJECT_ROOT + proposal + target file ────────────────
setup_fixture() {
  local root="$1"
  mkdir -p "${root}/docs/leadv2/shadow/proposals" "${root}/docs/leadv2/shadow/snapshots"
  printf -- 'line one\nline two\n' > "${root}/target.txt"
  local pid
  pid=$(python3 -c "import hashlib; print(hashlib.sha1(b'shadow-promotion-gate-test').hexdigest())")
  local patch_body
  patch_body=$(cd "$root" && diff -u target.txt <(printf -- 'line one\nline TWO-CANDIDATE\n') || true)
  patch_body="${patch_body//target.txt/a\/target.txt}"
  python3 - "$root" "$pid" "$patch_body" << 'PYEOF'
import sys, yaml
root, pid, patch_body = sys.argv[1], sys.argv[2], sys.argv[3]
proposal = {
    "id": pid,
    "task_id": "SHADOW-PROMOTION-GATE-01-fixture",
    "kind": "other",
    "risk_level": "low",
    "target_file": "target.txt",
    "before_snapshot": "",
    "diff_patch": patch_body,
    "arm": "A",
    "status": "pending",
    "proposed_at": "2026-01-01T00:00:00Z",
    "min_n_per_arm": 1,
}
with open(f"{root}/docs/leadv2/shadow/proposals/{pid}.yaml", "w") as f:
    yaml.dump(proposal, f, default_flow_style=False, sort_keys=False)
PYEOF
  printf -- '%s' "$pid"
}

run_promote() {
  local script="$1" root="$2" pid="$3"
  shift 3
  ( cd "$root" && env -i PATH="$PATH" HOME="$HOME" \
      LEADV2_PROJECT_ROOT="$root" LEADV2_SHADOW_ON_CLOSE=1 \
      "$@" bash "$script" --promote --proposal-id "$pid" ) 2>&1
}

proposal_status() {
  local root="$1" pid="$2"
  python3 -c "
import yaml
p = yaml.safe_load(open('${root}/docs/leadv2/shadow/proposals/${pid}.yaml')) or {}
print(p.get('status',''))
"
}

# generic HELD assertion: rc=4, status=blocked_by_eval, target file UNCHANGED, log_error reason
# substring present in combined output.
assert_held() {
  local label="$1" rc="$2" status="$3" target="$4" out="$5" expect_reason="$6"
  if [[ $rc -eq 4 && "$status" == "blocked_by_eval" \
        && "$target" == *"line two"* && "$target" != *"CANDIDATE"* \
        && "$out" == *"$expect_reason"* ]]; then
    log_pass "${label} -> HELD (rc=4, blocked_by_eval, target unchanged, log_error reason present)"
  else
    log_fail "${label} expected HELD, got rc=${rc} status=${status} reason_seen=$([[ "$out" == *"$expect_reason"* ]] && echo yes || echo NO)"
    printf -- '%s\n' "$out"
  fi
}

# ── Test 1: flag-off golden -- output identical between pre-diff (git HEAD) and patched script ──
test_flag_off_golden() {
  local orig_script="${STUB_DIR}/orig-shadow-apply.sh"
  git -C "$SCRIPT_DIR" show HEAD:plugins/leadv2/scripts/leadv2-shadow-apply.sh > "$orig_script" 2>/dev/null
  chmod +x "$orig_script"

  local root_a root_b pid_a pid_b out_a out_b
  root_a="$(mktemp -d)"; root_b="$(mktemp -d)"
  pid_a="$(setup_fixture "$root_a")"
  pid_b="$(setup_fixture "$root_b")"

  out_a="$(run_promote "$orig_script" "$root_a" "$pid_a" | strip_ts)"
  out_b="$(run_promote "$SHADOW_APPLY" "$root_b" "$pid_b" | strip_ts)"
  # normalize the two distinct random proposal ids/dirs out of the log lines
  out_a="${out_a//$pid_a/PID}"; out_a="${out_a//$root_a/ROOT}"
  out_b="${out_b//$pid_b/PID}"; out_b="${out_b//$root_b/ROOT}"

  local status_a status_b target_a target_b
  status_a="$(proposal_status "$root_a" "$pid_a")"
  status_b="$(proposal_status "$root_b" "$pid_b")"
  target_a="$(cat "${root_a}/target.txt")"
  target_b="$(cat "${root_b}/target.txt")"

  if [[ "$out_a" == "$out_b" && "$status_a" == "$status_b" && "$target_a" == "$target_b" ]]; then
    log_pass "flag-off byte-identical golden (status=${status_a})"
  else
    log_fail "flag-off golden MISMATCH (status ${status_a} vs ${status_b})"
    diff <(printf -- '%s' "$out_a") <(printf -- '%s' "$out_b") || true
  fi
  rm -rf "$root_a" "$root_b"
}

# ── Test 2: flag-on + gate PROMOTE -> promotes (the ONLY verdict that promotes) ──────────────────
test_gate_promote_promotes() {
  local root pid rc out status target
  root="$(mktemp -d)"; pid="$(setup_fixture "$root")"
  out="$(run_promote "$SHADOW_APPLY" "$root" "$pid" \
    LEADV2_TASKBENCH_ON=1 LEADV2_TASKBENCH_GATE_SCRIPT="${STUB_DIR}/gate-promote.sh")"
  rc=$?
  status="$(proposal_status "$root" "$pid")"
  target="$(cat "${root}/target.txt")"
  if [[ $rc -eq 0 && "$status" == "promoted" && "$target" == *"line TWO-CANDIDATE"* \
        && "$out" == *"taskbench_gate PROMOTE"* ]]; then
    log_pass "verdict=PROMOTE -> promoted (rc=0, status=promoted, target patched)"
  else
    log_fail "verdict=PROMOTE expected promoted, got rc=${rc} status=${status}"
    printf -- '%s\n' "$out"
  fi
  rm -rf "$root"
}

# ── Test 3: verdict=REJECT -> HELD ────────────────────────────────────────────────────────────
test_gate_reject_holds() {
  local root pid rc out status target
  root="$(mktemp -d)"; pid="$(setup_fixture "$root")"
  out="$(run_promote "$SHADOW_APPLY" "$root" "$pid" \
    LEADV2_TASKBENCH_ON=1 LEADV2_TASKBENCH_GATE_SCRIPT="${STUB_DIR}/gate-reject.sh")"
  rc=$?
  status="$(proposal_status "$root" "$pid")"
  target="$(cat "${root}/target.txt")"
  assert_held "verdict=REJECT" "$rc" "$status" "$target" "$out" "verdict=REJECT (measured regression)"
  rm -rf "$root"
}

# ── Test 4: verdict=INCONCLUSIVE -> HELD (FLIPPED from the round-1 fail-open bug) ────────────────
test_gate_inconclusive_holds() {
  local root pid rc out status target
  root="$(mktemp -d)"; pid="$(setup_fixture "$root")"
  out="$(run_promote "$SHADOW_APPLY" "$root" "$pid" \
    LEADV2_TASKBENCH_ON=1 LEADV2_TASKBENCH_GATE_SCRIPT="${STUB_DIR}/gate-inconclusive.sh")"
  rc=$?
  status="$(proposal_status "$root" "$pid")"
  target="$(cat "${root}/target.txt")"
  assert_held "verdict=INCONCLUSIVE" "$rc" "$status" "$target" "$out" \
    "verdict=INCONCLUSIVE (no benchmark result -- gate dormant until fed)"
  rm -rf "$root"
}

# ── Test 5: gate script absent -> HELD (misconfigured), no wedge (clean rc=4, no hang) ──────────
test_gate_absent_holds() {
  local root pid rc out status target
  root="$(mktemp -d)"; pid="$(setup_fixture "$root")"
  out="$(run_promote "$SHADOW_APPLY" "$root" "$pid" \
    LEADV2_TASKBENCH_ON=1 LEADV2_TASKBENCH_GATE_SCRIPT="${STUB_DIR}/does-not-exist.sh")"
  rc=$?
  status="$(proposal_status "$root" "$pid")"
  target="$(cat "${root}/target.txt")"
  assert_held "gate-absent" "$rc" "$status" "$target" "$out" "gate misconfigured (script not found"
  rm -rf "$root"
}

# ── Test 6: jq missing from PATH -> HELD (misconfigured) ────────────────────────────────────────
test_jq_missing_holds() {
  local root pid rc out status target
  root="$(mktemp -d)"; pid="$(setup_fixture "$root")"
  out="$(run_promote "$SHADOW_APPLY" "$root" "$pid" \
    LEADV2_TASKBENCH_ON=1 LEADV2_TASKBENCH_GATE_SCRIPT="${STUB_DIR}/gate-promote.sh" \
    PATH="$NOJQ_PATH")"
  rc=$?
  status="$(proposal_status "$root" "$pid")"
  target="$(cat "${root}/target.txt")"
  assert_held "jq-missing" "$rc" "$status" "$target" "$out" "gate misconfigured (jq not found on PATH)"
  rm -rf "$root"
}

# ── Test 7: unparsable verdict JSON -> HELD (misconfigured) ─────────────────────────────────────
test_gate_badjson_holds() {
  local root pid rc out status target
  root="$(mktemp -d)"; pid="$(setup_fixture "$root")"
  out="$(run_promote "$SHADOW_APPLY" "$root" "$pid" \
    LEADV2_TASKBENCH_ON=1 LEADV2_TASKBENCH_GATE_SCRIPT="${STUB_DIR}/gate-badjson.sh")"
  rc=$?
  status="$(proposal_status "$root" "$pid")"
  target="$(cat "${root}/target.txt")"
  assert_held "unparsable-verdict" "$rc" "$status" "$target" "$out" "gate misconfigured (empty/unparsable verdict"
  rm -rf "$root"
}

# ── Test 8: gate sourcing error (exit 7 on source) -> set -e-safe, HELD, no abort/crash ──────────
test_gate_sourcing_error_holds() {
  local root pid rc out status target
  root="$(mktemp -d)"; pid="$(setup_fixture "$root")"
  out="$(run_promote "$SHADOW_APPLY" "$root" "$pid" \
    LEADV2_TASKBENCH_ON=1 LEADV2_TASKBENCH_GATE_SCRIPT="${STUB_DIR}/gate-sourcing-error.sh")"
  rc=$?
  status="$(proposal_status "$root" "$pid")"
  target="$(cat "${root}/target.txt")"
  assert_held "sourcing-error" "$rc" "$status" "$target" "$out" "gate misconfigured (sourcing/exec error"
  rm -rf "$root"
}

# ── Test 9: gate ignores SIGTERM and hangs -> timeout -k force-KILLS it, HELD, no wedge ─────────
test_gate_hang_sigterm_ignored_killed() {
  local root pid rc out status target start end elapsed
  root="$(mktemp -d)"; pid="$(setup_fixture "$root")"
  start=$(date +%s)
  out="$(run_promote "$SHADOW_APPLY" "$root" "$pid" \
    LEADV2_TASKBENCH_ON=1 LEADV2_TASKBENCH_GATE_SCRIPT="${STUB_DIR}/gate-hang.sh")"
  rc=$?
  end=$(date +%s)
  elapsed=$((end - start))
  status="$(proposal_status "$root" "$pid")"
  target="$(cat "${root}/target.txt")"
  # must be killed by `timeout -k 5s 30s` (~30-35s), never hang past ~40s (proves no wedge)
  if [[ $elapsed -le 40 ]]; then
    assert_held "SIGTERM-ignoring hang" "$rc" "$status" "$target" "$out" \
      "gate misconfigured (timeout -- taskbench_gate did not return within 30s, force-killed via -k)"
  else
    log_fail "SIGTERM-ignoring hang: took ${elapsed}s (>40s) -- timeout -k did not force-kill, WEDGED"
  fi
  rm -rf "$root"
}

# ── Test 10: gate backgrounds an orphaned grandchild inheriting stdout -> must NOT wedge (fix-round 2) ──
test_gate_orphan_grandchild_no_pipe_wedge() {
  local root pid rc out status target start end elapsed
  root="$(mktemp -d)"; pid="$(setup_fixture "$root")"
  start=$(date +%s)
  out="$(run_promote "$SHADOW_APPLY" "$root" "$pid" \
    LEADV2_TASKBENCH_ON=1 LEADV2_TASKBENCH_GATE_SCRIPT="${STUB_DIR}/gate-orphan-grandchild.sh")"
  rc=$?
  end=$(date +%s)
  elapsed=$((end - start))
  status="$(proposal_status "$root" "$pid")"
  target="$(cat "${root}/target.txt")"
  # bug (pre-fix): $(...) capture blocks ~10s on the orphaned grandchild's fd 1.
  # fixed: temp-file read returns as soon as the gate function itself exits -- well under 5s.
  if [[ $elapsed -le 5 && $rc -eq 0 && "$status" == "promoted" && "$target" == *"line TWO-CANDIDATE"* ]]; then
    log_pass "orphan-grandchild -> returned promptly (${elapsed}s <= 5s, not ~10s), correct decision (promoted)"
  else
    log_fail "orphan-grandchild expected prompt return (<=5s) + promoted, got elapsed=${elapsed}s rc=${rc} status=${status}"
    printf -- '%s\n' "$out"
  fi
  rm -rf "$root"
}

test_flag_off_golden
test_gate_promote_promotes
test_gate_reject_holds
test_gate_inconclusive_holds
test_gate_absent_holds
test_jq_missing_holds
test_gate_badjson_holds
test_gate_sourcing_error_holds
test_gate_hang_sigterm_ignored_killed
test_gate_orphan_grandchild_no_pipe_wedge

printf -- '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
