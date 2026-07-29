#!/usr/bin/env bash
# ROUTER-T14c — prove the v2 toggle chain and the v1 rollback identity.
# This suite is intentionally hermetic: its ledger, journals, config, and baseline are
# all isolated below TMPDIR.  It never reaches a live dispatch lane.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCH_BIN="${SCRIPT_DIR}/../leadv2-dispatch-code.sh"
REAL_DISPATCH_BIN="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$DISPATCH_BIN")"
CANONICAL_ROOT="$(git -C "$(dirname "$REAL_DISPATCH_BIN")/../../.." rev-parse --show-toplevel)"
BASE_SHA="${LEADV2_TOGGLE_BASE_SHA:-cbca20a}"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/leadv2-router-v2-toggle.XXXXXX")"
BASELINE_BIN="$(dirname "$REAL_DISPATCH_BIN")/.baseline-$$.sh"
PASS=0 FAIL=0

cleanup() { rm -f "$BASELINE_BIN"; rm -rf "$TMP"; }
trap cleanup EXIT
pass() { PASS=$((PASS + 1)); printf 'PASS: %s\n' "$*"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$*" >&2; }

git -C "$CANONICAL_ROOT" show "${BASE_SHA}:plugins/leadv2/scripts/leadv2-dispatch-code.sh" > "$BASELINE_BIN" || {
  printf 'FAIL: cannot extract baseline %s\n' "$BASE_SHA" >&2; exit 1;
}
chmod +x "$BASELINE_BIN"

FIXTURE_ROOT="$TMP/proj"
mkdir -p "$FIXTURE_ROOT/.claude/ref"
cp /Users/kostiantyn.vlasenko/Projects/persona-engine/.claude/ref/leadv2-routing.yaml \
  "$FIXTURE_ROOT/.claude/ref/leadv2-routing.yaml"
# The consuming policy intentionally supplies the live codex arm.  v2's additive
# registry has not yet been synced there, so add the canonical registry to THIS fixture.
cat "$CANONICAL_ROOT/plugins/leadv2/config/leadv2-routing.yaml" >> "$FIXTURE_ROOT/.claude/ref/leadv2-routing.yaml"

JOURNAL_STUB="$TMP/journal-stub.sh"
cat > "$JOURNAL_STUB" <<'EOF'
#!/usr/bin/env bash
# The differential transcript is the router's journal contract, not unrelated
# product-gate bookkeeping that was added after the supplied v1 baseline.
if [[ "$*" == *route_resolved\ * || "$*" == *glm_failures_flag_ignored\ * || "$*" == *dispatch_refused\ reason=router_v2_unavailable\ * ]]; then
  printf '%s\n' "$*" >> "${LEADV2_TOGGLE_JOURNAL:?}"
fi
EOF
chmod +x "$JOURNAL_STUB"

# $1=label $2=binary $3=toggle $4=case-id; remaining args are dispatch args.
run_case() {
  local label="$1" bin="$2" toggle="$3" case_id="$4"; shift 4
  local out="$TMP/${label}-${case_id}.out" journal="$TMP/${label}-${case_id}.journal" rc
  : > "$journal"
  set +e
  env CLAUDE_PROJECT_ROOT="$FIXTURE_ROOT" PROJECT_ROOT="$FIXTURE_ROOT" LEADV2_DRY_RUN=1 LEADV2_DISPATCH_SPAWN=0 \
    LEADV2_DISPATCH_ARCHITECT_GATE=0 LEADV2_DISPATCH_E2E_GATE=0 LEADV2_DISPATCH_REVIEW_GATE=0 \
    LEADV2_DISPATCH_CACHE_DIR="$TMP/${label}-${case_id}-cache" \
    DISPATCH_LEDGER_DIR="$TMP/${label}-${case_id}-ledger" \
    LEADV2_JOURNAL_BIN="$JOURNAL_STUB" LEADV2_TOGGLE_JOURNAL="$journal" \
    LEADV2_ROUTER_V2="$toggle" bash "$bin" "unique toggle ${case_id}" "$@" --no-spawn >"$out" 2>&1
  rc=$?
  set -e
  { printf 'CASE=%s RC=%s\n' "$case_id" "$rc"; grep 'route_resolved ' "$out" || true; cat "$journal"; } \
    > "$TMP/${label}-${case_id}.transcript"
  printf '%s' "$rc"
}

assert_v1() { # id expected-model expected-rule expected-reason expected-rc [dispatch args]
  local id="$1" model="$2" rule="$3" reason="$4" wanted_rc="$5"; shift 5
  local rc line journal
  rc="$(run_case work "$REAL_DISPATCH_BIN" 0 "$id" "$@")"
  line="$(grep 'route_resolved ' "$TMP/work-${id}.out" | tail -1 || true)"
  journal="$(cat "$TMP/work-${id}.journal")"
  if [[ "$rc" == "$wanted_rc" && "$line" == *"router=v1 model=${model}"* && "$line" == *"rule=${rule}"* && "$line" == *"reason=${reason}"* ]]; then
    pass "v1 ${id}: ${model}/${rule}"
  else
    fail "v1 ${id}: rc=${rc} line=${line}"
  fi
  if [[ "$id" == 09 && "$journal" == *"route_resolved by=router router=v1 model=codex"* ]]; then
    pass "v1 09: codex decision journaled"
  elif [[ "$id" == 09 ]]; then
    fail "v1 09: codex decision missing from journal"
  fi
  if [[ "$id" == 10 && "$journal" == *"glm_failures_flag_ignored"* ]]; then
    pass "v1 10: ignored failure input journaled"
  elif [[ "$id" == 10 ]]; then
    fail "v1 10: ignored failure input not journaled"
  fi
}

# The matrix covers every v1 predicate, both sides of the funnel, and its divergent
# codex arm.  Mission text is unique per case, so dedup cannot make ordering observable.
assert_v1 01 glm none glm_default 0
assert_v1 02 sonnet safety_gate_publish_payments sonnet_exception 0 --protected
assert_v1 03 sonnet safety_gate_publish_payments sonnet_exception 0 --safety
assert_v1 04 sonnet integration_critical_4subsystems sonnet_exception 0 --subsystems 4
assert_v1 05 sonnet integration_critical_4subsystems sonnet_exception 0 --interactive
assert_v1 06 sonnet ui_design_judgment sonnet_exception 0 --ui-judgment
assert_v1 07 sonnet glm_lock_busy_no_second_channel sonnet_exception 0 --glm-lock-busy
assert_v1 08 opus opus_only_kind opus_mission_kind 3 --kind architecture
assert_v1 09 codex codex_fitting_kind codex_fitting_mission_kind 0 --kind codex_fitting_dev
assert_v1 10 glm none glm_default 0 --glm-failures 2

# Re-run the same matrix through the immutable v1 source and compare only the captured
# decision transcript (stdout route line, exit code, and decision journal lines).
for id in $(seq -w 1 10); do
  case "$id" in
    01) args=() ;; 02) args=(--protected) ;; 03) args=(--safety) ;;
    04) args=(--subsystems 4) ;; 05) args=(--interactive) ;; 06) args=(--ui-judgment) ;;
    07) args=(--glm-lock-busy) ;; 08) args=(--kind architecture) ;;
    09) args=(--kind codex_fitting_dev) ;; 10) args=(--glm-failures 2) ;;
  esac
  run_case baseline "$BASELINE_BIN" 0 "$id" "${args[@]}" >/dev/null
done
if diff -u "$TMP/work-01.transcript" "$TMP/baseline-01.transcript" >/dev/null && \
   diff -u <(cat "$TMP/work-"{01,02,03,04,05,06,07,08,09,10}.transcript) \
           <(cat "$TMP/baseline-"{01,02,03,04,05,06,07,08,09,10}.transcript) >/dev/null; then
  pass "v1 byte-identical vs ${BASE_SHA}"
else
  fail "v1 transcript differs from ${BASE_SHA}"
fi

# Recorder wrappers execute the real binaries.  Filter derives the complete registry
# from the fixture YAML; it never encodes a provider-arm exclusion in test code.
TRACE="$TMP/trace"
make_wrapper() { # name real trace-word [forced failure]
  local name="$1" real="$2" word="$3" fail_mode="${4:-0}" path
  path="$TMP/${name}.sh"
  cat > "$path" <<EOF
#!/usr/bin/env bash
printf '%s\\n' '$word' >> "\${LEADV2_TOGGLE_TRACE:?}"
if [[ '$fail_mode' == 1 && "\$1" == resolve ]]; then exit 19; fi
exec bash '$real' "\$@"
EOF
  chmod +x "$path"; printf '%s' "$path"
}
FILTER_WRAP="$(make_wrapper router "$CANONICAL_ROOT/plugins/leadv2/scripts/leadv2-router-v2.sh" filter)"
JUDGE_WRAP="$(make_wrapper judge "$CANONICAL_ROOT/plugins/leadv2/scripts/leadv2-task-judge.sh" judge)"
BANDIT_WRAP="$(make_wrapper bandit "$CANONICAL_ROOT/plugins/leadv2/scripts/leadv2-route-bandit.sh" 'bandit sample')"
QUOTA_STUB="$TMP/quota-live.sh"
cat > "$QUOTA_STUB" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '{"glm":{"provider":"glm","status":"ok","five_hour":{"pct":10,"usable_now":18},"weekly":{"pct":10,"usable_now":0.54},"binding_window":"weekly"},"codex":{"provider":"codex","status":"ok","windows":[{"kind":"primary","used_percent":10,"usable_now":9}],"binding_window":"primary"},"anthropic":{"provider":"anthropic","status":"ok","accounts":[{"active":true,"status":"ok","five_hour":{"pct":10,"usable_now":18},"seven_day":{"pct":10,"usable_now":0.54},"binding_window":"seven_day"}]}}'
EOF
chmod +x "$QUOTA_STUB"

: > "$TRACE"
export LEADV2_ROUTER_V2_BIN="$FILTER_WRAP" LEADV2_TASK_JUDGE_BIN="$JUDGE_WRAP" LEADV2_ROUTE_BANDIT_BIN="$BANDIT_WRAP" LEADV2_TOGGLE_TRACE="$TRACE" LEADV2_QUOTA_LIVE="$QUOTA_STUB"
v2rc="$(run_case v2 "$REAL_DISPATCH_BIN" 1 v2positive)"
v2line="$(grep 'route_resolved ' "$TMP/v2-v2positive.out" | tail -1 || true)"
if [[ "$v2rc" == 0 && "$v2line" == *"router=v2"* && "$v2line" == *"rule=router_v2"* ]]; then
  pass "v2 route is labeled on stdout"
else
  fail "v2 stdout label: rc=${v2rc} line=${v2line}"
fi
if [[ "$(cat "$TMP/v2-v2positive.journal")" == *"route_resolved by=router router=v2"* ]]; then
  pass "v2 route is labeled in the journal"
else
  fail "v2 journal label missing"
fi
if [[ "$(cat "$TRACE")" == $'filter\njudge\nbandit sample\nfilter' ]]; then
  pass "v2 chain trace: filter -> judge -> bandit sample -> resolve"
else
  fail "v2 chain trace: $(tr '\n' ' ' < "$TRACE")"
fi

FAIL_RESOLVER="$(make_wrapper resolver-fail "$CANONICAL_ROOT/plugins/leadv2/scripts/leadv2-router-v2.sh" filter 1)"
export LEADV2_ROUTER_V2_BIN="$FAIL_RESOLVER"
neg_rc="$(run_case v2fail "$REAL_DISPATCH_BIN" 1 v2negative)"
neg_journal="$(cat "$TMP/v2fail-v2negative.journal")"
if [[ "$neg_rc" == 1 && "$neg_journal" == *"dispatch_refused reason=router_v2_unavailable"* && "$neg_journal" == *"router=v2"* ]]; then
  pass "v2 resolver failure refuses with router=v2"
else
  fail "v2 resolver failure: rc=${neg_rc} journal=${neg_journal}"
fi

printf '=== Results: %s passed, %s failed ===\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
