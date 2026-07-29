#!/usr/bin/env bash
# tests/test-leadv2-lane-shape.sh — LANE-SHAPE-01 regression test.
#
# Proves, against the SHIPPED leadv2-lane-shape.sh and leadv2-phase8-assert.sh
# (real subprocesses, real exit codes — never a hand-reimplemented copy of the
# decision logic, same discipline as test-leadv2-phase8-assert-a2-schema.sh):
#
#   1. classify refuses a diagnostic mission (names a defect / fix verb) with
#      no ## Evidence block, under LEADV2_LANE_SHAPE=enforce.
#   2. classify accepts a docs-only mission as shape=solo when C1-C5 hold.
#   3. classify routes a migrations-touching mission out of the shape system
#      entirely (not-eligible, rc=3) rather than letting it dispatch as solo.
#   4. shape is immutable-after-write: a second classify on the same task_id
#      is refused (rc=4).
#   5. LEADV2_LANE_SHAPE=off is a true no-op (Stage 0 — no behavior change).
#   6. retro-check: a SOLO-labeled task whose ACTUAL diff touches a C3-excluded
#      surface (supabase/migrations/) cannot pass close, under enforce.
#   7. assert-artifacts + the full leadv2-phase8-assert.sh gate: a SOLO lane
#      with no non-empty "## Acceptance" content in its *.full.md is refused
#      close (worked SOLO example: fails, then passes once the section has
#      real pasted output).
#   8. assert-artifacts + the full gate: a LINE lane with no verify-probe
#      result / review verdict / harness entry is refused close (worked LINE
#      example: fails, then passes once evidence -> probe_ok -> harness_na
#      chain is complete).
#   9. LEADV2_LANE_SHAPE=warn never blocks (one-step-rollback proof).
#
# Run: bash plugins/leadv2/scripts/tests/test-leadv2-lane-shape.sh
# Exit 0 = all pass; non-zero = failures found.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
LANE_SH="${SCRIPTS_DIR}/leadv2-lane-shape.sh"
ASSERT_SH="${SCRIPTS_DIR}/leadv2-phase8-assert.sh"
source "${SCRIPTS_DIR}/leadv2-temp.sh"

PASS=0; FAIL=0; ERRORS=()
pass() { PASS=$((PASS + 1)); printf '[TEST] PASS: %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); ERRORS+=("$1"); printf '[TEST] FAIL: %s\n' "$1"; }

RUN_ID="lane-shape-$$-$(date +%s 2>/dev/null || echo 0)"
TMPDIR_ROOT="$(lv2_mktemp_dir "${RUN_ID}")"
trap 'rm -rf "$TMPDIR_ROOT"' EXIT

# Builds a project root that passes A1/A3/A4/A5/A6/A7/A8 (mirrors
# test-leadv2-phase8-assert-a2-schema.sh's _e2e_new_project) so the observed
# leadv2-phase8-assert.sh exit code is driven by A2 (terminal status, always
# satisfied here) and A9 (lane-shape) alone.
_new_project() {
  local task_id="$1"
  local root="${TMPDIR_ROOT}/${task_id}.$$.${RANDOM}"
  mkdir -p "${root}/docs/leadv2/closed" "${root}/docs/handoff/${task_id}"
  printf -- 'task_id: %s\nclosed_at: 2026-01-01T00:00:00Z\n' "$task_id" \
    > "${root}/docs/leadv2/closed/${task_id}.yaml"
  printf -- 'entries:\n  - task: %s\n' "$task_id" \
    > "${root}/docs/leadv2/reflect-history.yaml"
  touch "${root}/docs/handoff/${task_id}/e2e-gate-passed.flag"
  printf -- 'total_open: 1\ntasks:\n  - id: %s\n    status: verified_closed\n' "$task_id" \
    > "${root}/docs/tasks.yaml"
  printf -- '%s\n' "$root"
}

_classify() {
  local root="$1"; shift
  ( CLAUDE_PROJECT_ROOT="$root" LEADV2_PROJECT_ROOT="$root" LEADV2_STATE_ROOT="${root}/.state" \
    "${LANE_SH}" classify "$@" )
}

_assert_full_gate() {
  local root="$1" task_id="$2"
  ( CLAUDE_PROJECT_ROOT="$root" LEADV2_PROJECT_ROOT="$root" LEADV2_STATE_ROOT="${root}/.state" \
    LEADV2_LANE_SHAPE="${LEADV2_LANE_SHAPE_TEST:-enforce}" \
    bash "${ASSERT_SH}" "$task_id" >/dev/null 2>"${root}/.assert.err" )
}

# ── 1. diagnostic mission, no Evidence -> refused under enforce ─────────────
t1_id="diag-no-evidence"
t1_root="$(_new_project "$t1_id")"
if err="$(LEADV2_LANE_SHAPE=enforce _classify "$t1_root" --task-id "$t1_id" \
    --mission "Comment closers repeat across posts; fix the FORM rotation." 2>&1)"; then
  fail "1 diagnostic-no-evidence: expected non-zero exit, got 0. output: $err"
else
  rc=$?
  if [[ "$err" == *Evidence* ]]; then
    pass "1 diagnostic mission with no Evidence block refused (rc=${rc}, names Evidence)"
  else
    fail "1 diagnostic-no-evidence: refused but did not name the missing Evidence block: $err"
  fi
fi
[[ -f "${t1_root}/docs/handoff/${t1_id}/context.yaml" ]] && fail "1: context.yaml should not exist after a refused classify" || pass "1: no context.yaml written on refusal"

# ── 2. docs-only mission -> shape=solo ───────────────────────────────────────
t2_id="docs-only-solo"
t2_root="$(_new_project "$t2_id")"
if out="$(LEADV2_LANE_SHAPE=enforce _classify "$t2_root" --task-id "$t2_id" \
    --mission "Add a new flag row to docs/reference/ENGINE-REFERENCE.md documenting PE_EXAMPLE." \
    --writes "docs/reference/ENGINE-REFERENCE.md" \
    --acceptance-cmd "grep -q PE_EXAMPLE docs/reference/ENGINE-REFERENCE.md" \
    --rollback-onestep 2>&1)"; then
  shape="$(python3 -c "import yaml; print((yaml.safe_load(open('${t2_root}/docs/handoff/${t2_id}/context.yaml'))or{}).get('shape',''))" 2>/dev/null)"
  [[ "$shape" == "solo" ]] && pass "2 docs-only mission classified shape=solo" || fail "2 docs-only mission: expected shape=solo, got '${shape}' (out: $out)"
else
  fail "2 docs-only mission unexpectedly refused: $out"
fi

# ── 3. migrations-touching mission -> not shape-eligible (rc=3) ─────────────
t3_id="migration-not-eligible"
t3_root="$(_new_project "$t3_id")"
export LEADV2_LANE_SHAPE=enforce
_classify "$t3_root" --task-id "$t3_id" \
  --mission "Add a backfill column to the personas table." \
  --writes "supabase/migrations/0099_add_col.sql" \
  --acceptance-cmd "true" --rollback-onestep >/dev/null 2>"${t3_root}/.err"
rc=$?
if [[ $rc -eq 3 ]]; then
  pass "3 migrations-touching mission is not shape-eligible (rc=3)"
else
  fail "3 migrations-touching mission: expected rc=3, got rc=${rc} ($(cat "${t3_root}/.err"))"
fi

# ── 4. immutable-after-write: second classify on same task_id refused ───────
_classify "$t2_root" --task-id "$t2_id" --mission "second call, different text entirely" \
  --writes "docs/x.md" --acceptance-cmd "true" --rollback-onestep >/dev/null 2>"${t2_root}/.err2"
rc=$?
[[ $rc -eq 4 ]] && pass "4 shape is immutable — second classify refused (rc=4)" || fail "4 immutability: expected rc=4, got rc=${rc}"

# ── 5. LEADV2_LANE_SHAPE=off is a true no-op ─────────────────────────────────
t5_id="off-mode-noop"
t5_root="$(_new_project "$t5_id")"
LEADV2_LANE_SHAPE=off _classify "$t5_root" --task-id "$t5_id" \
  --mission "This is broken and needs a fix, no evidence attached." >/dev/null 2>&1
rc=$?
if [[ $rc -eq 0 && ! -f "${t5_root}/docs/handoff/${t5_id}/context.yaml" ]]; then
  pass "5 LEADV2_LANE_SHAPE=off is a no-op (exit 0, no context.yaml written)"
else
  fail "5 off-mode: expected rc=0 and no context.yaml, got rc=${rc}, exists=$( [[ -f "${t5_root}/docs/handoff/${t5_id}/context.yaml" ]] && echo yes || echo no)"
fi

# ── 6. retro-check: SOLO-labeled task whose diff touches an excluded surface ─
t6_id="solo-retro-violation"
t6_root="$(_new_project "$t6_id")"
mkdir -p "${t6_root}/docs/handoff/${t6_id}"
cat > "${t6_root}/docs/handoff/${t6_id}/context.yaml" <<'EOF'
shape: solo
shape_rationale:
  c1_constructive: true
  c2_machine_checkable_acceptance: true
  c3_blast_radius_le_1: true
  c4_one_step_rollback: true
  c5_no_negative_prior: true
acceptance_cmd: "true"
EOF
( CLAUDE_PROJECT_ROOT="$t6_root" LEADV2_PROJECT_ROOT="$t6_root" LEADV2_LANE_SHAPE=enforce \
  "${LANE_SH}" retro-check --task-id "$t6_id" --diff-files "supabase/migrations/0100_x.sql,agent/foo.py" \
  >/dev/null 2>"${t6_root}/.retro.err" )
rc=$?
if [[ $rc -eq 1 ]]; then
  pass "6 retro-check: solo lane whose diff touches supabase/migrations/ cannot pass (rc=1) -- SOLO C1-C5 violation caught at close"
else
  fail "6 retro-check: expected rc=1, got rc=${rc} ($(cat "${t6_root}/.retro.err"))"
fi

# ── 7. WORKED SOLO EXAMPLE via the full leadv2-phase8-assert.sh gate ────────
t7_id="solo-worked-example"
t7_root="$(_new_project "$t7_id")"
mkdir -p "${t7_root}/docs/handoff/${t7_id}"
cat > "${t7_root}/docs/handoff/${t7_id}/context.yaml" <<'EOF'
shape: solo
shape_rationale:
  c1_constructive: true
  c2_machine_checkable_acceptance: true
  c3_blast_radius_le_1: true
  c4_one_step_rollback: true
  c5_no_negative_prior: true
acceptance_cmd: "true"
EOF
# 7a: no *.full.md with real Acceptance content yet -> close refused.
_assert_full_gate "$t7_root" "$t7_id"
rc=$?
if [[ $rc -eq 1 ]] && grep -q "A9" "${t7_root}/.assert.err"; then
  pass "7a SOLO worked example: close refused with no ## Acceptance content (A9 named)"
else
  fail "7a SOLO worked example: expected rc=1 naming A9, got rc=${rc} ($(cat "${t7_root}/.assert.err"))"
fi
# 7b: add real pasted acceptance output -> close proceeds (A9 no longer blocks).
cat > "${t7_root}/docs/handoff/${t7_id}/developer.full.md" <<'EOF'
# developer

## Acceptance

$ true; echo done
done
EOF
_assert_full_gate "$t7_root" "$t7_id"
rc=$?
if [[ $rc -eq 0 ]]; then
  pass "7b SOLO worked example: close passes once ## Acceptance carries real pasted output"
else
  fail "7b SOLO worked example: expected rc=0 after adding Acceptance content, got rc=${rc} ($(cat "${t7_root}/.assert.err"))"
fi

# ── 8. WORKED LINE EXAMPLE via the full leadv2-phase8-assert.sh gate ────────
t8_id="line-worked-example"
t8_root="$(_new_project "$t8_id")"
mkdir -p "${t8_root}/docs/handoff/${t8_id}"
cat > "${t8_root}/docs/handoff/${t8_id}/context.yaml" <<'EOF'
shape: line
shape_rationale:
  c1_constructive: false
  c2_machine_checkable_acceptance: false
  c3_blast_radius_le_1: true
  c4_one_step_rollback: true
  c5_no_negative_prior: true
evidence:
  type: command
  repro_cmd: "printf FIXED"
  observed: "BROKEN: closer repeats"
  predicted_delta: "FIXED"
verification:
  probe:
    repro_cmd: "printf FIXED"
    expected_delta: "FIXED"
EOF
# 8a: no review verdict / probe result yet -> close refused.
_assert_full_gate "$t8_root" "$t8_id"
rc=$?
if [[ $rc -eq 1 ]] && grep -q "A9" "${t8_root}/.assert.err"; then
  pass "8a LINE worked example: close refused with no review/probe/harness artifacts (A9 named)"
else
  fail "8a LINE worked example: expected rc=1 naming A9, got rc=${rc} ($(cat "${t8_root}/.assert.err"))"
fi
# 8b: run the real probe (proves a false 'fixed' claim would come back probe_neg;
#     here repro_cmd genuinely matches predicted_delta so it lands probe_ok),
#     add a review verdict and a harness_na reason -> close proceeds.
( CLAUDE_PROJECT_ROOT="$t8_root" LEADV2_PROJECT_ROOT="$t8_root" "${LANE_SH}" verify-probe --task-id "$t8_id" >/dev/null 2>&1 )
python3 -c "
import yaml
p = '${t8_root}/docs/handoff/${t8_id}/verify-probe-result.yaml'
d = yaml.safe_load(open(p)) or {}
d['harness_na'] = 'unit-level probe, no live-cycle harness for this synthetic test fixture'
yaml.safe_dump(d, open(p, 'w'), sort_keys=False)
"
printf -- 'verdict: PASS\nreviewer: codex\n' > "${t8_root}/docs/handoff/${t8_id}/review-verdict.yaml"
_assert_full_gate "$t8_root" "$t8_id"
rc=$?
if [[ $rc -eq 0 ]]; then
  pass "8b LINE worked example: close passes once review verdict + probe_ok + harness_na are all present"
else
  fail "8b LINE worked example: expected rc=0, got rc=${rc} ($(cat "${t8_root}/.assert.err"))"
fi

# ── 8c. verify-probe catches a FALSE 'fixed' claim (F4 from the spec) ───────
t8c_id="line-false-fixed-claim"
t8c_root="$(_new_project "$t8c_id")"
mkdir -p "${t8c_root}/docs/handoff/${t8c_id}"
cat > "${t8c_root}/docs/handoff/${t8c_id}/context.yaml" <<'EOF'
shape: line
verification:
  probe:
    repro_cmd: "printf STILL_BROKEN"
    expected_delta: "FIXED"
EOF
( CLAUDE_PROJECT_ROOT="$t8c_root" LEADV2_PROJECT_ROOT="$t8c_root" "${LANE_SH}" verify-probe --task-id "$t8c_id" >/dev/null 2>&1 )
outcome="$(python3 -c "import yaml; print((yaml.safe_load(open('${t8c_root}/docs/handoff/${t8c_id}/verify-probe-result.yaml'))or{}).get('outcome',''))" 2>/dev/null)"
[[ "$outcome" == "probe_neg" ]] && pass "8c verify-probe: no-op diff with a false 'fixed' claim yields probe_neg automatically" || fail "8c verify-probe: expected probe_neg, got '${outcome}'"

# ── 9. LEADV2_LANE_SHAPE=warn never blocks (one-flag rollback) ──────────────
t9_id="warn-never-blocks"
t9_root="$(_new_project "$t9_id")"
mkdir -p "${t9_root}/docs/handoff/${t9_id}"
cat > "${t9_root}/docs/handoff/${t9_id}/context.yaml" <<'EOF'
shape: solo
EOF
LEADV2_LANE_SHAPE_TEST=warn _assert_full_gate "$t9_root" "$t9_id"
rc=$?
[[ $rc -eq 0 ]] && pass "9 LEADV2_LANE_SHAPE=warn never blocks close even with missing artifacts" || fail "9 warn mode: expected rc=0, got rc=${rc} ($(cat "${t9_root}/.assert.err"))"

# ── summary ───────────────────────────────────────────────────────────────────
printf -- '\n[TEST] %d passed, %d failed\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
  printf -- '[TEST] failures:\n'
  for e in "${ERRORS[@]}"; do printf -- '  - %s\n' "$e"; done
  exit 1
fi
exit 0
