#!/usr/bin/env bash
# tests/test-dispatch-ledger-partial-close.sh — DISPATCH-LEDGER-PARTIAL-CLOSE-01 regression
# test.
#
# DISPATCH-OUTCOME-LEDGER-01 (0b0e32f) freed a row whose lane finished and produced NOTHING.
# LANE-TURNCAP-CHECKPOINT-01 (220eeaf), shipped the same night, made a lane cut off at the
# turn cap commit whatever it has before dying -- so that same outcome resolution now reads
# a checkpointed-and-cut-off lane's partial commit as "real work" and blocks re-dispatch of a
# mission that never actually finished. This proves the fix: a row is freed ONLY when BOTH
# "dead" AND "checkpointed with no completion sentinel" are true; a genuinely finished lane
# (with or without an earlier checkpoint blip it recovered from) stays deduped exactly as
# item 8 (0b0e32f) already guarantees, and a still-running lane is never touched.
#
# Same harness discipline as test-leadv2-dispatch-outcome-ledger.sh: drives the REAL shipped
# leadv2-dispatch-code.sh (real subprocess, real exit codes) with a stub claude-subsession.sh
# launcher that spawns a real, killable OS process and prints its PID.
#
# Run: bash plugins/leadv2/scripts/tests/test-dispatch-ledger-partial-close.sh

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DISPATCH_SH="${SCRIPTS_DIR}/leadv2-dispatch-code.sh"
source "${SCRIPTS_DIR}/leadv2-temp.sh"

PASS=0; FAIL=0; ERRORS=()
pass() { PASS=$((PASS + 1)); printf '[TEST] PASS: %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); ERRORS+=("$1"); printf '[TEST] FAIL: %s\n' "$1"; }

RUN_ID="dispatch-partial-close-$$-$(date +%s 2>/dev/null || echo 0)"
TMPDIR_ROOT="$(lv2_mktemp_dir "${RUN_ID}")"
ROOT="${TMPDIR_ROOT}/repo"
CACHE_DIR="${TMPDIR_ROOT}/cache"
FAKE_SUBSESSION="${TMPDIR_ROOT}/fake-claude-subsession.sh"
trap 'rm -rf "$TMPDIR_ROOT"' EXIT

mkdir -p "${ROOT}/.claude/ref" "${ROOT}/docs/leadv2/.bus-offsets" "${ROOT}/platform"
( cd "${ROOT}" && git init -q && git config user.email test@example.com && git config user.name test \
  && printf 'seed\n' > seed.txt && git add seed.txt && git commit -qm seed )
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

cat > "${FAKE_SUBSESSION}" <<'EOF'
#!/usr/bin/env bash
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

_sig8_from_output() { sed -n 's/.*task=\([0-9a-f]\{8\}\).*/\1/p' <<<"$1" | tail -1; }
_pid_from_output()  { sed -n 's/.*handle=PID=\([0-9][0-9]*\).*/\1/p' <<<"$1" | tail -1; }

_wait_dead() {  # <pid> <timeout_s>
  local pid="$1" deadline=$(( $(date +%s) + $2 ))
  while kill -0 "${pid}" 2>/dev/null; do
    [[ $(date +%s) -lt ${deadline} ]] || return 1
    sleep 0.05
  done
  return 0
}

_checkpoint_note() { printf '%s/docs/handoff/dispatch-%s/CHECKPOINT.md' "${ROOT}" "$1"; }
_sentinel()         { printf '%s/docs/handoff/dispatch-%s/phase8-passed.flag' "${ROOT}" "$1"; }

# ── 1. dead + fresh CHECKPOINT.md + no sentinel -> re-dispatch succeeds ─────────────
m1="task: turncap-cutoff-lane $$ $(date +%s)"
FAKE_SONNET_BEHAVIOR=quick out1="$(_dispatch "${m1}")"; rc1=$?
pid1="$(_pid_from_output "${out1}")"; sig8_1="$(_sig8_from_output "${out1}")"
if [[ ${rc1} -eq 0 && -n "${pid1}" && -n "${sig8_1}" ]] && _wait_dead "${pid1}" 5; then
  sleep 1
  note="$(_checkpoint_note "${sig8_1}")"
  mkdir -p "$(dirname "${note}")"
  printf '# Turncap auto-checkpoint\n\nCut off mid-mission, only got partway through.\n' > "${note}"
  ( cd "${ROOT}" && printf 'partial\n' >> platform/partial_work.py \
    && git add platform/partial_work.py "docs/handoff/dispatch-${sig8_1}/CHECKPOINT.md" \
    && git commit -qm "chore(leadv2): turncap checkpoint dispatch-${sig8_1}" )
  sleep 1
  out1b="$(_dispatch "${m1}")"; rc1b=$?
  if [[ ${rc1b} -eq 0 ]] && grep -q 'route_resolved' <<<"${out1b}"; then
    pass "1: checkpointed-and-cut-off lane (no sentinel) frees its signature (re-dispatch rc=0)"
  else
    fail "1: expected rc=0/route_resolved on retry, got rc=${rc1b} out=${out1b}"
  fi
else
  fail "1: setup — first dispatch or process-death wait failed (rc=${rc1})"
fi

# ── 2. dead + real commit, genuinely finished (Phase-8 sentinel present) -> still deduped,
#      EVEN THOUGH an earlier checkpoint blip exists (recovered case must not be freed) ────
m2="task: turncap-recovered-then-finished-lane $$ $(date +%s)"
FAKE_SONNET_BEHAVIOR=quick out2="$(_dispatch "${m2}")"; rc2=$?
pid2="$(_pid_from_output "${out2}")"; sig8_2="$(_sig8_from_output "${out2}")"
if [[ ${rc2} -eq 0 && -n "${pid2}" && -n "${sig8_2}" ]] && _wait_dead "${pid2}" 5; then
  sleep 1
  note2="$(_checkpoint_note "${sig8_2}")"
  sentinel2="$(_sentinel "${sig8_2}")"
  mkdir -p "$(dirname "${note2}")"
  printf '# Turncap auto-checkpoint (recovered on next attempt)\n' > "${note2}"
  : > "${sentinel2}"
  ( cd "${ROOT}" && printf 'finished\n' >> platform/finished_work.py \
    && git add platform/finished_work.py \
       "docs/handoff/dispatch-${sig8_2}/CHECKPOINT.md" \
       "docs/handoff/dispatch-${sig8_2}/phase8-passed.flag" \
    && git commit -qm "real work — mission completed after resuming past the checkpoint" )
  sleep 1
  out2b="$(_dispatch "${m2}")"; rc2b=$?
  if [[ ${rc2b} -eq 2 ]] && grep -q 'duplicate_task_signature' <<<"${out2b}"; then
    pass "2: genuinely finished lane (sentinel present) stays deduped despite an earlier checkpoint"
  else
    fail "2: expected rc=2/duplicate_task_signature, got rc=${rc2b} out=${out2b}"
  fi
else
  fail "2: setup — first dispatch or process-death wait failed (rc=${rc2})"
fi

# ── 3. still RUNNING, even with a CHECKPOINT.md present -> signature never freed ────
# NOTE: `FAKE_SONNET_BEHAVIOR=long _dispatch ...` (assignment directly prefixing the
# function CALL) is required, not `FAKE_SONNET_BEHAVIOR=long out3="$(_dispatch ...)"` --
# the latter is two bare shell-variable assignments with no command word, so the fake
# launcher's subprocess never actually sees the env var and silently falls back to its
# "quick" (0.3s) default, making the lane genuinely dead by the second dispatch.
m3="task: turncap-long-running-lane $$ $(date +%s)"
out3="$( FAKE_SONNET_BEHAVIOR=long _dispatch "${m3}" )"; rc3=$?
pid3="$(_pid_from_output "${out3}")"; sig8_3="$(_sig8_from_output "${out3}")"
if [[ ${rc3} -eq 0 && -n "${pid3}" && -n "${sig8_3}" ]] && kill -0 "${pid3}" 2>/dev/null; then
  note3="$(_checkpoint_note "${sig8_3}")"
  mkdir -p "$(dirname "${note3}")"
  printf '# Turncap auto-checkpoint (stale, lane is actually still alive)\n' > "${note3}"
  out3b="$( FAKE_SONNET_BEHAVIOR=long _dispatch "${m3}" )"; rc3b=$?
  if [[ ${rc3b} -eq 2 ]] && grep -q 'duplicate_task_signature' <<<"${out3b}"; then
    pass "3: still-running lane's signature is never freed, even with a CHECKPOINT.md present"
  else
    fail "3: expected rc=2/duplicate_task_signature while alive, got rc=${rc3b} out=${out3b}"
  fi
  kill "${pid3}" 2>/dev/null || true
else
  fail "3: setup — first dispatch failed or fake process died too fast (rc=${rc3})"
fi

# ── 4. one-step rollback: CHECKPOINT_CUTOFF=0 restores item-8-only behavior (checkpoint
#      commit counts as ordinary evidence, blocks) ──────────────────────────────────
m4="task: turncap-cutoff-lane-rollback $$ $(date +%s)"
FAKE_SONNET_BEHAVIOR=quick out4="$( LEADV2_DISPATCH_CHECKPOINT_CUTOFF=0 _dispatch "${m4}" )"; rc4=$?
pid4="$(_pid_from_output "${out4}")"; sig8_4="$(_sig8_from_output "${out4}")"
if [[ ${rc4} -eq 0 && -n "${pid4}" && -n "${sig8_4}" ]] && _wait_dead "${pid4}" 5; then
  sleep 1
  note4="$(_checkpoint_note "${sig8_4}")"
  mkdir -p "$(dirname "${note4}")"
  printf '# Turncap auto-checkpoint\n' > "${note4}"
  ( cd "${ROOT}" && printf 'partial\n' >> platform/partial_work4.py \
    && git add platform/partial_work4.py "docs/handoff/dispatch-${sig8_4}/CHECKPOINT.md" \
    && git commit -qm "chore(leadv2): turncap checkpoint dispatch-${sig8_4}" )
  sleep 1
  out4b="$( LEADV2_DISPATCH_CHECKPOINT_CUTOFF=0 _dispatch "${m4}" )"; rc4b=$?
  if [[ ${rc4b} -eq 2 ]] && grep -q 'duplicate_task_signature' <<<"${out4b}"; then
    pass "4: LEADV2_DISPATCH_CHECKPOINT_CUTOFF=0 restores item-8-only behavior (blocks)"
  else
    fail "4: expected rc=2/duplicate_task_signature under the rollback flag, got rc=${rc4b} out=${out4b}"
  fi
else
  fail "4: setup — first dispatch or process-death wait failed (rc=${rc4})"
fi

printf '\n[TEST] %s passed, %s failed\n' "${PASS}" "${FAIL}"
if (( FAIL > 0 )); then
  printf '[TEST] Failures:\n'
  for e in "${ERRORS[@]}"; do printf '  - %s\n' "$e"; done
  exit 1
fi
exit 0
