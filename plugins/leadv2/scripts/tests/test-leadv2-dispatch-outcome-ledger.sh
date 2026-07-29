#!/usr/bin/env bash
# tests/test-leadv2-dispatch-outcome-ledger.sh — DISPATCH-OUTCOME-LEDGER-01 regression test.
#
# Proves, against the SHIPPED leadv2-dispatch-code.sh (real subprocess, real exit codes,
# same discipline as test-leadv2-lane-shape.sh — never a hand-reimplemented copy of the
# decision logic), that the dispatch ledger records OUTCOME, not just intent:
#
#   1. A lane that FINISHES with no commit frees its task signature automatically — the
#      identical mission re-dispatches with no manual step and no --force.
#   2. A lane that FINISHES having committed real work (a non-runtime-state path) stays
#      deduped — re-dispatch of the identical mission is still refused.
#   3. A lane that is still RUNNING never frees its signature, regardless of what it has
#      or hasn't committed yet.
#   4. A commit that touches ONLY runtime-state paths (lock file, bus offset, the
#      cross-worktree active.yaml registry) does NOT count as evidence — behaves like (1).
#   5. One-step rollback: LEADV2_DISPATCH_OUTCOME_LEDGER=0 restores the exact pre-existing
#      behavior — a finished-and-empty lane's signature stays blocked for the TTL.
#
# All five drive the REAL sonnet spawn path (glm/codex arms are exercised via the exact
# same _dispatch_worker_liveness/_dispatch_evidence_exists functions, selected by the `arm`
# field already recorded on the row — no separate code path to test here) with a stub
# claude-subsession.sh launcher (LEADV2_DISPATCH_SUBSESSION_BIN) that spawns a real,
# killable/short-lived OS process and prints its PID — sonnet's own liveness check IS
# `kill -0`, so this needs no provider-status stub, unlike glm/codex.
#
# Run: bash plugins/leadv2/scripts/tests/test-leadv2-dispatch-outcome-ledger.sh

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DISPATCH_SH="${SCRIPTS_DIR}/leadv2-dispatch-code.sh"
source "${SCRIPTS_DIR}/leadv2-temp.sh"

PASS=0; FAIL=0; ERRORS=()
pass() { PASS=$((PASS + 1)); printf '[TEST] PASS: %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); ERRORS+=("$1"); printf '[TEST] FAIL: %s\n' "$1"; }

RUN_ID="dispatch-outcome-$$-$(date +%s 2>/dev/null || echo 0)"
TMPDIR_ROOT="$(lv2_mktemp_dir "${RUN_ID}")"
ROOT="${TMPDIR_ROOT}/repo"
CACHE_DIR="${TMPDIR_ROOT}/cache"
FAKE_SUBSESSION="${TMPDIR_ROOT}/fake-claude-subsession.sh"
trap 'rm -rf "$TMPDIR_ROOT"' EXIT

# ── hermetic git repo + minimal routing.yaml (forces arm=sonnet, no quota/exclusion
#    lookups against the real host state) ────────────────────────────────────────────
mkdir -p "${ROOT}/.claude/ref" "${ROOT}/docs/leadv2/.bus-offsets" "${ROOT}/platform"
( cd "${ROOT}" && git init -q && git config user.email test@example.com && git config user.name test \
  && printf 'seed\n' > seed.txt && git add seed.txt && git commit -qm seed )
# git commit timestamps and dispatch_reserve's created_epoch are both second-granularity;
# without this gap the seed commit above can land in the SAME second as the first
# dispatch's reservation, and `git log --since` (inclusive of the boundary) then wrongly
# counts the seed commit as "evidence" for a task reserved a heartbeat later.
sleep 1

cat > "${ROOT}/.claude/ref/leadv2-routing.yaml" <<'YAML'
router:
  glm_policy:
    sonnet_exceptions:
      - id: safety_gate_publish_payments
    opus_only_mission_kinds: []
    codex_fitting_mission_kinds: []
    codex_default_tier: standard
YAML

# ── fake claude-subsession.sh: spawns a real OS process, prints its PID in the exact
#    "PID=<n> LABEL=... SESSION_ID=..." shape spawn_worker's sonnet-arm parser expects.
#    FAKE_SONNET_BEHAVIOR (env, read at invocation time) selects lifetime: quick (~0.3s,
#    used for "finished by the time we check") or long (dies only on trap/timeout, used
#    for "still running").
cat > "${FAKE_SUBSESSION}" <<'EOF'
#!/usr/bin/env bash
# nohup (not a bare subshell "&") is required here: a plain `( sleep N ) &` dies the
# instant THIS script's own process exits in some sandboxed shells (the child is reaped
# along with the launcher's process group) -- nohup detaches it the same way the REAL
# claude-subsession.sh's `run_subsession &` (a forked, independent bash function) does.
set -uo pipefail
case "${FAKE_SONNET_BEHAVIOR:-quick}" in
  long) nohup sleep 300 >/dev/null 2>&1 & ;;
  *)    nohup sleep 0.3 >/dev/null 2>&1 & ;;
esac
pid=$!
disown
printf 'PID=%s LABEL=fake-lane SESSION_ID=fake-session\n' "${pid}"
exit 0
EOF
chmod +x "${FAKE_SUBSESSION}"

_dispatch() {  # <mission> [extra args...]
  ( CLAUDE_PROJECT_ROOT="${ROOT}" LEADV2_PROJECT_ROOT="${ROOT}" \
    LEADV2_DISPATCH_CACHE_DIR="${CACHE_DIR}" \
    LEADV2_DISPATCH_SUBSESSION_BIN="${FAKE_SUBSESSION}" \
    LEADV2_JOURNAL_BIN=/bin/true \
    LEADV2_ROUTER_V2_QUOTA_FILTER=0 \
    LEADV2_EXCLUDED_ARMS="__none__" \
    LEADV2_LANE_SHAPE=off \
    "${DISPATCH_SH}" "$1" --protected --spawn "${@:2}" )
}

_pid_from_output() {  # <dispatch stdout> -> PID
  sed -n 's/.*handle=PID=\([0-9][0-9]*\).*/\1/p' <<<"$1" | tail -1
}

_wait_dead() {  # <pid> <timeout_s>
  local pid="$1" deadline=$(( $(date +%s) + $2 ))
  while kill -0 "${pid}" 2>/dev/null; do
    [[ $(date +%s) -lt ${deadline} ]] || return 1
    sleep 0.05
  done
  return 0
}

# ── 1. finished, no commit -> re-dispatch succeeds, no --force ──────────────────────
m1="task: quick-empty-lane $$ $(date +%s)"
FAKE_SONNET_BEHAVIOR=quick out1="$(_dispatch "${m1}")"; rc1=$?
pid1="$(_pid_from_output "${out1}")"
if [[ ${rc1} -eq 0 && -n "${pid1}" ]]; then
  if _wait_dead "${pid1}" 5; then
    sleep 1   # clear any same-second git-log ambiguity before the retry
    out1b="$(FAKE_SONNET_BEHAVIOR=quick _dispatch "${m1}")"; rc1b=$?
    if [[ ${rc1b} -eq 0 ]] && grep -q 'route_resolved' <<<"${out1b}"; then
      pass "1: finished-empty lane frees its signature (re-dispatch rc=0)"
    else
      fail "1: expected rc=0/route_resolved on retry, got rc=${rc1b} out=${out1b}"
    fi
  else
    fail "1: setup — fake process never died"
  fi
else
  fail "1: setup — first dispatch failed rc=${rc1} out=${out1}"
fi

# ── 2. finished, real commit (non-runtime path) -> re-dispatch still refused ────────
m2="task: quick-real-work-lane $$ $(date +%s)"
FAKE_SONNET_BEHAVIOR=quick out2="$(_dispatch "${m2}")"; rc2=$?
pid2="$(_pid_from_output "${out2}")"
if [[ ${rc2} -eq 0 && -n "${pid2}" ]] && _wait_dead "${pid2}" 5; then
  sleep 1
  ( cd "${ROOT}" && printf 'change\n' >> platform/fake_change.py \
    && git add platform/fake_change.py && git commit -qm "real work" )
  sleep 1
  out2b="$(_dispatch "${m2}")"; rc2b=$?
  if [[ ${rc2b} -eq 2 ]] && grep -q 'duplicate_task_signature' <<<"${out2b}"; then
    pass "2: finished lane with a real commit stays deduped (re-dispatch refused)"
  else
    fail "2: expected rc=2/duplicate_task_signature, got rc=${rc2b} out=${out2b}"
  fi
else
  fail "2: setup — first dispatch or process-death wait failed (rc=${rc2})"
fi

# ── 3. still RUNNING -> signature never freed ───────────────────────────────────────
# NOTE: the assignment must prefix the FUNCTION CALL (`FAKE_SONNET_BEHAVIOR=long
# _dispatch ...`), not the `out3=` assignment around it -- `FAKE_SONNET_BEHAVIOR=long
# out3="$(_dispatch ...)"` is two bare shell-variable assignments with no command word,
# so the fake launcher's subprocess never actually sees the env var and silently falls
# back to its "quick" (0.3s) default, making the lane genuinely dead by the time of the
# second dispatch a few lines below (found while adding
# test-dispatch-ledger-partial-close.sh, DISPATCH-LEDGER-PARTIAL-CLOSE-01).
m3="task: long-running-lane $$ $(date +%s)"
out3="$( FAKE_SONNET_BEHAVIOR=long _dispatch "${m3}" )"; rc3=$?
pid3="$(_pid_from_output "${out3}")"
if [[ ${rc3} -eq 0 && -n "${pid3}" ]] && kill -0 "${pid3}" 2>/dev/null; then
  out3b="$(_dispatch "${m3}")"; rc3b=$?
  if [[ ${rc3b} -eq 2 ]] && grep -q 'duplicate_task_signature' <<<"${out3b}"; then
    pass "3: still-running lane's signature is never freed"
  else
    fail "3: expected rc=2/duplicate_task_signature while alive, got rc=${rc3b} out=${out3b}"
  fi
  kill "${pid3}" 2>/dev/null || true
else
  fail "3: setup — first dispatch failed or fake process died too fast (rc=${rc3})"
fi

# ── 4. runtime-state-only commit (lock / bus-offset / active.yaml) does NOT count ───
m4="task: quick-runtime-state-only-lane $$ $(date +%s)"
FAKE_SONNET_BEHAVIOR=quick out4="$(_dispatch "${m4}")"; rc4=$?
pid4="$(_pid_from_output "${out4}")"
if [[ ${rc4} -eq 0 && -n "${pid4}" ]] && _wait_dead "${pid4}" 5; then
  sleep 1
  ( cd "${ROOT}" \
    && printf 'active: {}\n' > docs/leadv2/active.yaml \
    && printf '1\n' > docs/leadv2/.bus-offsets/some-session \
    && : > docs/leadv2/active.yaml.lock \
    && git add docs/leadv2/active.yaml docs/leadv2/.bus-offsets/some-session \
    && git commit -qm "runtime state churn only" )
  sleep 1
  out4b="$(_dispatch "${m4}")"; rc4b=$?
  if [[ ${rc4b} -eq 0 ]] && grep -q 'route_resolved' <<<"${out4b}"; then
    pass "4: runtime-state-only commit does not count as evidence (re-dispatch rc=0)"
  else
    fail "4: expected rc=0/route_resolved, got rc=${rc4b} out=${out4b}"
  fi
else
  fail "4: setup — first dispatch or process-death wait failed (rc=${rc4})"
fi

# ── 5. one-step rollback: OUTCOME_LEDGER=0 restores the exact pre-existing behavior ─
m5="task: quick-empty-lane-rollback $$ $(date +%s)"
FAKE_SONNET_BEHAVIOR=quick out5="$( LEADV2_DISPATCH_OUTCOME_LEDGER=0 _dispatch "${m5}" )"; rc5=$?
pid5="$(_pid_from_output "${out5}")"
if [[ ${rc5} -eq 0 && -n "${pid5}" ]] && _wait_dead "${pid5}" 5; then
  sleep 1
  out5b="$( LEADV2_DISPATCH_OUTCOME_LEDGER=0 _dispatch "${m5}" )"; rc5b=$?
  if [[ ${rc5b} -eq 2 ]] && grep -q 'duplicate_task_signature' <<<"${out5b}"; then
    pass "5: LEADV2_DISPATCH_OUTCOME_LEDGER=0 restores exact pre-existing TTL-only blocking"
  else
    fail "5: expected rc=2/duplicate_task_signature under the rollback flag, got rc=${rc5b} out=${out5b}"
  fi
else
  fail "5: setup — first dispatch or process-death wait failed (rc=${rc5})"
fi

printf '\n[TEST] %s passed, %s failed\n' "${PASS}" "${FAIL}"
if (( FAIL > 0 )); then
  printf '[TEST] Failures:\n'
  for e in "${ERRORS[@]}"; do printf '  - %s\n' "$e"; done
  exit 1
fi
exit 0
