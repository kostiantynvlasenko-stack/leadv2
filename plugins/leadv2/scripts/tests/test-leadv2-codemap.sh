#!/usr/bin/env bash
# tests/test-leadv2-codemap.sh — Unit tests for CODEMAP-CONTEXT-01 (+ fix-round-1) additions.
#
# Runs the REAL, unmodified workflow source (see fixtures/codemap-plan-harness.mjs for the
# execution methodology, same as causal-critique-harness.mjs) against a real fixture git repo.
# Scenario outputs are written to temp files (never interpolated into python -c strings) to
# avoid shell-quoting corruption of JSON payloads.
#
# Tests:
#   1. node --check syntax on the workflow file; bash -n on mission-lint.sh
#   2. flag-off (codemapEnabled key never set): no "Code map" text/key anywhere,
#      code_map_included ABSENT (fix-round-1 #1: omitted, never false)
#   3. flag-off-explicit (codemapEnabled:false + codeMap set anyway): same no-op as absent,
#      stray codeMap never read
#   4. [fix-round-1 #6] PRE-DIFF GOLDEN: runs the pristine pre-CODEMAP-CONTEXT-01
#      leadv2-plan.js (via `git show HEAD:...`) and asserts the CURRENT code's flag-off-absent
#      run is byte-for-byte identical (result object + architect/synthesize prompts) — this is
#      the test that actually catches a stray code_map_included key (finding #1's exact bug)
#   5. flag-on but MCP returned nothing: fail-open, same no-code-map outcome as flag-off
#   6. flag-on-normal: code_map reaches architect prompt AND context.yaml's code_map field via
#      the REAL deterministic persistCodeMap() code path (not a mocked LLM write); both prompts
#      fence the data as UNTRUSTED (fix-round-1 #4)
#   7. flag-on-oversized: capCodeMap total length (note included) <= 2000 (fix-round-1 #3)
#   8. [fix-round-1 #2] flag-on-retry: validate-ctx fails once, forcing the synthesize-retry
#      path (whose prompt never mentions code_map) — code_map must still survive on disk
#   9. non-code_map result fields identical between flag-off and flag-on runs
#  10-12. [fix-round-1 #5] leadv2-mission-lint.sh real Build-side enforcement: flag off is a
#      no-op (byte-identical old behavior), flag on + code_map present + missing heading BLOCKS
#      (exit 6), flag on + heading present PASSES (exit 0)
#
# Run: bash test-leadv2-codemap.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
WORKFLOW_JS="${PLUGIN_ROOT}/workflows/leadv2-plan.js"
MISSION_LINT="${PLUGIN_ROOT}/scripts/leadv2-mission-lint.sh"
HARNESS="${SCRIPT_DIR}/fixtures/codemap-plan-harness.mjs"

PASS=0; FAIL=0; ERRORS=()
log()  { printf -- '[TEST] %s\n' "$*"; }
pass() { PASS=$((PASS + 1)); log "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); ERRORS+=("$1"); log "FAIL: $1"; }

FIXTURE_DIR="$(mktemp -d)"
OUT_DIR="$(mktemp -d)"
trap 'rm -rf "$FIXTURE_DIR" "$OUT_DIR"' EXIT

mkdir -p "$FIXTURE_DIR/docs/leadv2"
(
  cd "$FIXTURE_DIR"
  git init -q
  git config user.email test@test.local
  git config user.name test
  git commit --allow-empty -q -m "fixture base"
)

run_scenario() {
  local name="$1" workflow="$2" out_file="$OUT_DIR/${1}.json"
  node "$HARNESS" "$FIXTURE_DIR" "$workflow" "${3:-$name}" >"$out_file" 2>"$OUT_DIR/${name}.err" || true
  printf '%s' "$out_file"
}

assert_nonempty() {
  local label="$1" file="$2"
  if [[ ! -s "$file" ]]; then
    fail "$label produced no output (see $OUT_DIR/${label}.err)"
    return 1
  fi
  return 0
}

# ── Test 1: syntax ──────────────────────────────────────────────────────────
if node --check "$WORKFLOW_JS" 2>"$OUT_DIR/synerr.log"; then
  pass "workflow file passes node --check"
else
  fail "node --check failed: $(cat "$OUT_DIR/synerr.log")"
fi
if bash -n "$MISSION_LINT" 2>"$OUT_DIR/mlsyn.log"; then
  pass "leadv2-mission-lint.sh passes bash -n"
else
  fail "leadv2-mission-lint.sh bash -n failed: $(cat "$OUT_DIR/mlsyn.log")"
fi

OFF_ABSENT_F="$(run_scenario flag-off-absent "$WORKFLOW_JS")"
OFF_EXPLICIT_F="$(run_scenario flag-off-explicit "$WORKFLOW_JS")"
MCP_EMPTY_F="$(run_scenario flag-on-mcp-empty "$WORKFLOW_JS")"
ON_NORMAL_F="$(run_scenario flag-on-normal "$WORKFLOW_JS")"
ON_OVERSIZED_F="$(run_scenario flag-on-oversized "$WORKFLOW_JS")"
ON_RETRY_F="$(run_scenario flag-on-retry "$WORKFLOW_JS")"

# ── Test 2: flag-off-absent -> no code_map anywhere, key OMITTED (fix #1) ───
if assert_nonempty "flag-off-absent" "$OFF_ABSENT_F"; then
  if python3 "$SCRIPT_DIR/fixtures/codemap-check-no-map.py" "$OFF_ABSENT_F"; then
    pass "flag-off (absent codemapEnabled): no code_map text/key anywhere, code_map_included OMITTED (fix #1)"
  else
    fail "flag-off (absent) leaked code_map or shipped a stray code_map_included key"
  fi
fi

# ── Test 3: flag-off-explicit behaves identically to flag-off-absent ────────
if assert_nonempty "flag-off-explicit" "$OFF_EXPLICIT_F"; then
  if python3 "$SCRIPT_DIR/fixtures/codemap-check-identical.py" "$OFF_ABSENT_F" "$OFF_EXPLICIT_F" \
    && python3 "$SCRIPT_DIR/fixtures/codemap-check-no-map.py" "$OFF_EXPLICIT_F" \
    && ! grep -q "should never appear" "$OFF_EXPLICIT_F"; then
    pass "codemapEnabled=false + a stray codeMap value produces the SAME result object as the key being absent, stray value never read"
  else
    fail "flag-off-explicit diverged from flag-off-absent"
  fi
fi

# ── Test 4: [fix #6] PRE-DIFF GOLDEN byte-identical proof ───────────────────
GIT_ROOT="$(git -C "$PLUGIN_ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null | xargs dirname 2>/dev/null || true)"
GIT_PREFIX="$(git -C "$PLUGIN_ROOT" rev-parse --show-prefix 2>/dev/null || true)"
GOLDEN_JS="$OUT_DIR/leadv2-plan.pre-codemap.js"
GOLDEN_OK=0
if [[ -n "$GIT_ROOT" ]] && git -C "$GIT_ROOT" show "HEAD:${GIT_PREFIX}workflows/leadv2-plan.js" >"$GOLDEN_JS" 2>"$OUT_DIR/golden-git.err"; then
  GOLDEN_OK=1
fi
if [[ "$GOLDEN_OK" == "1" && -s "$GOLDEN_JS" ]]; then
  GOLDEN_F="$(run_scenario golden-baseline "$GOLDEN_JS")"
  if assert_nonempty "golden-baseline" "$GOLDEN_F"; then
    if python3 "$SCRIPT_DIR/fixtures/codemap-check-golden.py" "$GOLDEN_F" "$OFF_ABSENT_F"; then
      pass "PRE-DIFF GOLDEN (git show HEAD, before any CODEMAP-CONTEXT-01 change): flag-off run is byte-for-byte identical to the pristine baseline (result object + architect/synthesize prompts) — catches finding #1's exact bug class"
    else
      fail "flag-off run diverged from the pre-diff golden (see stderr above)"
    fi
  fi
else
  fail "could not materialize pre-diff golden via 'git show HEAD:...' (see $OUT_DIR/golden-git.err) — golden byte-identical proof SKIPPED, treat as a failure until HEAD has a pre-diff commit"
fi

# ── Test 5: MCP-unavailable fail-open (flag on, no codeMap) ─────────────────
# NOTE: distinct check from Test 2 — codemapEnabled WAS true here, so per fix #1 the
# code_map_included key must be PRESENT with value false (not omitted, that's the "flag never
# on" case). codemap-check-flagon-empty.py asserts exactly that.
if assert_nonempty "flag-on-mcp-empty" "$MCP_EMPTY_F"; then
  if python3 "$SCRIPT_DIR/fixtures/codemap-check-flagon-empty.py" "$MCP_EMPTY_F"; then
    pass "MCP-unavailable fail-open: codemapEnabled=true but no codeMap -> no throw, no code_map text anywhere, code_map_included=false (present, since flag WAS explicitly on)"
  else
    fail "MCP-unavailable case leaked code_map, threw, or got the code_map_included presence/value wrong"
  fi
fi

# ── Test 6: flag-on-normal -> code_map reaches architect prompt AND context.yaml (real path), fenced as untrusted data ─
if assert_nonempty "flag-on-normal" "$ON_NORMAL_F"; then
  if python3 "$SCRIPT_DIR/fixtures/codemap-check-wired.py" "$ON_NORMAL_F"; then
    pass "flag-on: code_map reaches architect prompt + context.yaml (via REAL deterministic persistCodeMap(), not a mocked LLM write); both prompts fence it as UNTRUSTED DATA (fix #4)"
  else
    fail "flag-on-normal did not wire end-to-end / fencing missing"
  fi
fi

# ── Test 7: size cap TOTAL <= 2000 (fix #3) ──────────────────────────────────
if assert_nonempty "flag-on-oversized" "$ON_OVERSIZED_F"; then
  if python3 "$SCRIPT_DIR/fixtures/codemap-check-cap.py" "$ON_OVERSIZED_F"; then
    pass "size-cap enforced: persisted code_map total length (note included) <= 2000 chars (fix #3)"
  else
    fail "size cap breached (note appended on top of a full 2000-char slice)"
  fi
fi

# ── Test 8: [fix #2] retry path — code_map survives synthesize-retry ────────
if assert_nonempty "flag-on-retry" "$ON_RETRY_F"; then
  if python3 "$SCRIPT_DIR/fixtures/codemap-check-retry.py" "$ON_RETRY_F"; then
    pass "retry regression (fix #2): validate-ctx forces synthesize-retry (whose prompt never mentions code_map) — code_map still lands on disk via the re-run deterministic persist"
  else
    fail "code_map LOST on the validation-retry path (the exact fix #2 bug)"
  fi
fi

# ── Test 9: non-code_map result fields unaffected by codemap presence ───────
if [[ -s "$OFF_ABSENT_F" && -s "$ON_NORMAL_F" ]]; then
  if python3 "$SCRIPT_DIR/fixtures/codemap-check-fields.py" "$OFF_ABSENT_F" "$ON_NORMAL_F"; then
    pass "non-code_map result fields identical whether flag is off or on"
  else
    fail "code_map presence leaked into unrelated fields"
  fi
fi

# ── Tests 10-12: [fix #5] leadv2-mission-lint.sh real Build-side enforcement ─
ML_DIR="$OUT_DIR/mission-lint-fixture"
mkdir -p "$ML_DIR/docs/handoff/T1"
cat >"$ML_DIR/docs/handoff/T1/context.yaml" <<'YAML'
id: T1
mission: fixture
code_map: |
  services: a,b
  edges: a->b
YAML
cat >"$ML_DIR/docs/handoff/T1/mission-dev.md" <<'MD'
# Mission for developer — T1
Some content, no graph context heading.
MD

if LEADV2_CODEMAP=0 bash "$MISSION_LINT" "$ML_DIR/docs/handoff/T1/mission-dev.md" >"$OUT_DIR/ml-off.log" 2>&1; then
  pass "mission-lint flag off (LEADV2_CODEMAP unset/0): no-op, exit 0 even though code_map is present and heading is missing — byte-identical to pre-fix behavior"
else
  fail "mission-lint flag off should be a silent no-op but exited nonzero: $(cat "$OUT_DIR/ml-off.log")"
fi

set +e
LEADV2_CODEMAP=1 bash "$MISSION_LINT" "$ML_DIR/docs/handoff/T1/mission-dev.md" >"$OUT_DIR/ml-on-missing.log" 2>&1
ML_MISSING_EXIT=$?
set -e
if [[ "$ML_MISSING_EXIT" == "6" ]] && grep -q "MISSION_MISSING_GRAPH_CONTEXT" "$OUT_DIR/ml-on-missing.log"; then
  pass "mission-lint flag on + code_map present + mission missing '## Graph context' heading -> BLOCKS (exit 6), real enforcement not prose-only"
else
  fail "mission-lint flag on should BLOCK a mission missing the Graph context heading (exit=$ML_MISSING_EXIT): $(cat "$OUT_DIR/ml-on-missing.log")"
fi

printf '\n## Graph context\nservices: a,b\n' >>"$ML_DIR/docs/handoff/T1/mission-dev.md"
if LEADV2_CODEMAP=1 bash "$MISSION_LINT" "$ML_DIR/docs/handoff/T1/mission-dev.md" >"$OUT_DIR/ml-on-ok.log" 2>&1; then
  pass "mission-lint flag on + code_map present + mission HAS '## Graph context' heading -> PASSES (exit 0)"
else
  fail "mission-lint should pass once the Graph context heading is present: $(cat "$OUT_DIR/ml-on-ok.log")"
fi

echo ""
echo "=== leadv2-codemap test summary: $PASS passed, $FAIL failed ==="
if [[ $FAIL -gt 0 ]]; then
  printf '  - %s\n' "${ERRORS[@]}"
  exit 1
fi
exit 0
