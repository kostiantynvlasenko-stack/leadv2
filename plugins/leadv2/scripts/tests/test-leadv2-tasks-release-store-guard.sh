#!/usr/bin/env bash
# tests/test-leadv2-tasks-release-store-guard.sh — CLOSE-GATE-A2-STORE-YAML-
# IMPEDANCE-01 round-2 finding 2 regression test.
#
# Covers the ~65-line store-write + regen-guard branch inside
# leadv2-tasks-lib.sh::leadv2_tasks_release() (lines ~447-510) added by
# fix-round-1 and left with zero automated coverage per critic-round-2.md
# finding 2: "only a manual live-proof narrative exists". This test proves,
# via a real sourced call into the shipped function (not a reimplementation):
#
#   1. store_rc==0 (store write succeeded, >=1 row matched)     -> regen gate
#      IS invoked exactly once, with the item_id.
#   2. store_rc==4 (outcome != success, work-item-release.sh's no-op)
#      -> regen gate is NOT invoked, and the status the local dispatch just
#         wrote in docs/tasks.yaml survives untouched.
#   3. store_rc==5 (outcome==success but 0 rows matched, ad-hoc task)
#      -> regen gate is NOT invoked, and the just-written status survives.
#   4. store_rc==1 (hard store failure) -> regen gate is NOT invoked, the
#      just-written status survives, a loud ERROR is logged on stderr, and
#      (round-2 finding 3) leadv2_tasks_release itself still returns 0 --
#      dispatch succeeded, so callers running this bare under
#      `set -euo pipefail` (e.g. leadv2-queue-release.sh) must not abort.
#
# The stub regen-gate script used here does not merely record its call -- if
# invoked it OVERWRITES the item's status back to "in_progress", simulating
# what a real wholesale docs/tasks.yaml regen-from-store would do. This makes
# scenarios 2/3/4 non-tautological: if the guard's case/esac ever regressed
# to calling regen on a non-zero store_rc, the "status survives" assertion
# would catch it even though the "regen not invoked" assertion might be
# fooled by a different code path.
#
# Non-tautology proof (see docs/handoff/500a9bcbcab3/fix-round-2.md for the
# transcript): the case guard at leadv2-tasks-lib.sh was temporarily mutated
# to also regen on store_rc==4, this suite was re-run and scenario 2 FAILED
# as expected, then the mutation was reverted and the suite passed again.
#
# Run: bash scripts/tests/test-leadv2-tasks-release-store-guard.sh
# Exit 0 = all pass; non-zero = failures found.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/leadv2-temp.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TASKS_LIB="${SCRIPTS_DIR}/leadv2-tasks-lib.sh"

PASS=0; FAIL=0; ERRORS=()
log()  { printf -- '[TEST] %s\n' "$*"; }
pass() { PASS=$((PASS + 1)); log "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); ERRORS+=("FAIL: $1"); log "FAIL: $1"; }

RUN_ID="release-guard-$$-$(date +%s)"
TMPDIR_ROOT="$(lv2_mktemp_dir "${RUN_ID}")"
trap 'rm -rf "$TMPDIR_ROOT"' EXIT

# ── Per-scenario fixture: fresh PROJECT_ROOT, tasks.yaml, stub regen gate ──
# args: item_id
_new_scenario() {
  local item_id="$1" root="${TMPDIR_ROOT}/${1}.$$.${RANDOM}"
  mkdir -p "${root}/docs" "${root}/scripts"
  printf -- '- id: %s\n  lane: action\n  status: in_progress\n  attempts: 0\n' "$item_id" \
    > "${root}/docs/tasks.yaml"

  # Stub regen gate: records every invocation to REGEN_LOG (exported by the
  # caller before sourcing/invoking) and, if invoked, reverts the item's
  # status back to in_progress -- the "did a regen silently wipe the status
  # the dispatch just wrote" probe.
  cat > "${root}/scripts/leadv2-tasks-regen-gate.sh" <<'STUB'
#!/usr/bin/env bash
echo "$1" >> "${REGEN_LOG:?REGEN_LOG not set}"
python3 - "$1" "${PROJECT_ROOT}/docs/tasks.yaml" <<'PY'
import sys, yaml
item_id, path = sys.argv[1], sys.argv[2]
with open(path) as f:
    items = yaml.safe_load(f) or []
for it in items:
    if str(it.get("id", "")) == item_id:
        it["status"] = "in_progress"
with open(path, "w") as f:
    yaml.dump(items, f, default_flow_style=False, sort_keys=False)
PY
exit "${REGEN_EXIT_RC:-0}"
STUB
  chmod +x "${root}/scripts/leadv2-tasks-regen-gate.sh"
  printf -- '%s\n' "$root"
}

# args: root -> prints status field of the sole item
_read_status() {
  python3 -c '
import sys, yaml
with open(sys.argv[1] + "/docs/tasks.yaml") as f:
    items = yaml.safe_load(f) or []
print(items[0].get("status", "") if items else "")
' "$1"
}

# ── Runs leadv2_tasks_release in a fresh subshell against $1=root with a
# stubbed LEADV2_TASKS_RELEASE_CMD returning $2, item id $3. Sets
# SCEN_RC, SCEN_ERR, REGEN_CALLS (count of lines in REGEN_LOG).
_run_scenario() {
  local root="$1" release_cmd_rc="$2" item_id="$3"
  local release_cmd="${root}/fake-release-cmd.sh"
  cat > "$release_cmd" <<STUBCMD
#!/usr/bin/env bash
exit ${release_cmd_rc}
STUBCMD
  chmod +x "$release_cmd"

  local regen_log="${root}/regen.log"
  : > "$regen_log"

  set +e
  SCEN_ERR="$(
    PROJECT_ROOT="$root" LEADV2_TASKS_RELEASE_CMD="$release_cmd" REGEN_LOG="$regen_log" \
      bash -c '
        set -euo pipefail
        source "'"$TASKS_LIB"'"
        leadv2_tasks_release "'"$item_id"'" --outcome success
        echo "RC_MARKER:$?"
        echo "STORE_RC_MARKER:${LEADV2_TASKS_RELEASE_LAST_STORE_RC:-<unset>}"
      ' 2>&1
  )"
  SCEN_RAW_RC=$?
  set -e
  # Anchored (^...$): RC_MARKER is a substring of STORE_RC_MARKER, so an
  # unanchored grep -o would let STORE_RC_MARKER's line clobber SCEN_RC.
  SCEN_RC="$(grep -oE '^RC_MARKER:[0-9]+$' <<<"$SCEN_ERR" | tail -1 | cut -d: -f2)"
  SCEN_STORE_RC="$(grep -oE '^STORE_RC_MARKER:.*$' <<<"$SCEN_ERR" | tail -1 | cut -d: -f2)"
  # If bash -c itself aborted (set -e killed it before RC_MARKER printed),
  # SCEN_RC is empty -- that IS the "killed the caller" failure mode finding
  # 3 exists to prevent; surface it as a huge sentinel rc so assertions fail
  # loudly instead of comparing against an empty string.
  SCEN_RC="${SCEN_RC:-${SCEN_RAW_RC}}"
  REGEN_CALLS="$(wc -l < "$regen_log" | tr -d ' ')"
}

# ── Scenario 1: store_rc==0 -> regen invoked exactly once ──────────────────
test_1_store_success_regens() {
  log "Test 1: store_rc=0 -> regen gate invoked exactly once"
  local root item_id="T-STORE-OK"
  root="$(_new_scenario "$item_id")"
  _run_scenario "$root" 0 "$item_id"
  if [[ "$REGEN_CALLS" -eq 1 ]] && [[ "$SCEN_RC" == "0" ]]; then
    pass "Test 1: store_rc=0 -> regen called once, leadv2_tasks_release returned 0"
  else
    fail "Test 1: expected regen_calls=1 rc=0, got regen_calls=${REGEN_CALLS} rc=${SCEN_RC}: ${SCEN_ERR}"
  fi
}

# ── Scenario 2: store_rc==4 (non-success outcome no-op) -> no regen, status survives ──
test_2_store_nonsuccess_noregen_status_survives() {
  log "Test 2: store_rc=4 -> regen NOT invoked, status='done' from dispatch survives"
  local root item_id="T-STORE-4" status
  root="$(_new_scenario "$item_id")"
  _run_scenario "$root" 4 "$item_id"
  status="$(_read_status "$root")"
  if [[ "$REGEN_CALLS" -eq 0 ]] && [[ "$status" == "done" ]] && [[ "$SCEN_RC" == "0" ]]; then
    pass "Test 2: store_rc=4 -> regen skipped, status='done' preserved, rc=0"
  else
    fail "Test 2: expected regen_calls=0 status=done rc=0, got regen_calls=${REGEN_CALLS} status='${status}' rc=${SCEN_RC}: ${SCEN_ERR}"
  fi
}

# ── Scenario 3: store_rc==5 (0-row no-op) -> no regen, status survives ─────
test_3_store_zerorow_noregen_status_survives() {
  log "Test 3: store_rc=5 (0-row no-op) -> regen NOT invoked, status survives (the exact 'wipe' finding 2 warns about)"
  local root item_id="T-STORE-5" status
  root="$(_new_scenario "$item_id")"
  _run_scenario "$root" 5 "$item_id"
  status="$(_read_status "$root")"
  if [[ "$REGEN_CALLS" -eq 0 ]] && [[ "$status" == "done" ]] && [[ "$SCEN_RC" == "0" ]]; then
    pass "Test 3: store_rc=5 -> regen skipped, status='done' preserved (0-row no-op did not wipe it), rc=0"
  else
    fail "Test 3: expected regen_calls=0 status=done rc=0, got regen_calls=${REGEN_CALLS} status='${status}' rc=${SCEN_RC}: ${SCEN_ERR}"
  fi
}

# ── Scenario 4: store_rc==1 (hard failure) -> no regen, status survives, ───
# loud stderr, but leadv2_tasks_release still returns 0 (finding 3) ────────
test_4_store_hardfail_noregen_loud_rc0() {
  log "Test 4: store_rc=1 (hard failure) -> regen NOT invoked, status survives, loud ERROR logged, function still returns 0"
  local root item_id="T-STORE-1" status
  root="$(_new_scenario "$item_id")"
  _run_scenario "$root" 1 "$item_id"
  status="$(_read_status "$root")"
  if [[ "$REGEN_CALLS" -eq 0 ]] && [[ "$status" == "done" ]] && [[ "$SCEN_RC" == "0" ]] \
     && grep -q "ERROR: store write FAILED" <<<"$SCEN_ERR" \
     && [[ "$SCEN_STORE_RC" == "1" ]]; then
    pass "Test 4: store_rc=1 -> regen skipped, status preserved, loud ERROR present, LEADV2_TASKS_RELEASE_LAST_STORE_RC=1, function rc=0 (caller under set -e survives)"
  else
    fail "Test 4: expected regen_calls=0 status=done rc=0 loud-ERROR store_rc=1, got regen_calls=${REGEN_CALLS} status='${status}' rc='${SCEN_RC}' store_rc='${SCEN_STORE_RC}': ${SCEN_ERR}"
  fi
}

# ── Scenario 5: caller runs leadv2_tasks_release bare under set -euo ───────
# pipefail (leadv2-queue-release.sh's exact pattern) with a hard store
# failure -- the caller script itself must NOT abort (finding 3).
test_5_bare_setE_caller_survives_hard_store_failure() {
  log "Test 5: bare call under set -euo pipefail (no || guard) survives a hard store failure, matching leadv2-queue-release.sh:74"
  local root item_id="T-STORE-BARE-CALLER"
  root="$(_new_scenario "$item_id")"
  local release_cmd="${root}/fake-release-cmd.sh"
  printf -- '#!/usr/bin/env bash\nexit 1\n' > "$release_cmd"
  chmod +x "$release_cmd"
  local regen_log="${root}/regen.log"; : > "$regen_log"
  set +e
  BARE_OUT="$(
    PROJECT_ROOT="$root" LEADV2_TASKS_RELEASE_CMD="$release_cmd" REGEN_LOG="$regen_log" \
      bash -c '
        set -euo pipefail
        source "'"$TASKS_LIB"'"
        leadv2_tasks_release "'"$item_id"'" --outcome success
        echo "CALLER_REACHED_END"
      ' 2>&1
  )"
  BARE_RC=$?
  set -e
  if [[ "$BARE_RC" -eq 0 ]] && grep -q "CALLER_REACHED_END" <<<"$BARE_OUT"; then
    pass "Test 5: bare set -e caller reached the line after leadv2_tasks_release despite a hard store failure"
  else
    fail "Test 5: expected the bare set -e caller to survive (rc=0, reach end-of-script), got rc=${BARE_RC}: ${BARE_OUT}"
  fi
}

main() {
  log "=== CLOSE-GATE-A2-STORE-YAML-IMPEDANCE-01 round-2 finding-2 regen-guard tests (RUN_ID=${RUN_ID}) ==="
  log "Script: $TASKS_LIB"
  echo ""
  test_1_store_success_regens
  test_2_store_nonsuccess_noregen_status_survives
  test_3_store_zerorow_noregen_status_survives
  test_4_store_hardfail_noregen_loud_rc0
  test_5_bare_setE_caller_survives_hard_store_failure
  echo ""
  log "=== Results: PASS=$PASS FAIL=$FAIL ==="
  if [[ "${#ERRORS[@]}" -gt 0 ]]; then
    log "Failures:"
    for e in "${ERRORS[@]}"; do log "  $e"; done
    exit 1
  fi
  log "All tests passed."
  exit 0
}

main "$@"
