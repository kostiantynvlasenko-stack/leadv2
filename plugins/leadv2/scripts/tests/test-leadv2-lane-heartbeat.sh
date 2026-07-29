#!/usr/bin/env bash
# tests/test-leadv2-lane-heartbeat.sh — PULSE-01: durable heartbeat +
# running_stale/finished_empty verdicts (leadv2-lane-heartbeat.sh,
# leadv2-active-registry.sh heartbeat/mark_finished ops).
#
# Tests:
#   1. bash -n syntax check (both files)
#   2. fresh heartbeat -> running
#   3. heartbeat aged past threshold -> running_stale, NOT dead
#   4. terminal_status=completed with NO evidence -> finished_empty, NOT completed
#   5. terminal_status=completed WITH evidence -> completed
#   6. liveness reads IDENTICALLY for a Codex-arm row (no pid) and a
#      Sonnet-arm row (pid alive) at the same heartbeat age
#   7. a confirmed-dead LOCAL pid + stale heartbeat -> dead (only reachable
#      when a local pid exists at all)
#   8. concurrent heartbeat writes across N tasks do not lose an update
#   9. worked example: supervisor answers "is lane X alive" from the
#      registry alone (--all --json), no file-mtime read anywhere
#
# Portable: sandboxed via LEADV2_PROJECT_ROOT/LEADV2_STATE_ROOT env
# overrides, no git repo needed.
# Run: bash scripts/tests/test-leadv2-lane-heartbeat.sh

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/leadv2-temp.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGISTRY_SH="${SCRIPT_DIR}/../leadv2-active-registry.sh"
HEARTBEAT_SH="${SCRIPT_DIR}/../leadv2-lane-heartbeat.sh"

PASS=0; FAIL=0; ERRORS=()
log()  { printf -- '[TEST] %s\n' "$*"; }
pass() { PASS=$((PASS + 1)); log "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); ERRORS+=("FAIL: $1"); log "FAIL: $1"; }

_new_sandbox() {
  local d
  d="$(lv2_mktemp_dir "lhb-test")"
  mkdir -p "${d}/proj" "${d}/state"
  printf -- '%s' "$d"
}

_yaml_file_of() {
  # _yaml_file_of <sandbox>
  LEADV2_PROJECT_ROOT="${1}/proj" LEADV2_STATE_ROOT="${1}/state" bash -c '
    source "'"$REGISTRY_SH"'"
    _leadv2_yaml_file
  '
}

_register() {
  # _register <sandbox> <task_id>
  LEADV2_PROJECT_ROOT="${1}/proj" LEADV2_STATE_ROOT="${1}/state" bash -c '
    source "'"$REGISTRY_SH"'"
    leadv2_active_register "'"$2"'" "Standard" "$LEADV2_PROJECT_ROOT" "test-branch" "false"
  ' >/dev/null
}

_set_field_raw() {
  # _set_field_raw <yaml_file> <task_id> <field> <python-literal-expr>
  # value is passed as a raw python expression (via env) so callers can set
  # None/ints/dicts, not just strings.
  LHB_TEST_VALUE="$4" python3 -c '
import sys, os, yaml
yaml_file, task_id, field = sys.argv[1:4]
value = eval(os.environ["LHB_TEST_VALUE"])
with open(yaml_file, encoding="utf-8") as f:
    d = yaml.safe_load(f) or {}
for s in d.get("sessions") or []:
    if s.get("task_id") == task_id:
        s[field] = value
with open(yaml_file, "w", encoding="utf-8") as f:
    yaml.dump(d, f, default_flow_style=False, sort_keys=False)
' "$1" "$2" "$3"
}

_status_json() {
  # _status_json <sandbox> <task_id> [stale_min]
  LEADV2_PROJECT_ROOT="${1}/proj" LEADV2_STATE_ROOT="${1}/state" \
  LEADV2_HEARTBEAT_STALE_MIN="${3:-25}" \
    bash "$HEARTBEAT_SH" status "$2" --json
}

_field_of() {
  # _field_of <json> <field>
  python3 -c "import json,sys; print(json.load(sys.stdin).get(sys.argv[1]))" "$2" <<<"$1"
}

# ── Test 1: syntax ───────────────────────────────────────────────────────────

test_1_syntax() {
  log "Test 1: bash -n syntax check"
  if bash -n "$REGISTRY_SH" 2>/dev/null && bash -n "$HEARTBEAT_SH" 2>/dev/null; then
    pass "Test 1: bash -n OK for both files"
  else
    fail "Test 1: bash -n FAILED"
  fi
}

# ── Test 2: fresh heartbeat -> running ───────────────────────────────────────

test_2_fresh_running() {
  log "Test 2: fresh heartbeat -> running"
  local sandbox tid json status
  sandbox="$(_new_sandbox)"; tid="T2"
  _register "$sandbox" "$tid"
  LEADV2_PROJECT_ROOT="${sandbox}/proj" LEADV2_STATE_ROOT="${sandbox}/state" bash -c '
    source "'"$REGISTRY_SH"'"
    leadv2_active_heartbeat "'"$tid"'" "doing work"
  ' >/dev/null
  json="$(_status_json "$sandbox" "$tid")"
  status="$(_field_of "$json" status)"
  if [[ "$status" == "running" ]]; then
    pass "Test 2: fresh heartbeat resolved to running"
  else
    fail "Test 2: expected running, got '$status' — $json"
  fi
  rm -rf "$sandbox"
}

# ── Test 3: aged heartbeat -> running_stale, NOT dead ───────────────────────

test_3_stale_not_dead() {
  log "Test 3: heartbeat aged past threshold -> running_stale (not dead)"
  local sandbox tid yaml_file json status old_ts
  sandbox="$(_new_sandbox)"; tid="T3"
  _register "$sandbox" "$tid"
  yaml_file="$(_yaml_file_of "$sandbox")"
  # Backdate last_pulse_at 60 minutes; no pid on this row's kill-0 path is
  # exercised because pid IS present from registration (this test process's
  # own durable pid) and it is ALIVE for the whole test -- so this exercises
  # the "pid alive, heartbeat stale" branch, distinct from Test 7's "pid dead".
  old_ts="$(python3 -c "import datetime; print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(minutes=60)).strftime('%Y-%m-%dT%H:%M:%SZ'))")"
  _set_field_raw "$yaml_file" "$tid" "last_pulse_at" "'$old_ts'"
  json="$(_status_json "$sandbox" "$tid" 25)"
  status="$(_field_of "$json" status)"
  if [[ "$status" == "running_stale" ]]; then
    pass "Test 3: aged heartbeat resolved to running_stale, not dead"
  elif [[ "$status" == "dead" ]]; then
    fail "Test 3: FALSE DEATH — aged-but-alive lane reported dead: $json"
  else
    fail "Test 3: expected running_stale, got '$status' — $json"
  fi
  rm -rf "$sandbox"
}

# ── Test 4: completed with no evidence -> finished_empty ────────────────────

test_4_finished_empty() {
  log "Test 4: terminal_status=completed with empty evidence -> finished_empty"
  local sandbox tid json status
  sandbox="$(_new_sandbox)"; tid="T4"
  _register "$sandbox" "$tid"
  LEADV2_PROJECT_ROOT="${sandbox}/proj" LEADV2_STATE_ROOT="${sandbox}/state" bash -c '
    source "'"$REGISTRY_SH"'"
    leadv2_active_mark_finished "'"$tid"'" "completed" "{}"
  ' >/dev/null
  json="$(_status_json "$sandbox" "$tid")"
  status="$(_field_of "$json" status)"
  if [[ "$status" == "finished_empty" ]]; then
    pass "Test 4: empty-evidence completion downgraded to finished_empty"
  elif [[ "$status" == "completed" ]]; then
    fail "Test 4: FALSE COMPLETION — provider self-report trusted with no proof: $json"
  else
    fail "Test 4: expected finished_empty, got '$status' — $json"
  fi
  rm -rf "$sandbox"
}

# ── Test 5: completed with evidence -> completed ─────────────────────────────

test_5_completed_with_evidence() {
  log "Test 5: terminal_status=completed with real evidence -> completed"
  local sandbox tid json status
  sandbox="$(_new_sandbox)"; tid="T5"
  _register "$sandbox" "$tid"
  LEADV2_PROJECT_ROOT="${sandbox}/proj" LEADV2_STATE_ROOT="${sandbox}/state" bash -c '
    source "'"$REGISTRY_SH"'"
    leadv2_active_mark_finished "'"$tid"'" "completed" "{\"has_diff\":true,\"diff_stat_lines\":3}"
  ' >/dev/null
  json="$(_status_json "$sandbox" "$tid")"
  status="$(_field_of "$json" status)"
  if [[ "$status" == "completed" ]]; then
    pass "Test 5: evidenced completion resolved to completed"
  else
    fail "Test 5: expected completed, got '$status' — $json"
  fi
  rm -rf "$sandbox"
}

# ── Test 6: uniform across arms ──────────────────────────────────────────────

test_6_uniform_across_arms() {
  log "Test 6: liveness reads identically for a Codex-arm row and a Sonnet-arm row"
  local sandbox tid_codex tid_sonnet yaml_file json_c json_s status_c status_s
  sandbox="$(_new_sandbox)"; tid_codex="T6C"; tid_sonnet="T6S"
  _register "$sandbox" "$tid_codex"
  _register "$sandbox" "$tid_sonnet"
  yaml_file="$(_yaml_file_of "$sandbox")"

  # Codex-arm row: no local pid, backend=headless (app-server job — never has
  # a process on THIS host). Sonnet-arm row: keeps its real (alive) pid from
  # registration, backend=terminal. Both get the SAME stale heartbeat age.
  _set_field_raw "$yaml_file" "$tid_codex" "pid" "None"
  _set_field_raw "$yaml_file" "$tid_codex" "backend" "'headless'"
  _set_field_raw "$yaml_file" "$tid_sonnet" "backend" "'terminal'"
  local old_ts
  old_ts="$(python3 -c "import datetime; print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(minutes=60)).strftime('%Y-%m-%dT%H:%M:%SZ'))")"
  _set_field_raw "$yaml_file" "$tid_codex" "last_pulse_at" "'$old_ts'"
  _set_field_raw "$yaml_file" "$tid_sonnet" "last_pulse_at" "'$old_ts'"

  json_c="$(_status_json "$sandbox" "$tid_codex" 25)"
  json_s="$(_status_json "$sandbox" "$tid_sonnet" 25)"
  status_c="$(_field_of "$json_c" status)"
  status_s="$(_field_of "$json_s" status)"

  if [[ "$status_c" == "$status_s" && "$status_c" == "running_stale" ]]; then
    pass "Test 6: Codex-arm (no pid) and Sonnet-arm (alive pid) both resolve to running_stale identically"
  else
    fail "Test 6: verdicts diverged by arm — codex=$status_c sonnet=$status_s (codex json: $json_c) (sonnet json: $json_s)"
  fi
  rm -rf "$sandbox"
}

# ── Test 7: confirmed-dead local pid -> dead ─────────────────────────────────

test_7_dead_requires_confirmed_pid() {
  log "Test 7: stale heartbeat + confirmed-gone LOCAL pid -> dead"
  local sandbox tid yaml_file json status dead_pid
  sandbox="$(_new_sandbox)"; tid="T7"
  _register "$sandbox" "$tid"
  yaml_file="$(_yaml_file_of "$sandbox")"
  # A pid essentially guaranteed not to exist.
  dead_pid=999999
  local old_ts
  old_ts="$(python3 -c "import datetime; print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(minutes=60)).strftime('%Y-%m-%dT%H:%M:%SZ'))")"
  _set_field_raw "$yaml_file" "$tid" "pid" "$dead_pid"
  _set_field_raw "$yaml_file" "$tid" "last_pulse_at" "'$old_ts'"
  json="$(_status_json "$sandbox" "$tid" 25)"
  status="$(_field_of "$json" status)"
  if [[ "$status" == "dead" ]]; then
    pass "Test 7: stale heartbeat + confirmed-gone pid -> dead"
  else
    fail "Test 7: expected dead, got '$status' — $json"
  fi
  rm -rf "$sandbox"
}

# ── Test 8: concurrent heartbeat writes don't lose an update ────────────────

test_8_concurrent_writes() {
  log "Test 8: concurrent heartbeat writes across N tasks do not lose an update"
  local sandbox n i yaml_file lost=0
  sandbox="$(_new_sandbox)"
  n=8
  for ((i = 1; i <= n; i++)); do
    _register "$sandbox" "TC${i}"
  done
  local pids=()
  for ((i = 1; i <= n; i++)); do
    (
      LEADV2_PROJECT_ROOT="${sandbox}/proj" LEADV2_STATE_ROOT="${sandbox}/state" bash -c '
        source "'"$REGISTRY_SH"'"
        leadv2_active_heartbeat "TC'"$i"'" "checkpoint-'"$i"'"
      ' >/dev/null 2>&1
    ) &
    pids+=("$!")
  done
  for p in "${pids[@]}"; do wait "$p"; done

  yaml_file="$(_yaml_file_of "$sandbox")"
  for ((i = 1; i <= n; i++)); do
    local got
    got="$(python3 -c '
import sys, yaml
with open(sys.argv[1], encoding="utf-8") as f:
    d = yaml.safe_load(f) or {}
row = next((s for s in (d.get("sessions") or []) if s.get("task_id") == sys.argv[2]), None)
print(row.get("heartbeat_checkpoint") if row else "__ROW_MISSING__")
' "$yaml_file" "TC${i}")"
    if [[ "$got" != "checkpoint-${i}" ]]; then
      lost=$((lost + 1))
      log "  lost/clobbered heartbeat for TC${i}: got '$got'"
    fi
  done
  if [[ "$lost" -eq 0 ]]; then
    pass "Test 8: all $n concurrent heartbeats landed, none lost"
  else
    fail "Test 8: $lost of $n concurrent heartbeats lost or clobbered"
  fi
  rm -rf "$sandbox"
}

# ── Test 9: worked example — supervisor asks "is lane X alive" ─────────────

test_9_worked_example() {
  log "Test 9: worked example — registry-only liveness answer, no mtime read"
  local sandbox json count
  sandbox="$(_new_sandbox)"
  _register "$sandbox" "EX-ALIVE"
  _register "$sandbox" "EX-STALE"
  LEADV2_PROJECT_ROOT="${sandbox}/proj" LEADV2_STATE_ROOT="${sandbox}/state" bash -c '
    source "'"$REGISTRY_SH"'"
    leadv2_active_heartbeat "EX-ALIVE" "writing tests"
  ' >/dev/null
  local yaml_file old_ts
  yaml_file="$(_yaml_file_of "$sandbox")"
  old_ts="$(python3 -c "import datetime; print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(minutes=90)).strftime('%Y-%m-%dT%H:%M:%SZ'))")"
  _set_field_raw "$yaml_file" "EX-STALE" "last_pulse_at" "'$old_ts'"

  json="$(LEADV2_PROJECT_ROOT="${sandbox}/proj" LEADV2_STATE_ROOT="${sandbox}/state" \
    bash "$HEARTBEAT_SH" status --all --json)"
  log "  supervisor query result:"
  log "  $json"
  count="$(python3 -c "import json,sys; print(len(json.loads(sys.argv[1])))" "$json")"
  if [[ "$count" -eq 2 ]]; then
    pass "Test 9: 'status --all --json' answered both lanes from the registry alone"
  else
    fail "Test 9: expected 2 rows in --all output, got $count — $json"
  fi
  rm -rf "$sandbox"
}

main() {
  log "=== leadv2-lane-heartbeat (PULSE-01) unit tests ==="
  log "Script: $HEARTBEAT_SH"
  echo ""
  test_1_syntax
  test_2_fresh_running
  test_3_stale_not_dead
  test_4_finished_empty
  test_5_completed_with_evidence
  test_6_uniform_across_arms
  test_7_dead_requires_confirmed_pid
  test_8_concurrent_writes
  test_9_worked_example
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
