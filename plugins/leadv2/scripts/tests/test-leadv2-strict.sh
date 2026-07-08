#!/usr/bin/env bash
# tests/test-leadv2-strict.sh — Unit tests for FAIL-LOUD-FLAGS-01
# (LEADV2_REQUIRE_STRICT / leadv2-strict.sh + its 4 wired call sites).
#
# Every scenario runs against a scratch-dir COPY of the real scripts (never
# the live repo files) so the test suite never mutates shared state.
#
# Coverage, per wired site (semantic-recall.sh, rules-eval.sh,
# collision-check.sh, coverage-gate.sh):
#   (a) strict=0 (default/unset) on the genuine-misconfig branch -> byte
#       -identical no-op: same rc as pre-diff, zero STRICT-FAIL bytes.
#   (b) strict=1 on the genuine-misconfig branch -> STRICT-FAIL fires,
#       non-zero/expected rc.
#   (c) strict=1 on the LEGITIMATE branch (flag off / loader ran fine with
#       zero rows) -> must NOT fire, rc/output unchanged from strict=0.
#   (d) leadv2-strict.sh ABSENT (the bug this suite exists to catch, C1) ->
#       strict_or_warn is undefined; every site MUST degrade to the exact
#       pre-diff rc, in BOTH strict=0 and strict=1 (the guard is
#       `command -v strict_or_warn`, not the flag).
#
# Run: bash scripts/tests/test-leadv2-strict.sh
# Exit 0 = all pass; non-zero = failures found.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

PASS=0
FAIL=0
ERRORS=()

log()  { printf -- '[TEST] %s\n' "$*"; }
pass() { PASS=$(( PASS + 1 )); log "PASS: $1"; }
fail() { FAIL=$(( FAIL + 1 )); ERRORS+=("FAIL: $1"); log "FAIL: $1"; }

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

if bash -n "${SCRIPTS_DIR}/leadv2-strict.sh" 2>/dev/null; then
  pass "bash -n syntax check: leadv2-strict.sh"
else
  fail "bash -n syntax check: leadv2-strict.sh"
fi

_run() {
  local expect_rc="$1" expect_sf="$2" label="$3"; shift 3
  [[ "$1" == "--" ]] && shift
  local out rc
  set +e
  out=$("$@" 2>&1)
  rc=$?
  set -e
  local has_sf=0
  [[ "$out" == *"STRICT-FAIL"* ]] && has_sf=1
  if [[ "$rc" -eq "$expect_rc" && "$has_sf" -eq "$expect_sf" ]]; then
    pass "$label (rc=$rc, strict-fail=$has_sf)"
  else
    fail "$label (got rc=$rc strict-fail=$has_sf, want rc=$expect_rc strict-fail=$expect_sf) :: $out"
  fi
}

T1="$SCRATCH/site1"; mkdir -p "$T1"
cp "${SCRIPTS_DIR}/leadv2-semantic-recall.sh" "${SCRIPTS_DIR}/leadv2-strict.sh" "$T1/"

_run 0 0 "site1(recall) (a) strict=0 misconfig -> silent fail-open" -- \
  env LEADV2_SEMANTIC_RECALL_ENABLED=1 LEADV2_RECALL_HELPER=/no/such/f \
  bash "$T1/leadv2-semantic-recall.sh" immune q 5 pe

_run 1 1 "site1(recall) (b) strict=1 misconfig -> STRICT-FAIL" -- \
  env LEADV2_REQUIRE_STRICT=1 LEADV2_SEMANTIC_RECALL_ENABLED=1 LEADV2_RECALL_HELPER=/no/such/f \
  bash "$T1/leadv2-semantic-recall.sh" immune q 5 pe

_run 0 0 "site1(recall) (c) strict=1 legitimate flag=0 -> no false-fire" -- \
  env LEADV2_REQUIRE_STRICT=1 bash "$T1/leadv2-semantic-recall.sh" immune q 5 pe

rm -f "$T1/leadv2-strict.sh"
_run 0 0 "site1(recall) (d) helper-ABSENT + strict=0 -> unchanged rc=0" -- \
  env LEADV2_SEMANTIC_RECALL_ENABLED=1 LEADV2_RECALL_HELPER=/no/such/f \
  bash "$T1/leadv2-semantic-recall.sh" immune q 5 pe
_run 0 0 "site1(recall) (d) helper-ABSENT + strict=1 -> unchanged rc=0 (NOT unconditional exit)" -- \
  env LEADV2_REQUIRE_STRICT=1 LEADV2_SEMANTIC_RECALL_ENABLED=1 LEADV2_RECALL_HELPER=/no/such/f \
  bash "$T1/leadv2-semantic-recall.sh" immune q 5 pe

T2="$SCRATCH/site2"; mkdir -p "$T2/root/.claude/leadv2-overrides/rules"
cp "${SCRIPTS_DIR}/leadv2-rules-eval.sh" "${SCRIPTS_DIR}/leadv2-strict.sh" "${SCRIPTS_DIR}/leadv2-helpers.sh" "$T2/"
cat > "$T2/root/.claude/leadv2-overrides/quality-engine.yaml" <<'YAML'
enabled: true
l_a:
  enabled: true
  rules_dir: .claude/leadv2-overrides/rules
YAML

printf '#!/usr/bin/env bash\nexit 7\n' > "$T2/leadv2-rules-load.sh"
chmod +x "$T2"/*.sh

_run 0 0 "site2(rules-eval) (a) strict=0 loader-crash -> silent empty-ruleset fallback" -- \
  env LEADV2_PROJECT_ROOT="$T2/root" bash "$T2/leadv2-rules-eval.sh" T-TEST
_run 3 1 "site2(rules-eval) (b) strict=1 loader-crash -> STRICT-FAIL, rc=3" -- \
  env LEADV2_REQUIRE_STRICT=1 LEADV2_PROJECT_ROOT="$T2/root" bash "$T2/leadv2-rules-eval.sh" T-TEST

printf '#!/usr/bin/env bash\necho "{\\"rules\\":[],\\"count\\":0,\\"warnings\\":[]}"\n' > "$T2/leadv2-rules-load.sh"
chmod +x "$T2/leadv2-rules-load.sh"
_run 0 0 "site2(rules-eval) (c) strict=1 legitimate zero-rules -> no false-fire" -- \
  env LEADV2_REQUIRE_STRICT=1 LEADV2_PROJECT_ROOT="$T2/root" bash "$T2/leadv2-rules-eval.sh" T-TEST

printf '#!/usr/bin/env bash\nexit 7\n' > "$T2/leadv2-rules-load.sh"
chmod +x "$T2/leadv2-rules-load.sh"
rm -f "$T2/leadv2-strict.sh"
_run 0 0 "site2(rules-eval) (d) helper-ABSENT + strict=0 -> unchanged rc=0" -- \
  env LEADV2_PROJECT_ROOT="$T2/root" bash "$T2/leadv2-rules-eval.sh" T-TEST
_run 0 0 "site2(rules-eval) (d) helper-ABSENT + strict=1 -> unchanged rc=0 (NOT unconditional exit 3)" -- \
  env LEADV2_REQUIRE_STRICT=1 LEADV2_PROJECT_ROOT="$T2/root" bash "$T2/leadv2-rules-eval.sh" T-TEST

T3="$SCRATCH/site3"; mkdir -p "$T3/docs/leadv2"
cp "${SCRIPTS_DIR}/leadv2-collision-check.sh" "${SCRIPTS_DIR}/leadv2-strict.sh" "$T3/"
echo 'this is not valid bash {{{' > "$T3/leadv2-helpers.sh"
( cd "$T3" && git init -q 2>/dev/null || true )

# NOTE: collision-check.sh's default mode runs `git status --porcelain` /
# `git stash list` against CWD (not LEADV2_PROJECT_ROOT) -- must `cd "$T3"`
# into the scratch git repo, else it inspects the REAL calling repo's state.
_run 0 0 "site3(collision) (a) strict=0 source-fail -> silent PE-default fallback" -- \
  bash -c "cd '$T3' && LEADV2_PROJECT_ROOT='$T3' bash leadv2-collision-check.sh"
_run 1 1 "site3(collision) (b) strict=1 source-fail -> STRICT-FAIL, rc=1 (not 2=collision)" -- \
  bash -c "cd '$T3' && LEADV2_REQUIRE_STRICT=1 LEADV2_PROJECT_ROOT='$T3' bash leadv2-collision-check.sh"

cp "${SCRIPTS_DIR}/leadv2-helpers.sh" "$T3/leadv2-helpers.sh"
set +e
out3c=$(bash -c "cd '$T3' && LEADV2_REQUIRE_STRICT=1 LEADV2_PROJECT_ROOT='$T3' bash leadv2-collision-check.sh" 2>&1)
rc3c=$?
set -e
if [[ "$out3c" != *"STRICT-FAIL"* && "$rc3c" -ne 1 ]]; then
  pass "site3(collision) (c) strict=1 legitimate helpers.sh -> no false-fire (rc=$rc3c)"
else
  fail "site3(collision) (c) strict=1 legitimate helpers.sh -> unexpected (rc=$rc3c) :: $out3c"
fi

echo 'this is not valid bash {{{' > "$T3/leadv2-helpers.sh"
rm -f "$T3/leadv2-strict.sh"
_run 0 0 "site3(collision) (d) helper-ABSENT + strict=0 -> unchanged rc=0" -- \
  bash -c "cd '$T3' && LEADV2_PROJECT_ROOT='$T3' bash leadv2-collision-check.sh"
_run 0 0 "site3(collision) (d) helper-ABSENT + strict=1 -> unchanged rc=0 (NOT unconditional exit 1)" -- \
  bash -c "cd '$T3' && LEADV2_REQUIRE_STRICT=1 LEADV2_PROJECT_ROOT='$T3' bash leadv2-collision-check.sh"

T4="$SCRATCH/site4/scripts"; mkdir -p "$T4"
cp "${SCRIPTS_DIR}/leadv2-coverage-gate.sh" "${SCRIPTS_DIR}/leadv2-strict.sh" "$T4/"
echo 'this is not valid bash {{{' > "$T4/leadv2-helpers.sh"
( cd "$(dirname "$T4")" && git init -q 2>/dev/null || true )

set +e
out4a=$(bash "$T4/leadv2-coverage-gate.sh" --start-sha HEAD --task-id T-TEST 2>&1)
rc4a=$?
out4b=$(LEADV2_REQUIRE_STRICT=1 bash "$T4/leadv2-coverage-gate.sh" --start-sha HEAD --task-id T-TEST 2>&1)
rc4b=$?
set -e
if [[ "$out4a" != *"STRICT-FAIL"* ]]; then
  pass "site4(coverage-gate) (a) strict=0 source-fail -> no STRICT-FAIL bytes"
else
  fail "site4(coverage-gate) (a) strict=0 source-fail -> unexpected STRICT-FAIL :: $out4a"
fi
if [[ "$out4b" == *"STRICT-FAIL[coverage-gate-helpers-source-fail]"* && "$rc4b" -eq 2 ]]; then
  pass "site4(coverage-gate) (b) strict=1 source-fail -> STRICT-FAIL, rc=2"
else
  fail "site4(coverage-gate) (b) strict=1 source-fail -> unexpected (rc=$rc4b) :: $out4b"
fi

rm -f "$T4/leadv2-strict.sh"
set +e
out4d0=$(bash "$T4/leadv2-coverage-gate.sh" --start-sha HEAD --task-id T-TEST 2>&1); rc4d0=$?
out4d1=$(LEADV2_REQUIRE_STRICT=1 bash "$T4/leadv2-coverage-gate.sh" --start-sha HEAD --task-id T-TEST 2>&1); rc4d1=$?
set -e
if [[ "$rc4d0" -eq "$rc4d1" && "$out4d1" != *"STRICT-FAIL"* ]]; then
  pass "site4(coverage-gate) (d) helper-ABSENT -> strict=0/1 identical rc=$rc4d0, no STRICT-FAIL"
else
  fail "site4(coverage-gate) (d) helper-ABSENT -> rc mismatch (rc0=$rc4d0 rc1=$rc4d1) :: $out4d1"
fi

log "----"
log "PASS=$PASS FAIL=$FAIL"
if [[ "$FAIL" -gt 0 ]]; then
  for e in "${ERRORS[@]}"; do log "$e"; done
  exit 1
fi
exit 0
