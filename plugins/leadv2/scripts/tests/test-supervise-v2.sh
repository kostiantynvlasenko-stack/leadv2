#!/usr/bin/env bash
# tests/test-supervise-v2.sh — SUPERVISE-V2-01 batch-2 item 6: extends the
# batch-1 suite (test-supervise-failclosed.sh) with coverage for items 1-4:
#
#   1. loop cadence/ceiling — unchanged poll -> 0 log lines; N lanes -> N
#      pulse lines, each <=180 bytes.
#   2. pick-script ranking JSON schema.
#   3. adoption triple-proof matrix — name-only tmux window -> orphan
#      (never adopted); full proof (name+task-id+live claude PID) -> adopted.
#   4. tombstone-before-prune — a corroborated-dead row is tombstoned AND
#      removed from active.yaml; the observe_only visibility fix (would_prune
#      always reports a gated-but-eligible prune) is asserted directly.
#   5. truth-probe timeout -> unavailable (fail-open-to-EMPTY, never -clear).
#
# Fully isolated: LEADV2_STATE_ROOT points every control-plane read/write at
# a throwaway tmp dir (never ~/.claude/leadv2-state/<real-repo>), and tmux
# tests use an isolated `tmux -L` socket (never the real "leadv2" session).
# No GNU-only utilities. Run: bash scripts/tests/test-supervise-v2.sh
# Exit 0 = all pass; non-zero = failures found.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SUPERVISE_SH="${PLUGIN_DIR}/scripts/leadv2-supervise.sh"
LOOP_SH="${PLUGIN_DIR}/scripts/leadv2-supervise-loop.sh"
PICK_SH="${PLUGIN_DIR}/scripts/leadv2-supervise-pick.sh"
STATE_PATH_SH="${PLUGIN_DIR}/scripts/leadv2-state-path.sh"

PASS=0; FAIL=0; ERRORS=()
log()  { printf -- '[TEST] %s\n' "$*"; }
pass() { PASS=$((PASS + 1)); log "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); ERRORS+=("FAIL: $1"); log "FAIL: $1"; }

CLEANUP_DIRS=()
TMUX_SOCKETS=()
cleanup() {
  for s in "${TMUX_SOCKETS[@]:-}"; do
    [[ -n "$s" ]] && tmux -L "$s" kill-server 2>/dev/null || true
  done
  for d in "${CLEANUP_DIRS[@]:-}"; do
    [[ -n "$d" && -d "$d" ]] && rm -rf "$d"
  done
  return 0
}
trap cleanup EXIT

_new_fixture() {
  # Creates one isolated repo+state root pair. Prints "<repo> <state>".
  local repo state
  repo="$(mktemp -d /tmp/sv2-repo-XXXXXX)"
  state="$(mktemp -d /tmp/sv2-state-XXXXXX)"
  CLEANUP_DIRS+=("$repo" "$state")
  (cd "$repo" && git init -q)
  mkdir -p "$repo/docs/leadv2" "$repo/docs/handoff"
  # Trailing newline is REQUIRED: `read` (in `read -r a b < <(_new_fixture)`)
  # returns 1 on EOF-without-newline even though it populated the vars —
  # under `set -e` that silently kills the whole script via the EXIT trap.
  printf -- '%s %s\n' "$repo" "$state"
}

_active_yaml() {
  LEADV2_PROJECT_ROOT="$1" LEADV2_STATE_ROOT="$2" \
    PROJECT_ROOT="$1" bash "$STATE_PATH_SH" active.yaml
}

json_get() {
  # json_get <key-path-via-python-dict-access>
  python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
print($1)
"
}

# ── Test 1: loop cadence/ceiling ────────────────────────────────────────────

test_1_loop_cadence_ceiling() {
  log "Test 1: loop cadence/ceiling — unchanged poll -> 0 lines; N lanes -> N pulse lines <=180B"

  local repo state active_path now
  read -r repo state < <(_new_fixture)
  active_path="$(_active_yaml "$repo" "$state")"
  now="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  mkdir -p "$(dirname "$active_path")"
  cat > "$active_path" <<YAML
sessions:
  - task_id: LANE-A
    session_id: sa
    started_at: "$now"
    phase: build
    pid: $$
    pid_birth: null
    protocol_version: 2
    backend: workflow
    last_pulse_at: "$now"
    stale: false
  - task_id: LANE-B
    session_id: sb
    started_at: "$now"
    phase: review
    pid: $$
    pid_birth: null
    protocol_version: 2
    backend: workflow
    last_pulse_at: "$now"
    stale: false
YAML

  # The loop renders to LOG_FILE (control-plane supervise-loop.log), never
  # stdout — resolve it the same way the loop script does.
  local loop_log
  loop_log="$(LEADV2_PROJECT_ROOT="$repo" LEADV2_STATE_ROOT="$state" \
    PROJECT_ROOT="$repo" bash "$STATE_PATH_SH" supervise-loop.log)"

  timeout 20 env LEADV2_PROJECT_ROOT="$repo" CLAUDE_PROJECT_DIR="$repo" LEADV2_STATE_ROOT="$state" \
    LEADV2_SUPERVISE_LOOP_MAX_CYCLES=1 LEADV2_SUPERVISE_LOOP_PULSE_ON_START=1 \
    LEADV2_SUPERVISE_EVENT_POLL_S=0 \
    bash "$LOOP_SH" >/dev/null 2>&1 || true

  local n_lines
  n_lines="$(grep -c "^LANE-A \|^LANE-B " "$loop_log" 2>/dev/null || true)"
  if [[ "$n_lines" -ne 2 ]]; then
    fail "Test 1a: expected 2 pulse lines (one per lane), got $n_lines. log:\n$(cat "$loop_log" 2>/dev/null)"
  else
    pass "Test 1a: N=2 lanes -> 2 pulse lines"
  fi

  local over_budget
  over_budget="$(grep "^LANE-A \|^LANE-B " "$loop_log" 2>/dev/null | awk 'length($0) > 180' | wc -l | tr -d ' ')"
  if [[ "$over_budget" -ne 0 ]]; then
    fail "Test 1b: $over_budget pulse line(s) exceed 180 bytes"
  else
    pass "Test 1b: all pulse lines <=180 bytes"
  fi

  # Unchanged poll (event-only cycle, no pulse-on-start) -> 0 NEW pulse/urgent
  # lines appended (log only grows by the "started" line at most).
  local before_size after_size new_bytes
  before_size="$(wc -c < "$loop_log" 2>/dev/null || echo 0)"
  timeout 20 env LEADV2_PROJECT_ROOT="$repo" CLAUDE_PROJECT_DIR="$repo" LEADV2_STATE_ROOT="$state" \
    LEADV2_SUPERVISE_LOOP_MAX_CYCLES=1 LEADV2_SUPERVISE_EVENT_POLL_S=0 \
    bash "$LOOP_SH" >/dev/null 2>&1 || true
  after_size="$(wc -c < "$loop_log" 2>/dev/null || echo 0)"
  new_bytes="$(python3 -c "print(int('$after_size') - int('$before_size'))")"
  # Only the "started pid=..." line is allowed to grow the log on an
  # unchanged delta-only cycle — never a pulse/urgent line.
  local new_content
  new_content="$(tail -c "$new_bytes" "$loop_log" 2>/dev/null || true)"
  if printf -- '%s' "$new_content" | grep -qE '^--- pulse|SUPERVISE-URGENT'; then
    fail "Test 1c: unchanged event-only poll appended a pulse/urgent line: $new_content"
  else
    pass "Test 1c: unchanged event-only poll -> no pulse/urgent line appended"
  fi
}

# ── Test 2: pick-script ranking JSON schema ─────────────────────────────────

test_2_pick_schema() {
  log "Test 2: pick-script ranking JSON schema"

  local repo state
  read -r repo state < <(_new_fixture)
  cat > "$repo/docs/tasks.yaml" <<'YAML'
total_open: 2
tasks:
  - id: TASK-A
    title: Fix the thing
    priority: 1
  - id: TASK-B
    title: Ship the other thing
    priority: 2
YAML

  local out
  out="$(LEADV2_PROJECT_ROOT="$repo" CLAUDE_PROJECT_DIR="$repo" LEADV2_STATE_ROOT="$state" \
    bash "$PICK_SH" 10 2>/dev/null)" || { fail "Test 2: pick-script exited nonzero"; return; }

  if ! printf -- '%s' "$out" | python3 -c "import json,sys; json.loads(sys.stdin.read())" 2>/dev/null; then
    fail "Test 2a: output is not valid JSON: $out"
  else
    pass "Test 2a: valid JSON"
  fi

  local schema_ok
  schema_ok="$(printf -- '%s' "$out" | python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
cands = d.get('candidates', d if isinstance(d, list) else [])
required = {'id', 'title', 'priority', 'recommend', 'reason'}
ok = len(cands) <= 10 and all(required.issubset(set(c.keys())) for c in cands)
print('ok' if ok else 'fail: ' + json.dumps(d)[:300])
")"
  if [[ "$schema_ok" == ok ]]; then
    pass "Test 2b: schema fields present, <=10 cap respected"
  else
    fail "Test 2b: $schema_ok"
  fi
}

# ── Test 3: adoption triple-proof matrix ────────────────────────────────────

test_3_adoption_triple_proof() {
  log "Test 3: adoption triple-proof matrix (name-only -> orphan; full proof -> adopt)"

  local repo state active_path sock
  read -r repo state < <(_new_fixture)
  active_path="$(_active_yaml "$repo" "$state")"
  mkdir -p "$(dirname "$active_path")"
  printf -- 'sessions: []\n' > "$active_path"
  printf -- 'total_open: 1\ntasks:\n  - id: TASK-KNOWN\n    title: known\n    priority: 1\n' \
    > "$repo/docs/tasks.yaml"

  sock="sv2-test-$$-$RANDOM"
  TMUX_SOCKETS+=("$sock")

  # keepalive window: killing the only window in a tmux session kills the
  # session itself — keep one dedicated window alive across 3a/3b so the
  # session (and socket) survive `kill-window` on the test window.
  tmux -L "$sock" new-session -d -s leadv2 -n KEEPALIVE 'sleep 90' 2>/dev/null

  # 3a: name-only orphan — window name matches NO known task id, no claude PID.
  tmux -L "$sock" new-window -t leadv2 -n UNKNOWN-WINDOW 'sleep 60' 2>/dev/null

  local out3a
  out3a="$(LEADV2_PROJECT_ROOT="$repo" CLAUDE_PROJECT_DIR="$repo" LEADV2_STATE_ROOT="$state" \
    LEADV2_SUPERVISE_TMUX_SOCKET="$sock" bash "$SUPERVISE_SH" --json 2>/dev/null)" \
    || { fail "Test 3a: supervise.sh exited nonzero"; return; }

  local orphaned adopted_a
  orphaned="$(printf -- '%s' "$out3a" | json_get "any(o['window']=='UNKNOWN-WINDOW' for o in d.get('orphans', []))")"
  adopted_a="$(printf -- '%s' "$out3a" | json_get "'UNKNOWN-WINDOW' in d.get('adopted', [])")"
  if [[ "$orphaned" == True && "$adopted_a" == False ]]; then
    pass "Test 3a: unknown-name window -> orphan, never adopted"
  else
    fail "Test 3a: orphaned=$orphaned adopted=$adopted_a out=$out3a"
  fi

  tmux -L "$sock" kill-window -t "leadv2:UNKNOWN-WINDOW" 2>/dev/null || true

  # 3b: full triple proof — window name == known task id, AND a live process
  # descending from the pane has "claude" in its command name.
  tmux -L "$sock" new-window -t leadv2 -n TASK-KNOWN 'exec -a claude sleep 60' 2>/dev/null \
    || tmux -L "$sock" new-window -t leadv2 -n TASK-KNOWN 'sleep 60' 2>/dev/null
  sleep 0.3

  local out3b adopted_b
  out3b="$(LEADV2_PROJECT_ROOT="$repo" CLAUDE_PROJECT_DIR="$repo" LEADV2_STATE_ROOT="$state" \
    LEADV2_SUPERVISE_TMUX_SOCKET="$sock" LEADV2_SUPERVISE_OBSERVE_ONLY=0 \
    bash "$SUPERVISE_SH" --json 2>/dev/null)" \
    || { fail "Test 3b: supervise.sh exited nonzero"; return; }
  adopted_b="$(printf -- '%s' "$out3b" | json_get "'TASK-KNOWN' in d.get('adopted', []) or 'TASK-KNOWN' in d.get('would_adopt', [])")"
  if [[ "$adopted_b" == True ]]; then
    pass "Test 3b: name+task-id+live-claude-PID triple proof -> adopted (or would_adopt if reconcile_cycle gated)"
  else
    fail "Test 3b: adopted=$adopted_b out=$out3b"
  fi
}

# ── Test 4: tombstone-before-prune + observe_only visibility ──────────────

test_4_tombstone_before_prune() {
  log "Test 4: tombstone-before-prune + would_prune visibility (observe_only gap fix)"

  local repo state active_path snap
  read -r repo state < <(_new_fixture)
  active_path="$(_active_yaml "$repo" "$state")"
  mkdir -p "$(dirname "$active_path")"
  cat > "$active_path" <<'YAML'
sessions:
  - task_id: DEAD-1
    session_id: d1
    started_at: "2020-01-01T00:00:00+00:00"
    phase: build
    pid: 999999
    pid_birth: null
    protocol_version: 1
    backend: tmux
    tmux_window: DEAD-1
    last_pulse_at: "2020-01-01T00:00:00+00:00"
    stale: false
YAML
  snap="$(LEADV2_PROJECT_ROOT="$repo" CLAUDE_PROJECT_DIR="$repo" LEADV2_STATE_ROOT="$state" \
    PROJECT_ROOT="$repo" bash "$STATE_PATH_SH" .supervise-last.json)"
  mkdir -p "$(dirname "$snap")"
  cat > "$snap" <<'JSON'
{"rendered_at":"2020-01-01T00:00:00+00:00","tasks":{},"reported_events":[],
 "dead_candidates":{"DEAD-1":"2020-01-01T00:00:00+00:00"},"reconcile_cycle_count":5}
JSON

  # 4a: observe_only=1 -> reported in would_prune, NOT actually removed, no tombstone this call.
  local tombstones out4a still_present would_prune_has
  tombstones="$(LEADV2_PROJECT_ROOT="$repo" CLAUDE_PROJECT_DIR="$repo" LEADV2_STATE_ROOT="$state" \
    PROJECT_ROOT="$repo" bash "$STATE_PATH_SH" tombstones.yaml)"
  out4a="$(LEADV2_PROJECT_ROOT="$repo" CLAUDE_PROJECT_DIR="$repo" LEADV2_STATE_ROOT="$state" \
    LEADV2_SUPERVISE_OBSERVE_ONLY=1 bash "$SUPERVISE_SH" --json 2>/dev/null)" \
    || { fail "Test 4a: supervise.sh exited nonzero"; return; }
  would_prune_has="$(printf -- '%s' "$out4a" | json_get "'DEAD-1' in d.get('would_prune', [])")"
  still_present="$(python3 -c "
import yaml
d = yaml.safe_load(open('$active_path')) or {}
print(any(s.get('task_id')=='DEAD-1' for s in d.get('sessions', [])))
")"
  if [[ "$would_prune_has" == True && "$still_present" == True ]]; then
    pass "Test 4a: observe_only=1 -> would_prune reports DEAD-1, row NOT removed"
  else
    fail "Test 4a: would_prune_has=$would_prune_has still_present=$still_present out=$out4a"
  fi

  # 4b: real prune (no observe_only) -> tombstone written BEFORE/with the prune, row removed.
  local out4b removed tombstone_has
  out4b="$(LEADV2_PROJECT_ROOT="$repo" CLAUDE_PROJECT_DIR="$repo" LEADV2_STATE_ROOT="$state" \
    LEADV2_SUPERVISE_OBSERVE_ONLY=0 bash "$SUPERVISE_SH" --json 2>/dev/null)" \
    || { fail "Test 4b: supervise.sh exited nonzero"; return; }
  removed="$(python3 -c "
import yaml
d = yaml.safe_load(open('$active_path')) or {}
print(not any(s.get('task_id')=='DEAD-1' for s in d.get('sessions', [])))
")"
  tombstone_has="false"
  if [[ -f "$tombstones" ]]; then
    tombstone_has="$(python3 -c "
import yaml
d = yaml.safe_load(open('$tombstones')) or []
print(any(t.get('task_id')=='DEAD-1' for t in d))
")"
  fi
  if [[ "$removed" == True && "$tombstone_has" == True ]]; then
    pass "Test 4b: corroborated dead row pruned AND tombstoned"
  else
    fail "Test 4b: removed=$removed tombstone_has=$tombstone_has"
  fi
}

# ── Test 5: truth-probe timeout -> unavailable ──────────────────────────────

test_5_truth_probe_timeout() {
  log "Test 5: truth-probe timeout -> unavailable (fail-open-to-EMPTY, never -clear)"

  local repo state active_path overrides_dir probe
  read -r repo state < <(_new_fixture)
  active_path="$(_active_yaml "$repo" "$state")"
  mkdir -p "$(dirname "$active_path")"
  printf -- 'sessions: []\n' > "$active_path"
  overrides_dir="$repo/.claude/leadv2-overrides"
  mkdir -p "$overrides_dir"
  probe="$overrides_dir/supervise-truth-probe.sh"
  cat > "$probe" <<'SH'
#!/usr/bin/env bash
sleep 15
echo '{"breaches":[]}'
SH
  chmod +x "$probe"

  local start end elapsed out status
  start="$(date +%s)"
  out="$(LEADV2_PROJECT_ROOT="$repo" CLAUDE_PROJECT_DIR="$repo" LEADV2_STATE_ROOT="$state" \
    bash "$SUPERVISE_SH" --json 2>/dev/null)" \
    || { fail "Test 5: supervise.sh exited nonzero"; return; }
  end="$(date +%s)"
  elapsed=$((end - start))

  status="$(printf -- '%s' "$out" | json_get "d.get('truth_probe',{}).get('status') if isinstance(d.get('truth_probe'), dict) else d.get('truth_probe')")"
  if [[ "$status" == "unavailable" && "$elapsed" -lt 14 ]]; then
    pass "Test 5: probe timeout (${elapsed}s) -> status=unavailable, never 'clear'"
  else
    fail "Test 5: status=$status elapsed=${elapsed}s (expected unavailable in <14s)"
  fi
}

# ── Test 6: bash -n syntax on all three scripts ─────────────────────────────

test_6_syntax() {
  log "Test 6: bash -n syntax check"
  local ok=1
  for f in "$SUPERVISE_SH" "$LOOP_SH" "$PICK_SH"; do
    if ! bash -n "$f" 2>/dev/null; then
      fail "Test 6: bash -n failed on $f"
      ok=0
    fi
  done
  [[ "$ok" -eq 1 ]] && pass "Test 6: bash -n OK on all 3 scripts"
}

# ── Run all ──────────────────────────────────────────────────────────────

log "=== leadv2-supervise V2 unit tests (SUPERVISE-V2-01 batch-2 item 6) ==="
log "Scripts: $SUPERVISE_SH / $LOOP_SH / $PICK_SH"
echo

test_6_syntax
test_1_loop_cadence_ceiling
test_2_pick_schema
test_3_adoption_triple_proof
test_4_tombstone_before_prune
test_5_truth_probe_timeout

echo
log "=== Results: PASS=$PASS FAIL=$FAIL ==="
if [[ "$FAIL" -gt 0 ]]; then
  log "Failures:"
  for e in "${ERRORS[@]}"; do
    log "  $e"
  done
  exit 1
fi
exit 0
