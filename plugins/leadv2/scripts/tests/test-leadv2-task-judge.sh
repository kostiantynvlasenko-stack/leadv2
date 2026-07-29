#!/usr/bin/env bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/leadv2-temp.sh"
# tests/test-leadv2-task-judge.sh — ROUTER-T5 (smart-routing-v2 spec §3 L2, §8 T5).
#
# Drives the REAL shipped leadv2-task-judge.sh against a temp PROJECT_ROOT with
# a stub `claude` binary (LEADV2_JUDGE_CLAUDE_BIN) so no real model call ever
# happens in CI. Covers every spec acceptance item verbatim:
#   - golden missions produce a valid TaskEstimate
#   - LEADV2_JUDGE_DISABLE=1 -> estimate_source=fallback, exit 0
#   - the prompt template greps clean of arm/model/provider/quota vocabulary
#   - fallback fires on a FORCED failure (stub exits 1), not just the disable flag
#   - a repeated mission signature hits the cache instead of the stub model
#
# Run: bash .claude/scripts/tests/test-leadv2-task-judge.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JUDGE_SH="${SCRIPT_DIR}/../leadv2-task-judge.sh"
PROMPT_TMPL="${SCRIPT_DIR}/../leadv2-task-judge-prompt.tmpl"

PASS=0
FAIL=0
ERRORS=()

log()  { printf -- '[TEST] %s\n' "$*"; }
pass() { PASS=$((PASS + 1)); log "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); ERRORS+=("FAIL: $1"); log "FAIL: $1"; }

# ── fixtures ─────────────────────────────────────────────────────────────────
_fixture_root() {
  local root; root="$(lv2_mktemp_dir "task-judge")"
  mkdir -p "${root}/.claude/leadv2-overrides"
  printf 'leadv2_dir: docs/leadv2\n' > "${root}/.claude/leadv2-overrides/state-paths.yaml"
  printf '%s' "${root}"
}

_write_mission() {
  local root="$1" name="$2" content="$3"
  local f="${root}/${name}.md"
  printf '%s' "${content}" > "${f}"
  printf '%s' "${f}"
}

# Stub `claude` binary — ignores its args, always emits a fixed valid envelope
# (fenced JSON inside .result, mirroring real `claude -p --output-format json`
# behavior observed live: the model wraps its answer in ```json fences even
# when told not to).
_stub_claude_ok() {
  local dir="$1" counter_file="$2"
  local bin="${dir}/claude"
  cat > "${bin}" <<STUB
#!/usr/bin/env bash
echo x >> "${counter_file}"
printf '%s\n' '{"is_error":false,"result":"\`\`\`json\n{\"complexity\":\"standard\",\"subsystems_touched\":3,\"needs_live_verification\":true,\"risk_class\":\"data\",\"duration_class\":\"medium\",\"work_kind\":\"build\"}\n\`\`\`","type":"result"}'
STUB
  chmod +x "${bin}"
  printf '%s' "${bin}"
}

_stub_claude_fail() {
  local dir="$1" counter_file="$2"
  local bin="${dir}/claude"
  cat > "${bin}" <<STUB
#!/usr/bin/env bash
echo x >> "${counter_file}"
exit 1
STUB
  chmod +x "${bin}"
  printf '%s' "${bin}"
}

_stub_claude_garbage() {
  local dir="$1" counter_file="$2"
  local bin="${dir}/claude"
  cat > "${bin}" <<STUB
#!/usr/bin/env bash
echo x >> "${counter_file}"
printf '%s\n' '{"is_error":false,"result":"not json at all"}'
STUB
  chmod +x "${bin}"
  printf '%s' "${bin}"
}

_stub_claude_hang() {
  local dir="$1" counter_file="$2"
  local bin="${dir}/claude"
  cat > "${bin}" <<STUB
#!/usr/bin/env bash
echo x >> "${counter_file}"
sleep 30
STUB
  chmod +x "${bin}"
  printf '%s' "${bin}"
}

_kv() { python3 -c "import json,sys; print(json.loads(sys.argv[1]).get(sys.argv[2],''))" "$1" "$2" 2>/dev/null; }

_validate_schema_or_fail() {
  local json="$1" label="$2"
  python3 -c "
import json, sys
est = json.loads(sys.argv[1])
ALLOWED = {
    'complexity': {'trivial','simple','standard','complex'},
    'risk_class': {'none','data','safety_publish_payments'},
    'duration_class': {'short','medium','long'},
    'work_kind': {'build','review','diagnose','docs'},
    'estimate_source': {'judge','fallback'},
}
REQUIRED = ('estimate_v','complexity','subsystems_touched','needs_live_verification',
            'risk_class','duration_class','work_kind','estimate_id','estimate_source')
ok = all(k in est for k in REQUIRED)
ok = ok and all(est[f] in allowed for f, allowed in ALLOWED.items())
ok = ok and isinstance(est['subsystems_touched'], int) and not isinstance(est['subsystems_touched'], bool)
ok = ok and 0 <= est['subsystems_touched'] <= 10
ok = ok and isinstance(est['needs_live_verification'], bool)
ok = ok and est['estimate_v'] == 1
sys.exit(0 if ok else 1)
" "${json}" 2>/dev/null
  if [[ $? -eq 0 ]]; then
    pass "${label}: schema valid"
  else
    fail "${label}: schema INVALID — ${json}"
  fi
}

# ── T1: golden missions produce a valid TaskEstimate (stub judge succeeds) ──
test_t1_golden_missions_valid() {
  local root; root="$(_fixture_root)"
  local counter="${root}/calls.txt"; : > "${counter}"
  local claude_bin; claude_bin="$(_stub_claude_ok "${root}" "${counter}")"

  local m1 m2 m3
  m1="$(_write_mission "${root}" "trivial" "Fix a typo in the README.")"
  m2="$(_write_mission "${root}" "build" "Implement a new async endpoint that reads from Supabase and writes to Qdrant, touching agent/ and platform/.")"
  m3="$(_write_mission "${root}" "risky" "Run a schema migration against the prod Supabase database and verify on the VPS.")"

  local m
  for m in "${m1}" "${m2}" "${m3}"; do
    local out
    out="$(LEADV2_JUDGE_CLAUDE_BIN="${claude_bin}" LEADV2_JUDGE_CACHE_DIR="${root}/cache" \
      bash "${JUDGE_SH}" --mission-file "${m}" 2>/dev/null)"
    local rc=$?
    if [[ ${rc} -ne 0 ]]; then
      fail "T1 ($(basename "${m}")): exit ${rc}, expected 0"
      continue
    fi
    _validate_schema_or_fail "${out}" "T1 ($(basename "${m}"))"
    local src; src="$(_kv "${out}" estimate_source)"
    [[ "${src}" == "judge" ]] && pass "T1 ($(basename "${m}")): estimate_source=judge" \
      || fail "T1 ($(basename "${m}")): expected estimate_source=judge, got ${src}"
  done
  rm -rf "${root}"
}

# ── T2: LEADV2_JUDGE_DISABLE=1 -> fallback, exit 0, model never invoked ────
test_t2_disable_flag() {
  local root; root="$(_fixture_root)"
  local counter="${root}/calls.txt"; : > "${counter}"
  local claude_bin; claude_bin="$(_stub_claude_ok "${root}" "${counter}")"
  local m; m="$(_write_mission "${root}" "m" "Any task text.")"

  local out rc=0
  out="$(LEADV2_JUDGE_DISABLE=1 LEADV2_JUDGE_CLAUDE_BIN="${claude_bin}" LEADV2_JUDGE_CACHE_DIR="${root}/cache" \
    bash "${JUDGE_SH}" --mission-file "${m}" 2>/dev/null)" || rc=$?
  local src; src="$(_kv "${out}" estimate_source)"

  if [[ ${rc} -eq 0 && "${src}" == "fallback" ]]; then
    pass "T2: LEADV2_JUDGE_DISABLE=1 -> estimate_source=fallback, exit 0"
  else
    fail "T2: expected exit 0 / fallback, got exit=${rc} src=${src}"
  fi
  local calls; calls="$(wc -l < "${counter}" | tr -d ' ')"
  [[ "${calls}" == "0" ]] && pass "T2: model never invoked (0 calls)" \
    || fail "T2: expected 0 model calls, got ${calls}"
  rm -rf "${root}"
}

# ── T3: prompt template lexicon grep — the invariant test ─────────────────
test_t3_lexicon_grep() {
  if [[ ! -f "${PROMPT_TMPL}" ]]; then
    fail "T3: prompt template missing at ${PROMPT_TMPL}"
    return
  fi
  if grep -iE '\b(arm|model|provider|quota)\b' "${PROMPT_TMPL}" >/dev/null; then
    fail "T3: prompt template contains banned arm/model/provider/quota vocabulary: $(grep -inE '\b(arm|model|provider|quota)\b' "${PROMPT_TMPL}")"
  else
    pass "T3: prompt template greps clean of arm/model/provider/quota"
  fi
}

# ── T4: FORCED failure (stub exits 1) -> fallback, not just the disable flag ─
test_t4_forced_failure_fallback() {
  local root; root="$(_fixture_root)"
  local counter="${root}/calls.txt"; : > "${counter}"
  local claude_bin; claude_bin="$(_stub_claude_fail "${root}" "${counter}")"
  local m; m="$(_write_mission "${root}" "m" "Any task text, judge will fail.")"

  local out rc=0
  out="$(LEADV2_JUDGE_CLAUDE_BIN="${claude_bin}" LEADV2_JUDGE_CACHE_DIR="${root}/cache" \
    bash "${JUDGE_SH}" --mission-file "${m}" 2>/dev/null)" || rc=$?
  local src; src="$(_kv "${out}" estimate_source)"
  if [[ ${rc} -eq 0 && "${src}" == "fallback" ]]; then
    pass "T4: stub exit 1 -> estimate_source=fallback, exit 0 (not disabled)"
  else
    fail "T4: expected exit 0 / fallback, got exit=${rc} src=${src}"
  fi
  local calls; calls="$(wc -l < "${counter}" | tr -d ' ')"
  [[ "${calls}" == "1" ]] && pass "T4: model WAS invoked once before falling back (proves this isn't the disable path)" \
    || fail "T4: expected exactly 1 model call, got ${calls}"
  rm -rf "${root}"
}

# ── T5: malformed/garbage judge output -> fallback ─────────────────────────
test_t5_garbage_output_fallback() {
  local root; root="$(_fixture_root)"
  local counter="${root}/calls.txt"; : > "${counter}"
  local claude_bin; claude_bin="$(_stub_claude_garbage "${root}" "${counter}")"
  local m; m="$(_write_mission "${root}" "m" "Any task text, judge returns garbage.")"

  local out rc=0
  out="$(LEADV2_JUDGE_CLAUDE_BIN="${claude_bin}" LEADV2_JUDGE_CACHE_DIR="${root}/cache" \
    bash "${JUDGE_SH}" --mission-file "${m}" 2>/dev/null)" || rc=$?
  local src; src="$(_kv "${out}" estimate_source)"
  if [[ ${rc} -eq 0 && "${src}" == "fallback" ]]; then
    pass "T5: malformed judge output -> estimate_source=fallback, exit 0"
  else
    fail "T5: expected exit 0 / fallback, got exit=${rc} src=${src}"
  fi
  rm -rf "${root}"
}

# ── T6: timeout -> fallback ─────────────────────────────────────────────────
test_t6_timeout_fallback() {
  local root; root="$(_fixture_root)"
  local counter="${root}/calls.txt"; : > "${counter}"
  local claude_bin; claude_bin="$(_stub_claude_hang "${root}" "${counter}")"
  local m; m="$(_write_mission "${root}" "m" "Any task text, judge hangs forever.")"

  local out rc=0
  out="$(LEADV2_JUDGE_CLAUDE_BIN="${claude_bin}" LEADV2_JUDGE_TIMEOUT_SEC=1 LEADV2_JUDGE_CACHE_DIR="${root}/cache" \
    bash "${JUDGE_SH}" --mission-file "${m}" 2>/dev/null)" || rc=$?
  local src; src="$(_kv "${out}" estimate_source)"
  if [[ ${rc} -eq 0 && "${src}" == "fallback" ]]; then
    pass "T6: judge timeout (1s vs 30s hang) -> estimate_source=fallback, exit 0"
  else
    fail "T6: expected exit 0 / fallback, got exit=${rc} src=${src}"
  fi
  rm -rf "${root}"
}

# ── T7: repeated mission signature hits the cache, not the model ──────────
test_t7_cache_hit() {
  local root; root="$(_fixture_root)"
  local counter="${root}/calls.txt"; : > "${counter}"
  local claude_bin; claude_bin="$(_stub_claude_ok "${root}" "${counter}")"
  local m; m="$(_write_mission "${root}" "m" "Same mission dispatched twice.")"

  local out1 out2
  out1="$(LEADV2_JUDGE_CLAUDE_BIN="${claude_bin}" LEADV2_JUDGE_CACHE_DIR="${root}/cache" \
    bash "${JUDGE_SH}" --mission-file "${m}" 2>/dev/null)"
  out2="$(LEADV2_JUDGE_CLAUDE_BIN="${claude_bin}" LEADV2_JUDGE_CACHE_DIR="${root}/cache" \
    bash "${JUDGE_SH}" --mission-file "${m}" 2>/dev/null)"

  local calls; calls="$(wc -l < "${counter}" | tr -d ' ')"
  if [[ "${calls}" == "1" ]]; then
    pass "T7: 2 dispatches of the same mission signature -> 1 model call (2nd hit cache)"
  else
    fail "T7: expected exactly 1 model call across 2 dispatches, got ${calls}"
  fi
  local id1 id2; id1="$(_kv "${out1}" estimate_id)"; id2="$(_kv "${out2}" estimate_id)"
  [[ -n "${id1}" && "${id1}" == "${id2}" ]] && pass "T7: estimate_id stable across cache hit (${id1})" \
    || fail "T7: estimate_id mismatch, got ${id1} vs ${id2}"
  rm -rf "${root}"
}

# ── T8: --class Light skips the judge entirely (R2 mitigation #3) ─────────
test_t8_light_skips_judge() {
  local root; root="$(_fixture_root)"
  local counter="${root}/calls.txt"; : > "${counter}"
  local claude_bin; claude_bin="$(_stub_claude_ok "${root}" "${counter}")"
  local m; m="$(_write_mission "${root}" "m" "Trivial single-line change.")"

  local out; out="$(LEADV2_JUDGE_CLAUDE_BIN="${claude_bin}" LEADV2_JUDGE_CACHE_DIR="${root}/cache" \
    bash "${JUDGE_SH}" --mission-file "${m}" --class Light 2>/dev/null)"
  local src; src="$(_kv "${out}" estimate_source)"
  local calls; calls="$(wc -l < "${counter}" | tr -d ' ')"
  if [[ "${src}" == "fallback" && "${calls}" == "0" ]]; then
    pass "T8: --class Light -> fallback with 0 model calls"
  else
    fail "T8: expected fallback/0 calls, got src=${src} calls=${calls}"
  fi
  rm -rf "${root}"
}

# ── T9: usage error — missing mission file exits non-zero, not fallback ───
test_t9_missing_mission_file_errors() {
  local root; root="$(_fixture_root)"
  local rc=0
  LEADV2_JUDGE_CACHE_DIR="${root}/cache" bash "${JUDGE_SH}" --mission-file "${root}/does-not-exist.md" >/dev/null 2>/dev/null || rc=$?
  [[ ${rc} -eq 2 ]] && pass "T9: missing --mission-file -> exit 2 (usage error, not fallback)" \
    || fail "T9: expected exit 2, got ${rc}"
  rm -rf "${root}"
}

# ── syntax guard ─────────────────────────────────────────────────────────────
test_syntax_check() {
  if bash -n "${JUDGE_SH}" 2>/dev/null; then
    pass "bash -n syntax OK on leadv2-task-judge.sh"
  else
    fail "bash -n syntax check failed"
  fi
}

test_t1_golden_missions_valid
test_t2_disable_flag
test_t3_lexicon_grep
test_t4_forced_failure_fallback
test_t5_garbage_output_fallback
test_t6_timeout_fallback
test_t7_cache_hit
test_t8_light_skips_judge
test_t9_missing_mission_file_errors
test_syntax_check

echo ""
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
if [[ "${FAIL}" -gt 0 ]]; then
  printf '%s\n' "${ERRORS[@]}"
  exit 1
fi
exit 0
