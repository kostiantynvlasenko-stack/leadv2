#!/usr/bin/env bash
# tests/test-leadv2-causal-critique.sh — Unit tests for leadv2-causal-critique.js
# (REFLECT-CAUSAL-CRITIQUE-01, including fix-round-2 security/reliability fixes).
#
# Runs the REAL, unmodified workflow source (see fixtures/causal-critique-harness.mjs for the
# execution methodology) against a real fixture git repo with real context.yaml/scorecard/
# review-signature/ledger files, plus the REAL §5a python heredoc extracted live from
# lead-reflect/SKILL.md (not hand-duplicated) to prove the byte-identical / folded-in wiring.
#
# Tests 1-9 (round 1, unchanged behavior):
#   1. bash -n / node --check syntax on the workflow file
#   2. "good" scenario: 1 driver kept (has evidence), 1 driver DROPPED (empty evidence)
#   3. "good" scenario: freeform_insight is non-null and was appended to freeform-insights.jsonl
#   4. Digest phase actually issued real bash() calls against fixture files
#   5. "unavailable" scenario: agent() returns null -> fail-open shape, no throw
#   6. "trivial-skip" scenario: task_class=Trivial -> agent() is NEVER called
#   7-8. lead-reflect SKILL.md §5a python heredoc (extracted live), empty vs filled tempfile
#
# Tests 9+ (fix-round-2 re-attack proof):
#   9.  freeform_insight with empty trace_evidence is DROPPED (H1 fix) -- not appended to jsonl
#   10. malicious TASK_ID containing `'; touch ...; echo '` does NOT execute during Digest (C1
#       sibling fix, leadv2-causal-critique.js shq())
#   11. §5a PoC replay #1: causal_critique JSON whose string VALUE contains a literal `'''`
#       sequence -> entry.causal_critique folds in correctly, reflect-history entry stays
#       intact (task/reflect/signature all present) -- no SyntaxError, no data loss
#   12. §5a PoC replay #2: causal_critique JSON whose string VALUE contains an os.system(...)
#       breakout payload -> NO marker file created (proves no code execution), entry intact
#   13. §5a PoC replay #3: causal_critique JSON whose string VALUE contains backtick/$(...)
#       sequences -> NO marker file created, entry intact
#   14. §5a with missing tempfile (flag off / skip): causal_critique key omitted, entry intact
#       (byte-identical) -- AND the whole other fields (task/reflect/signature) still write
#       correctly even though the try/except wraps the fold
#
# Run: bash scripts/tests/test-leadv2-causal-critique.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
WORKFLOW_JS="${PLUGIN_ROOT}/workflows/leadv2-causal-critique.js"
HARNESS="${SCRIPT_DIR}/fixtures/causal-critique-harness.mjs"
SKILL_MD="${PLUGIN_ROOT}/skills/lead-reflect/SKILL.md"

PASS=0; FAIL=0; ERRORS=()
log()  { printf -- '[TEST] %s\n' "$*"; }
pass() { PASS=$((PASS + 1)); log "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); ERRORS+=("$1"); log "FAIL: $1"; }

FIXTURE_DIR="$(mktemp -d)"
trap 'rm -rf "$FIXTURE_DIR"' EXIT

TASK_ID="FIXTURE-TASK-01"
mkdir -p "$FIXTURE_DIR/docs/handoff/$TASK_ID" "$FIXTURE_DIR/docs/handoff/FIXTURE-TASK-02" "$FIXTURE_DIR/docs/leadv2"

cat > "$FIXTURE_DIR/docs/handoff/$TASK_ID/context.yaml" <<YAML
decisions:
  - "D1: use rpc() for partial-index upserts"
off_limits:
  - immune-patterns.yaml
plan:
  parallel_groups: ["F1", "F2"]
verification: "pytest -x --tb=short green"
git:
  start_sha: HEAD~1
YAML
cp "$FIXTURE_DIR/docs/handoff/$TASK_ID/context.yaml" "$FIXTURE_DIR/docs/handoff/FIXTURE-TASK-02/context.yaml"

cat > "$FIXTURE_DIR/docs/leadv2/scorecard.jsonl" <<'JSONL'
{"task_id":"FIXTURE-TASK-01","verify_pass":true,"cost":0.42,"error_usd":0,"founder_interventions":0}
JSONL

cat > "$FIXTURE_DIR/docs/handoff/$TASK_ID/review-signature.md" <<'MD'
verdict: REVISE
blocking: 1
dims: {schema: fail, tests: pass}
quality_score: 0.7
MD

cat > "$FIXTURE_DIR/docs/leadv2/ledger.jsonl" <<JSONL
{"event":"phase_enter","task_id":"$TASK_ID","phase":"build"}
{"event":"phase_exit","task_id":"$TASK_ID","phase":"build","error":"PGRST102"}
JSONL

cat > "$FIXTURE_DIR/docs/leadv2-negative-memory.yaml" <<'YAML'
entries: []
YAML

(
  cd "$FIXTURE_DIR"
  git init -q
  git config user.email test@test.local
  git config user.name test
  git add -A
  git commit -q -m "fixture base"
  echo extra >> docs/leadv2-negative-memory.yaml
  git add -A
  git commit -q -m "fixture head"
)

# ── Test 1: syntax ──────────────────────────────────────────────────────────
if node --check "$WORKFLOW_JS" 2>/tmp/causal-critique-synerr.log; then
  pass "workflow file passes node --check"
else
  fail "node --check failed: $(cat /tmp/causal-critique-synerr.log)"
fi

# ── Tests 2-4: "good" scenario ───────────────────────────────────────────────
GOOD_OUT="$(node "$HARNESS" "$FIXTURE_DIR" "$WORKFLOW_JS" good 2>/tmp/causal-critique-good.err || true)"
if [[ -z "$GOOD_OUT" ]]; then
  fail "good scenario produced no output; stderr: $(cat /tmp/causal-critique-good.err)"
else
  DRIVERS_KEPT=$(printf '%s' "$GOOD_OUT" | python3 -c "import json,sys; print(len(json.load(sys.stdin)['result']['causal_critique']['root_drivers']))")
  if [[ "$DRIVERS_KEPT" == "1" ]]; then
    pass "anti-hallucination filter: 1 driver kept, 1 dropped (empty evidence)"
  else
    fail "expected 1 kept driver, got $DRIVERS_KEPT"
  fi

  FREEFORM_ID=$(printf '%s' "$GOOD_OUT" | python3 -c "import json,sys; r=json.load(sys.stdin)['result']['freeform_insight']; print(r['id'] if r else 'NONE')")
  if [[ "$FREEFORM_ID" != "NONE" && -n "$FREEFORM_ID" ]]; then
    pass "freeform_insight returned with id=$FREEFORM_ID (free-text schema-escape path)"
  else
    fail "freeform_insight missing from result"
  fi

  if grep -q "\"id\": \"$FREEFORM_ID\"" "$FIXTURE_DIR/docs/leadv2/freeform-insights.jsonl" 2>/dev/null; then
    pass "freeform-insights.jsonl contains the appended candidate record"
  else
    fail "freeform-insights.jsonl missing or does not contain id=$FREEFORM_ID"
  fi

  # WORKFLOW-BASH-FIX-01: there is no bash() global at runtime anymore -- the Digest phase's
  # reads now happen inside the ONE 'gather-digest' agent() call. Assert the harness's mock
  # agentImpl genuinely executed those commands (realExec count) AND that the resulting digest
  # content (visible in the downstream causal-critique prompt) reflects REAL fixture file
  # content, not canned values -- the direct replacement for the old bash-call-count check.
  REAL_EXEC=$(printf '%s' "$GOOD_OUT" | python3 -c "import json,sys; print(json.load(sys.stdin)['calls']['realExec'])")
  if [[ "$REAL_EXEC" -gt 3 ]]; then
    pass "Digest phase genuinely executed $REAL_EXEC real shell command(s) via the gather-digest/persist agent() calls"
  else
    fail "expected >3 real-executed commands in Digest/Persist, got $REAL_EXEC"
  fi

  DIGEST_REFLECTS_FIXTURE=$(printf '%s' "$GOOD_OUT" | python3 -c "import json,sys; print(json.load(sys.stdin)['digestReflectsFixture'])")
  if [[ "$DIGEST_REFLECTS_FIXTURE" == "True" ]]; then
    pass "gather-digest agent() call genuinely read real fixture content (context.yaml + ledger.jsonl reflected in critique prompt)"
  else
    fail "digest content does not reflect real fixture files -- gather-digest may be returning canned/empty values"
  fi
fi

# ── Test 5: agent unavailable -> fail-open ──────────────────────────────────
UNAVAIL_OUT="$(node "$HARNESS" "$FIXTURE_DIR" "$WORKFLOW_JS" unavailable 2>/tmp/causal-critique-unavail.err || true)"
SKIP_REASON=$(printf '%s' "$UNAVAIL_OUT" | python3 -c "import json,sys; print(json.load(sys.stdin)['result'].get('skipped_reason','MISSING'))" 2>/dev/null || echo "PARSE_FAIL")
if [[ "$SKIP_REASON" == "agent_unavailable" ]]; then
  pass "agent() unavailable -> fail-open (skipped_reason=agent_unavailable, no throw)"
else
  fail "expected skipped_reason=agent_unavailable, got '$SKIP_REASON' (stderr: $(cat /tmp/causal-critique-unavail.err))"
fi

# ── Test 6: Trivial task_class -> agent() never called ──────────────────────
TRIVIAL_OUT="$(node "$HARNESS" "$FIXTURE_DIR" "$WORKFLOW_JS" trivial-skip 2>/tmp/causal-critique-trivial.err || true)"
TRIVIAL_REASON=$(printf '%s' "$TRIVIAL_OUT" | python3 -c "import json,sys; print(json.load(sys.stdin)['result'].get('skipped_reason','MISSING'))" 2>/dev/null || echo "PARSE_FAIL")
if [[ "$TRIVIAL_REASON" == "task_class=Trivial" ]]; then
  pass "task_class=Trivial -> skipped before any agent() call (defense-in-depth gate)"
else
  fail "expected skipped_reason=task_class=Trivial, got '$TRIVIAL_REASON' (stderr: $(cat /tmp/causal-critique-trivial.err))"
fi

# ── Test 9: H1 fix -- freeform_insight with empty trace_evidence is dropped ──
NOEVID_OUT="$(node "$HARNESS" "$FIXTURE_DIR" "$WORKFLOW_JS" freeform-no-evidence 2>/tmp/causal-critique-noevid.err || true)"
if [[ -z "$NOEVID_OUT" ]]; then
  fail "freeform-no-evidence scenario produced no output; stderr: $(cat /tmp/causal-critique-noevid.err)"
else
  NOEVID_FI=$(printf '%s' "$NOEVID_OUT" | python3 -c "import json,sys; r=json.load(sys.stdin)['result']['freeform_insight']; print('NULL' if r is None else 'NON_NULL')")
  NOEVID_JSONL_HAS=$(printf '%s' "$NOEVID_OUT" | python3 -c "import json,sys; print(json.load(sys.stdin)['jsonlContainsUngrounded'])")
  if [[ "$NOEVID_FI" == "NULL" && "$NOEVID_JSONL_HAS" == "False" ]]; then
    pass "H1 fix: freeform_insight with empty trace_evidence dropped, never persisted to jsonl"
  else
    fail "H1 fix regression: freeform_insight=$NOEVID_FI jsonl_has_ungrounded=$NOEVID_JSONL_HAS"
  fi
fi

# ── Test 10: C1-sibling fix -- malicious TASK_ID does not execute during Digest ──
MALICIOUS_OUT="$(node "$HARNESS" "$FIXTURE_DIR" "$WORKFLOW_JS" malicious-taskid 2>/tmp/causal-critique-malicious.err || true)"
if [[ -z "$MALICIOUS_OUT" ]]; then
  fail "malicious-taskid scenario produced no output; stderr: $(cat /tmp/causal-critique-malicious.err)"
else
  MARKER_CREATED=$(printf '%s' "$MALICIOUS_OUT" | python3 -c "import json,sys; print(json.load(sys.stdin)['markerCreated'])")
  if [[ "$MARKER_CREATED" == "False" ]]; then
    pass "C1-sibling fix: malicious TASK_ID (shell metacharacters) did NOT execute during Digest (shq() escaping holds)"
  else
    fail "CRITICAL REGRESSION: malicious TASK_ID EXECUTED shell code (PWNED_TASKID_MARKER was created)"
  fi
fi

# ── Tests 11-14: lead-reflect §5a python heredoc, extracted LIVE from SKILL.md ───
PY_BLOCK=$(awk '
  n==0 && /^python3 - <<PYEOF$/ { f=1; n=1; next }
  f==1 && /^PYEOF$/ { exit }
  f==1 { print }
' "$SKILL_MD")
if [[ -z "$PY_BLOCK" ]]; then
  fail "could not extract §5a python heredoc from SKILL.md"
else
  PY_TMPL="$FIXTURE_DIR/5a-template.py"
  printf '%s' "$PY_BLOCK" > "$PY_TMPL"
  T5A_TASK_ID="T5A-TASK"
  CC_TMP_PATH="$FIXTURE_DIR/docs/handoff/$T5A_TASK_ID/.causal-critique.json.tmp"
  mkdir -p "$FIXTURE_DIR/docs/handoff/$T5A_TASK_ID"
  MARKER_5A="$FIXTURE_DIR/PWNED_5A_MARKER"

  run_5a() {
    local hist="$1"
    ( cd "$FIXTURE_DIR" && python3 - "$PY_TMPL" "$hist" "$T5A_TASK_ID" <<'DRIVER'
import sys
tmpl_path, hist, task_id = sys.argv[1], sys.argv[2], sys.argv[3]
with open(tmpl_path, encoding="utf-8") as fh:
    src = fh.read()
subs = {
    "task_id": task_id, "almost_missed": "none", "opus_needed_for": "none",
    "parallel_win": "no parallel opportunity", "codex_rounds": "0", "pattern_for_immune": "none",
    "fix_quality": "n/a", "phase": "close", "task_class": "Standard", "failure_class": "none",
    "recovery_decision": "n/a", "outcome": "success", "involved_agents_json": "[]",
    "change_kind": "code", "REFLECT_HISTORY": hist,
}
for k, v in subs.items():
    src = src.replace("${" + k + "}", v)
exec(compile(src, "<rendered-5a>", "exec"), {})
DRIVER
    )
  }

  check_entry_intact() {
    local hist="$1"
    python3 -c "
import yaml, sys
d = yaml.safe_load(open('$hist'))
e = d['entries'][-1]
assert e['task'] == '$T5A_TASK_ID', e
assert 'reflect' in e and 'signature' in e, e
print('ok')
" >/dev/null 2>&1
  }

  rm -f "$CC_TMP_PATH" "$MARKER_5A"
  EMPTY_HIST="$FIXTURE_DIR/reflect-history-empty.yaml"
  run_5a "$EMPTY_HIST" >/tmp/causal-critique-5a-empty.log 2>&1
  if python3 -c "
import yaml
d = yaml.safe_load(open('$EMPTY_HIST'))
e = d['entries'][-1]
assert 'causal_critique' not in e, e
print('ok')
" >/dev/null 2>&1 && check_entry_intact "$EMPTY_HIST"; then
    pass "§5a missing tempfile: causal_critique key omitted (byte-identical), entry otherwise intact"
  else
    fail "§5a missing-tempfile case failed ($(cat /tmp/causal-critique-5a-empty.log))"
  fi

  FILLED_HIST="$FIXTURE_DIR/reflect-history-filled.yaml"
  printf '%s' '{"outcome_summary": "test", "root_drivers": [], "cheap_win": null}' > "$CC_TMP_PATH"
  run_5a "$FILLED_HIST" >/tmp/causal-critique-5a-filled.log 2>&1
  if python3 -c "
import yaml
d = yaml.safe_load(open('$FILLED_HIST'))
e = d['entries'][-1]
assert e['causal_critique']['outcome_summary'] == 'test', e
print('ok')
" >/dev/null 2>&1; then
    pass "§5a with valid tempfile JSON: entry.causal_critique folded in correctly, tempfile cleaned up"
  else
    fail "§5a valid-JSON case: causal_critique not folded in ($(cat /tmp/causal-critique-5a-filled.log))"
  fi
  if [[ ! -f "$CC_TMP_PATH" ]]; then
    pass "§5a cleans up the tempfile after a successful fold (os.remove)"
  else
    fail "§5a left the tempfile behind after a successful fold"
  fi

  rm -f "$CC_TMP_PATH" "$MARKER_5A"
  POC1_HIST="$FIXTURE_DIR/reflect-history-poc1.yaml"
  python3 -c "
import json
payload = {'outcome_summary': \"quoting a python docstring that uses ''' triple-quotes routinely\", 'root_drivers': [], 'cheap_win': None}
open('$CC_TMP_PATH', 'w').write(json.dumps(payload))
"
  run_5a "$POC1_HIST" >/tmp/causal-critique-5a-poc1.log 2>&1
  if python3 -c "
import yaml
d = yaml.safe_load(open('$POC1_HIST'))
e = d['entries'][-1]
assert \"'''\" in e['causal_critique']['outcome_summary'], e
print('ok')
" >/dev/null 2>&1 && check_entry_intact "$POC1_HIST"; then
    pass "PoC#1 replay (literal ''' in critique text): folds in safely, no SyntaxError, entry intact"
  else
    fail "PoC#1 replay FAILED -- $(cat /tmp/causal-critique-5a-poc1.log)"
  fi

  rm -f "$CC_TMP_PATH"
  POC2_HIST="$FIXTURE_DIR/reflect-history-poc2.yaml"
  python3 -c "
import json
payload = {'outcome_summary': '''; import os; os.system(\"touch $MARKER_5A\"); x=\"''', 'root_drivers': [], 'cheap_win': None}
open('$CC_TMP_PATH', 'w').write(json.dumps(payload))
"
  run_5a "$POC2_HIST" >/tmp/causal-critique-5a-poc2.log 2>&1
  if [[ ! -f "$MARKER_5A" ]] && check_entry_intact "$POC2_HIST"; then
    pass "PoC#2 replay (os.system breakout payload): NO code executed, entry intact"
  else
    MARK2="no"; [[ -f "$MARKER_5A" ]] && MARK2="yes"
    fail "CRITICAL REGRESSION: PoC#2 replay -- marker exists=$MARK2, log: $(cat /tmp/causal-critique-5a-poc2.log)"
  fi

  rm -f "$CC_TMP_PATH" "$MARKER_5A"
  POC3_HIST="$FIXTURE_DIR/reflect-history-poc3.yaml"
  python3 -c "
import json
payload = {'outcome_summary': 'contains \`touch $MARKER_5A\` and \$(touch $MARKER_5A) as literal text', 'root_drivers': [], 'cheap_win': None}
open('$CC_TMP_PATH', 'w').write(json.dumps(payload))
"
  run_5a "$POC3_HIST" >/tmp/causal-critique-5a-poc3.log 2>&1
  if [[ ! -f "$MARKER_5A" ]] && check_entry_intact "$POC3_HIST"; then
    pass "PoC#3 replay (backtick/dollar-paren payload): NO shell execution, entry intact"
  else
    MARK3="no"; [[ -f "$MARKER_5A" ]] && MARK3="yes"
    fail "CRITICAL REGRESSION: PoC#3 replay -- marker exists=$MARK3, log: $(cat /tmp/causal-critique-5a-poc3.log)"
  fi
fi

echo ""
echo "=== leadv2-causal-critique test summary: $PASS passed, $FAIL failed ==="
if [[ $FAIL -gt 0 ]]; then
  printf '  - %s\n' "${ERRORS[@]}"
  exit 1
fi
exit 0
