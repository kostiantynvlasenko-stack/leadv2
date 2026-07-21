#!/usr/bin/env bash
# tests/test-active-registry-update-phase.sh — SUPERVISE-V2-01 item 6c:
# leadv2_active_update_phase legacy 1-arg / V2 2-arg forms + phase_started_at
# semantics + unknown-field preservation (leadv2-active-registry.sh).
#
# Tests:
#   1. legacy 1-arg form (LEADV2_TASK_ID env) updates phase
#   2. V2 2-arg form (task_id, phase) updates phase
#   3. a real phase change sets phase_started_at to a new timestamp
#   4. heartbeat (update_pulse) does NOT reset phase_started_at
#   5. unknown/custom fields on a session row survive a phase mutation
#   6. live idempotent re-register refreshes worktree without duplicating row
#   7. bash -n syntax check
#
# Portable: no GNU-only date/sed -i/timeout/flock — sandboxed via
# LEADV2_PROJECT_ROOT / LEADV2_STATE_ROOT env overrides, no git repo needed
# (both env vars are honored directly, no git rev-parse call).
# Run: bash scripts/tests/test-active-registry-update-phase.sh
# Exit 0 = all pass; non-zero = failures found.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/leadv2-temp.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGISTRY_SH="${SCRIPT_DIR}/../leadv2-active-registry.sh"

PASS=0; FAIL=0; ERRORS=()
log()  { printf -- '[TEST] %s\n' "$*"; }
pass() { PASS=$((PASS + 1)); log "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); ERRORS+=("FAIL: $1"); log "FAIL: $1"; }

TASK_ID="ARUP-T1"

_new_sandbox() {
  # Each test gets its own isolated project+state root so runs don't interfere.
  local d
  d="$(lv2_mktemp_dir "arup-test")"
  mkdir -p "${d}/proj" "${d}/state"
  printf -- '%s' "$d"
}

_field() {
  # _field <yaml_file> <task_id> <field>
  python3 -c '
import sys, yaml
with open(sys.argv[1], encoding="utf-8") as f:
    d = yaml.safe_load(f) or {}
row = next((s for s in (d.get("sessions") or []) if s.get("task_id") == sys.argv[2]), None)
if row is None:
    print("__ROW_MISSING__")
else:
    v = row.get(sys.argv[3])
    print(v if v is not None else "__NONE__")
' "$1" "$2" "$3"
}

_set_field_raw() {
  # _set_field_raw <yaml_file> <task_id> <field> <value> — injects an
  # arbitrary key directly (simulating an unknown/custom field written by
  # some other component) so we can assert it survives a later mutation.
  python3 -c '
import sys, yaml
yaml_file, task_id, field, value = sys.argv[1:5]
with open(yaml_file, encoding="utf-8") as f:
    d = yaml.safe_load(f) or {}
for s in d.get("sessions") or []:
    if s.get("task_id") == task_id:
        s[field] = value
with open(yaml_file, "w", encoding="utf-8") as f:
    yaml.dump(d, f, default_flow_style=False, sort_keys=False)
' "$1" "$2" "$3" "$4"
}

# ── Test 1: legacy 1-arg form ────────────────────────────────────────────────

test_1_legacy_1arg() {
  log "Test 1: legacy 1-arg leadv2_active_update_phase (LEADV2_TASK_ID env) updates phase"

  local sandbox out
  sandbox="$(_new_sandbox)"
  out="$(
    LEADV2_PROJECT_ROOT="${sandbox}/proj" LEADV2_STATE_ROOT="${sandbox}/state" bash -c '
      set -euo pipefail
      source "'"$REGISTRY_SH"'"
      leadv2_active_register "'"$TASK_ID"'" "Standard" "$LEADV2_PROJECT_ROOT" "test-branch" "false" >/dev/null
      LEADV2_TASK_ID="'"$TASK_ID"'" leadv2_active_update_phase "build"
      _leadv2_yaml_file
    ' 2>&1
  )" || true
  local yaml_file
  yaml_file="$(printf -- '%s\n' "$out" | tail -1)"

  local phase
  phase="$(_field "$yaml_file" "$TASK_ID" phase 2>/dev/null || echo "__ERR__")"
  if [[ "$phase" == "build" ]]; then
    pass "Test 1: legacy 1-arg set phase=build"
  else
    fail "Test 1: phase='$phase' (expected build) — full output: $out"
  fi
  rm -rf "$sandbox"
}

# ── Test 2: V2 2-arg form ────────────────────────────────────────────────────

test_2_v2_2arg() {
  log "Test 2: V2 2-arg leadv2_active_update_phase(task_id, phase) updates phase"

  local sandbox out yaml_file phase
  sandbox="$(_new_sandbox)"
  out="$(
    LEADV2_PROJECT_ROOT="${sandbox}/proj" LEADV2_STATE_ROOT="${sandbox}/state" bash -c '
      set -euo pipefail
      source "'"$REGISTRY_SH"'"
      leadv2_active_register "'"$TASK_ID"'" "Standard" "$LEADV2_PROJECT_ROOT" "test-branch" "false" >/dev/null
      leadv2_active_update_phase "'"$TASK_ID"'" "review"
      _leadv2_yaml_file
    ' 2>&1
  )" || true
  yaml_file="$(printf -- '%s\n' "$out" | tail -1)"
  phase="$(_field "$yaml_file" "$TASK_ID" phase 2>/dev/null || echo "__ERR__")"
  if [[ "$phase" == "review" ]]; then
    pass "Test 2: V2 2-arg set phase=review"
  else
    fail "Test 2: phase='$phase' (expected review) — full output: $out"
  fi
  rm -rf "$sandbox"
}

# ── Test 3 + 4: phase_started_at semantics ──────────────────────────────────

test_3_and_4_phase_started_at_semantics() {
  log "Test 3+4: phase change sets phase_started_at; heartbeat does NOT reset it"

  local sandbox out yaml_file
  sandbox="$(_new_sandbox)"
  out="$(
    LEADV2_PROJECT_ROOT="${sandbox}/proj" LEADV2_STATE_ROOT="${sandbox}/state" bash -c '
      set -euo pipefail
      source "'"$REGISTRY_SH"'"
      leadv2_active_register "'"$TASK_ID"'" "Standard" "$LEADV2_PROJECT_ROOT" "test-branch" "false" >/dev/null
      _leadv2_yaml_file
    ' 2>&1
  )" || true
  yaml_file="$(printf -- '%s\n' "$out" | tail -1)"

  local psa_intake
  psa_intake="$(_field "$yaml_file" "$TASK_ID" phase_started_at)"

  # Real phase change -> phase_started_at must change.
  LEADV2_PROJECT_ROOT="${sandbox}/proj" LEADV2_STATE_ROOT="${sandbox}/state" bash -c '
    set -euo pipefail
    source "'"$REGISTRY_SH"'"
    sleep 1
    leadv2_active_update_phase "'"$TASK_ID"'" "build"
  ' >/dev/null 2>&1

  local psa_build
  psa_build="$(_field "$yaml_file" "$TASK_ID" phase_started_at)"

  if [[ "$psa_build" != "$psa_intake" && "$psa_build" != "__NONE__" ]]; then
    pass "Test 3: phase change updated phase_started_at ($psa_intake -> $psa_build)"
  else
    fail "Test 3: phase_started_at unchanged after phase transition (intake=$psa_intake build=$psa_build)"
  fi

  # Heartbeat must NOT touch phase_started_at.
  LEADV2_PROJECT_ROOT="${sandbox}/proj" LEADV2_STATE_ROOT="${sandbox}/state" bash -c '
    set -euo pipefail
    source "'"$REGISTRY_SH"'"
    sleep 1
    leadv2_active_update_pulse "'"$TASK_ID"'"
  ' >/dev/null 2>&1

  local psa_after_pulse
  psa_after_pulse="$(_field "$yaml_file" "$TASK_ID" phase_started_at)"

  if [[ "$psa_after_pulse" == "$psa_build" ]]; then
    pass "Test 4: heartbeat did not reset phase_started_at"
  else
    fail "Test 4: heartbeat changed phase_started_at ($psa_build -> $psa_after_pulse)"
  fi
  rm -rf "$sandbox"
}

# ── Test 5: unknown fields preserved across a mutation ──────────────────────

test_5_unknown_fields_preserved() {
  log "Test 5: a custom/unknown field on a session row survives update_phase"

  local sandbox out yaml_file
  sandbox="$(_new_sandbox)"
  out="$(
    LEADV2_PROJECT_ROOT="${sandbox}/proj" LEADV2_STATE_ROOT="${sandbox}/state" bash -c '
      set -euo pipefail
      source "'"$REGISTRY_SH"'"
      leadv2_active_register "'"$TASK_ID"'" "Standard" "$LEADV2_PROJECT_ROOT" "test-branch" "false" >/dev/null
      _leadv2_yaml_file
    ' 2>&1
  )" || true
  yaml_file="$(printf -- '%s\n' "$out" | tail -1)"

  _set_field_raw "$yaml_file" "$TASK_ID" "custom_probe_field" "sentinel-value-42"

  LEADV2_PROJECT_ROOT="${sandbox}/proj" LEADV2_STATE_ROOT="${sandbox}/state" bash -c '
    set -euo pipefail
    source "'"$REGISTRY_SH"'"
    leadv2_active_update_phase "'"$TASK_ID"'" "done"
  ' >/dev/null 2>&1

  local survived
  survived="$(_field "$yaml_file" "$TASK_ID" custom_probe_field)"
  if [[ "$survived" == "sentinel-value-42" ]]; then
    pass "Test 5: unknown field preserved across update_phase"
  else
    fail "Test 5: unknown field lost — got '$survived' (expected sentinel-value-42)"
  fi
  rm -rf "$sandbox"
}

# ── Test 6: live registration refresh ───────────────────────────────────────

test_6_live_register_refresh() {
  log "Test 6: live re-register refreshes worktree and preserves one row"

  local sandbox out yaml_file result
  sandbox="$(_new_sandbox)"
  mkdir -p "${sandbox}/worktree"
  out="$(
    LEADV2_PROJECT_ROOT="${sandbox}/proj" LEADV2_STATE_ROOT="${sandbox}/state" bash -c '
      set -euo pipefail
      source "'"$REGISTRY_SH"'"
      leadv2_active_register "'"$TASK_ID"'" "Standard" "$LEADV2_PROJECT_ROOT" "main" "true" >/dev/null
      leadv2_active_register "'"$TASK_ID"'" "Standard" "'"${sandbox}/worktree"'" "worktree-branch" "false" >/dev/null
      _leadv2_yaml_file
    ' 2>&1
  )" || true
  yaml_file="$(printf -- '%s\n' "$out" | tail -1)"
  result="$(python3 - "$yaml_file" "$TASK_ID" "${sandbox}/worktree" <<'PYEOF' 2>/dev/null || true
import sys, yaml
with open(sys.argv[1], encoding="utf-8") as fh:
    rows = [r for r in (yaml.safe_load(fh) or {}).get("sessions", []) if r.get("task_id") == sys.argv[2]]
print("ok" if len(rows) == 1 and rows[0].get("worktree") == sys.argv[3] and rows[0].get("branch") == "worktree-branch" else "bad")
PYEOF
)"
  if [[ "$result" == "ok" ]]; then
    pass "Test 6: one live row refreshed to the real task worktree"
  else
    fail "Test 6: live re-register did not refresh cleanly — output: $out"
  fi
  rm -rf "$sandbox"
}

# ── Test 7: syntax ───────────────────────────────────────────────────────────

test_7_syntax() {
  log "Test 7: bash -n syntax check"
  bash -n "$REGISTRY_SH" 2>/dev/null && pass "Test 7: bash -n OK" || fail "Test 7: bash -n FAILED"
}

main() {
  log "=== leadv2-active-registry update_phase unit tests ==="
  log "Script: $REGISTRY_SH"
  echo ""
  test_7_syntax
  test_1_legacy_1arg
  test_2_v2_2arg
  test_3_and_4_phase_started_at_semantics
  test_5_unknown_fields_preserved
  test_6_live_register_refresh
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
