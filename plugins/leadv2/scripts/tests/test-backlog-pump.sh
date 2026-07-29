#!/usr/bin/env bash
# tests/test-backlog-pump.sh — BACKLOG-PUMP-01 coverage.
#
# 1. lane finishes -> next queued task dispatches automatically, no human step.
# 2. queue empty -> nothing happens, quietly (exit 0, no dispatch call).
# 3. concurrency cap respected (active == max -> no dispatch).
# 4. kill switch off is a no-op; unresolved Git state refuses a refill.
# 5. duplicate signature is returned to the existing dispatch ledger, never
#    dispatched or claimed by a second bookkeeping surface.
# 6. a judgment-class task is NOT auto-dispatched (lane=human-needed never a
#    top_n candidate; an opus-arm rc=3 candidate is unclaimed + surfaced).
# 7. a lane that finished having produced nothing does not silently consume
#    the queue (1st empty close -> requeued; 2nd consecutive -> parked
#    human-needed, never spins forever).
# 8. dry-run shows the next N candidates + declared plan-order reason.
#
# Fully isolated: LEADV2_PROJECT_ROOT / LEADV2_STATE_ROOT point at throwaway
# tmp dirs; LEADV2_BACKLOG_PUMP_DISPATCH_BIN / LEADV2_JOURNAL_BIN stub out the
# real dispatch + journal so this never touches a real ledger or spawns a
# real worker. Run: bash scripts/tests/test-backlog-pump.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PUMP_SH="${PLUGIN_DIR}/scripts/leadv2-backlog-pump.sh"
TASKS_LIB="${PLUGIN_DIR}/scripts/leadv2-tasks-lib.sh"

PASS=0; FAIL=0; ERRORS=()
log()  { printf -- '[TEST] %s\n' "$*"; }
pass() { PASS=$((PASS + 1)); log "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); ERRORS+=("FAIL: $1"); log "FAIL: $1"; }

CLEANUP_DIRS=()
cleanup() {
  for d in "${CLEANUP_DIRS[@]:-}"; do
    [[ -n "$d" && -d "$d" ]] && rm -rf "$d"
  done
  return 0
}
trap cleanup EXIT

_mktmp() { local d; d="$(mktemp -d 2>/dev/null || mktemp -d -t lv2bp)"; CLEANUP_DIRS+=("$d"); printf '%s' "$d"; }

# Healthy-quota stub — every test that isn't specifically about the quota
# floor wants headroom asserted true, never coupled to this machine's real
# live provider quota.
HEALTHY_QUOTA_BIN="$(_mktmp)/quota-stub.sh"
cat >"$HEALTHY_QUOTA_BIN" <<'STUB'
#!/usr/bin/env bash
printf '{"glm":{"status":"ok","usable_now":true},"codex":{"status":"unknown"},"anthropic":{"status":"ok","usable_now":true}}\n'
STUB
chmod +x "$HEALTHY_QUOTA_BIN"

# One isolated repo+state root pair, with tasks.yaml + active.yaml seeded.
_new_fixture() {
  local repo state
  repo="$(_mktmp)"; state="$(_mktmp)"
  (cd "$repo" && git init -q && git config user.email t@t.test && git config user.name t \
     && mkdir -p docs/leadv2 docs/handoff && echo init >README.md && git add -A \
     && git commit -q -m init)
  mkdir -p "${state}/docs/leadv2"
  cat >"${state}/docs/leadv2/active.yaml" <<'YAML'
meta:
  hard_limit: 2
sessions: []
YAML
  printf '%s %s\n' "$repo" "$state"
}

_write_tasks() {  # $1=repo $2=yaml-body
  cat >"${1}/docs/tasks.yaml" <<EOF
$2
EOF
}

# Stub dispatch bin: reads a control file for the rc to return per call,
# records every invocation to a log for assertion.
_make_dispatch_stub() {  # $1=dir -> path to stub + control file path (echoed as "stub rc_file log_file")
  local dir="$1"
  local stub="${dir}/dispatch-stub.sh"
  local rcfile="${dir}/dispatch-rc"
  local logfile="${dir}/dispatch-log"
  echo 0 >"$rcfile"
  : >"$logfile"
  cat >"$stub" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$1" >>"${logfile}"
exit "\$(cat "${rcfile}")"
STUB
  chmod +x "$stub"
  printf '%s %s %s\n' "$stub" "$rcfile" "$logfile"
}

_run_pump() {  # env-wrapped invocation
  local repo="$1" state="$2" dispatch_stub="$3"; shift 3
  LEADV2_PROJECT_ROOT="$repo" PROJECT_ROOT="$repo" LEADV2_STATE_ROOT="${state}/docs/leadv2" \
  CLAUDE_PROJECT_DIR="$repo" \
  LEADV2_BACKLOG_PUMP="${LEADV2_BACKLOG_PUMP:-1}" \
  LEADV2_BACKLOG_PUMP_DISPATCH_BIN="$dispatch_stub" \
  LEADV2_BACKLOG_PUMP_QUOTA_BIN="$HEALTHY_QUOTA_BIN" \
  LEADV2_JOURNAL_BIN=/bin/true \
  bash "$PUMP_SH" "$@"
}

# ── Test 1: lane finishes -> next queued task dispatches automatically ─────
test_auto_dispatch() {
  read -r repo state < <(_new_fixture)
  _write_tasks "$repo" '- id: T1
  lane: action
  status: pending
  priority: high
  title: fix the thing
  created_at: "2026-01-01T00:00:00Z"
'
  read -r stub rcfile logfile < <(_make_dispatch_stub "$state")
  echo 0 >"$rcfile"

  _run_pump "$repo" "$state" "$stub" check >/dev/null 2>&1

  if grep -q "fix the thing" "$logfile" 2>/dev/null; then
    pass "auto_dispatch: queued task dispatched with no human step"
  else
    fail "auto_dispatch: expected dispatch call, log=$(cat "$logfile" 2>/dev/null)"
  fi
}

# ── Test 2: queue empty -> nothing happens quietly ──────────────────────────
test_empty_queue() {
  read -r repo state < <(_new_fixture)
  _write_tasks "$repo" '[]'
  read -r stub rcfile logfile < <(_make_dispatch_stub "$state")

  local rc=0
  _run_pump "$repo" "$state" "$stub" check >/dev/null 2>&1 || rc=$?

  if [[ "$rc" -eq 0 && ! -s "$logfile" ]]; then
    pass "empty_queue: exit 0, no dispatch call"
  else
    fail "empty_queue: rc=$rc log_size=$(wc -c <"$logfile" 2>/dev/null)"
  fi
}

# ── Test 3: concurrency cap respected ───────────────────────────────────────
test_concurrency_cap() {
  read -r repo state < <(_new_fixture)
  _write_tasks "$repo" '- id: T1
  lane: action
  status: pending
  priority: high
  title: task one
  created_at: "2026-01-01T00:00:00Z"
'
  cat >"${state}/docs/leadv2/active.yaml" <<'YAML'
meta:
  hard_limit: 2
sessions:
  - task_id: existing-1
  - task_id: existing-2
YAML
  read -r stub rcfile logfile < <(_make_dispatch_stub "$state")

  _run_pump "$repo" "$state" "$stub" check >/dev/null 2>&1

  if [[ ! -s "$logfile" ]]; then
    pass "concurrency_cap: at capacity, no dispatch attempted"
  else
    fail "concurrency_cap: dispatched despite full capacity: $(cat "$logfile")"
  fi
}

# ── Test 4: rollback flag exactly restores the pre-pump no-op ──────────────
test_kill_switch_off() {
  read -r repo state < <(_new_fixture)
  _write_tasks "$repo" '- id: T-off
  lane: action
  status: pending
  priority: high
  title: must remain untouched while disabled
  created_at: "2026-01-01T00:00:00Z"
'
  read -r stub rcfile logfile < <(_make_dispatch_stub "$state")
  local before after
  before="$(cat "$repo/docs/tasks.yaml")"
  LEADV2_BACKLOG_PUMP=0 _run_pump "$repo" "$state" "$stub" check >/dev/null 2>&1
  after="$(cat "$repo/docs/tasks.yaml")"
  if [[ ! -s "$logfile" && "$before" == "$after" ]]; then
    pass "kill_switch_off: no dispatch and no queue mutation"
  else
    fail "kill_switch_off: pump changed state while disabled"
  fi
}

# ── Test 5: a mid-conflict repository never receives a refill ──────────────
test_tree_mid_conflict() {
  read -r repo state < <(_new_fixture)
  _write_tasks "$repo" '- id: T-conflict
  lane: action
  status: pending
  priority: high
  title: must not start during a merge conflict
  created_at: "2026-01-01T00:00:00Z"
'
  read -r stub rcfile logfile < <(_make_dispatch_stub "$state")
  git -C "$repo" rev-parse HEAD >"$repo/.git/MERGE_HEAD"
  _run_pump "$repo" "$state" "$stub" check >/dev/null 2>&1
  if [[ ! -s "$logfile" ]]; then
    pass "tree_mid_conflict: no dispatch while Git has MERGE_HEAD"
  else
    fail "tree_mid_conflict: dispatched into an unresolved tree"
  fi
}

# ── Test 6: duplicate refusal remains owned by the dispatch ledger ─────────
test_duplicate_signature_refused() {
  read -r repo state < <(_new_fixture)
  _write_tasks "$repo" '- id: T-duplicate
  lane: action
  status: pending
  priority: high
  title: already represented by a dispatch signature
  created_at: "2026-01-01T00:00:00Z"
'
  read -r stub rcfile logfile < <(_make_dispatch_stub "$state")
  echo 2 >"$rcfile"
  _run_pump "$repo" "$state" "$stub" check >/dev/null 2>&1
  local item
  item="$(LEADV2_PROJECT_ROOT="$repo" PROJECT_ROOT="$repo" bash -c "source '$TASKS_LIB'; leadv2_tasks_by_id T-duplicate" 2>/dev/null)"
  if [[ -s "$logfile" && "$item" == *"status: pending"* && "$item" == *"by: null"* ]]; then
    pass "duplicate_signature_refused: ledger refusal unclaims without redispatch"
  else
    fail "duplicate_signature_refused: duplicate was not safely returned to queue"
  fi
}

# ── Test 7: judgment-class task is NOT auto-dispatched ──────────────────────
test_judgment_class_excluded() {
  read -r repo state < <(_new_fixture)
  _write_tasks "$repo" '- id: T-human
  lane: human-needed
  status: pending
  priority: critical
  title: approve the payment change
  created_at: "2026-01-01T00:00:00Z"
'
  read -r stub rcfile logfile < <(_make_dispatch_stub "$state")

  _run_pump "$repo" "$state" "$stub" check >/dev/null 2>&1

  if [[ ! -s "$logfile" ]]; then
    pass "judgment_class_excluded: human-needed lane never dispatched"
  else
    fail "judgment_class_excluded: dispatched a human-needed task: $(cat "$logfile")"
  fi

  # Sub-case: a candidate that resolves to arm=opus (rc=3) is unclaimed and
  # surfaced, not silently dropped or retried as a normal skip.
  read -r repo2 state2 < <(_new_fixture)
  _write_tasks "$repo2" '- id: T-arch
  lane: action
  status: pending
  priority: high
  title: redesign the auth subsystem
  created_at: "2026-01-01T00:00:00Z"
'
  read -r stub2 rcfile2 logfile2 < <(_make_dispatch_stub "$state2")
  echo 3 >"$rcfile2"
  mkdir -p "${state2}/docs/leadv2"
  : >"${state2}/docs/leadv2/open-threads.md"

  _run_pump "$repo2" "$state2" "$stub2" check >/dev/null 2>&1

  local unclaimed=0
  grep -q "^[[:space:]]*status: pending" <(LEADV2_PROJECT_ROOT="$repo2" PROJECT_ROOT="$repo2" bash -c "source '$TASKS_LIB'; leadv2_tasks_by_id T-arch") 2>/dev/null && unclaimed=1

  if [[ "$unclaimed" -eq 1 ]] && grep -q "T-arch" "${state2}/docs/leadv2/open-threads.md" 2>/dev/null; then
    pass "judgment_class_excluded: opus-arm candidate unclaimed + surfaced to founder"
  else
    fail "judgment_class_excluded: opus-arm candidate not properly unclaimed/surfaced"
  fi
}

# ── Test 8: empty-outcome lane does not silently consume the queue ─────────
test_empty_outcome_bounded() {
  read -r repo state < <(_new_fixture)
  _write_tasks "$repo" '- id: T-empty
  lane: action
  status: pending
  priority: high
  title: a task that never actually changes anything
  created_at: "2026-01-01T00:00:00Z"
'
  # Claim it once so reap has something to unclaim.
  LEADV2_PROJECT_ROOT="$repo" PROJECT_ROOT="$repo" bash -c "source '$TASKS_LIB'; leadv2_tasks_claim T-empty --by tester" >/dev/null 2>&1

  # 1st reap: diff is empty (no commits since main) -> requeue to pending.
  LEADV2_PROJECT_ROOT="$repo" PROJECT_ROOT="$repo" LEADV2_STATE_ROOT="${state}/docs/leadv2" \
    LEADV2_JOURNAL_BIN=/bin/true LEADV2_OUTCOME_LEDGER_BIN=/nonexistent \
    bash "$PUMP_SH" reap T-empty >/dev/null 2>&1

  local status1
  status1="$(LEADV2_PROJECT_ROOT="$repo" PROJECT_ROOT="$repo" bash -c "source '$TASKS_LIB'; leadv2_tasks_by_id T-empty" 2>/dev/null | grep -E '^[[:space:]]*(status|lane):')"

  # Re-claim + reap again (2nd consecutive empty close) -> parked human-needed.
  LEADV2_PROJECT_ROOT="$repo" PROJECT_ROOT="$repo" bash -c "source '$TASKS_LIB'; leadv2_tasks_claim T-empty --by tester" >/dev/null 2>&1
  LEADV2_PROJECT_ROOT="$repo" PROJECT_ROOT="$repo" LEADV2_STATE_ROOT="${state}/docs/leadv2" \
    LEADV2_JOURNAL_BIN=/bin/true LEADV2_OUTCOME_LEDGER_BIN=/nonexistent \
    bash "$PUMP_SH" reap T-empty >/dev/null 2>&1

  local lane2
  lane2="$(LEADV2_PROJECT_ROOT="$repo" PROJECT_ROOT="$repo" bash -c "source '$TASKS_LIB'; leadv2_tasks_by_id T-empty" 2>/dev/null | grep -E '^[[:space:]]*lane:' | awk '{print $2}')"

  if grep -q "status: pending" <<<"$status1" && [[ "$lane2" == "human-needed" ]]; then
    pass "empty_outcome_bounded: 1st empty -> requeued, 2nd consecutive -> parked (never spins forever)"
  else
    fail "empty_outcome_bounded: status1='$status1' lane2='$lane2'"
  fi
}

# ── Test 9: dry-run shows next N candidates + declared plan order ──────────
test_dry_run() {
  read -r repo state < <(_new_fixture)
  _write_tasks "$repo" '- id: T-low
  lane: action
  status: pending
  priority: low
  title: low prio task
  created_at: "2026-01-01T00:00:00Z"
- id: T-high
  lane: action
  status: pending
  priority: high
  title: high prio task
  created_at: "2026-01-01T00:00:00Z"
- id: T-crit
  lane: recovery
  status: pending
  priority: critical
  title: crit recovery task
  created_at: "2026-01-01T00:00:00Z"
'
  local out
  out="$(LEADV2_PROJECT_ROOT="$repo" PROJECT_ROOT="$repo" LEADV2_STATE_ROOT="${state}/docs/leadv2" \
         CLAUDE_PROJECT_DIR="$repo" LEADV2_JOURNAL_BIN=/bin/true \
         bash "$PUMP_SH" dry-run 3 2>/dev/null)"

  local first_line; first_line="$(head -1 <<<"$out")"
  if grep -q "T-low" <<<"$first_line" && grep -q "declared plan order" <<<"$out"; then
    pass "dry_run: plan-declared source order + reasons printed, no side effects"
  else
    fail "dry_run: unexpected output: $out"
  fi
}

log "=== BACKLOG-PUMP-01 test suite ==="
test_auto_dispatch
test_empty_queue
test_concurrency_cap
test_kill_switch_off
test_tree_mid_conflict
test_duplicate_signature_refused
test_judgment_class_excluded
test_empty_outcome_bounded
test_dry_run

log ""
log "=== Results: ${PASS} passed, ${FAIL} failed ==="
if [[ "$FAIL" -gt 0 ]]; then
  for e in "${ERRORS[@]}"; do log "$e"; done
  exit 1
fi
exit 0
