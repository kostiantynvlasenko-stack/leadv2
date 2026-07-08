#!/usr/bin/env bash
# test-glm-coder-529.sh — offline test harness for GLM-RELIABILITY-529-01
# (fix-round-4 RADICAL SIMPLIFY: overload_watchdog_loop and all its
# state/env/markers/tests are GONE. Surface under test is now: the single
# GLM_TIMEOUT watchdog, the two-sentinel contract (GLM_FALLBACK_TO_SONNET /
# GLM_PERMANENT_FAILURE), FIX2 (.result_is_error -> fallback), FIX3 (exit-0
# + coherent result success precedence), and PROVIDER_RETRY visibility).
#
# NO real network / no real z.ai / no real `claude` invocation: every scenario
# stubs the `claude` binary via the GLM_CLAUDE_BIN seam (fake executables
# below emit canned stream-json lines). Run-state (RUNS_DIR) and secrets
# (SECRETS_FILE) are also seam-overridden into an isolated tmp dir so tests
# never touch prod ~/.claude/cache/glm-runs or the real zai.env.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GLM_CODER="${SCRIPT_DIR}/../glm-coder.sh"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "${TMP_ROOT}"' EXIT

FAILURES=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s -- %s\n' "$1" "$2"; FAILURES=$((FAILURES + 1)); }

# ---------------------------------------------------------------------------
# case_bash_n
# ---------------------------------------------------------------------------
if bash -n "${GLM_CODER}"; then
  pass "case_bash_n"
else
  fail "case_bash_n" "bash -n reported a syntax error"
fi

# ---------------------------------------------------------------------------
# Shared fixtures — isolated secrets + run-state dirs. Prod
# ~/.claude/cache/glm-runs/ and ~/.claude/secrets/zai.env are NEVER touched.
# ---------------------------------------------------------------------------
SECRETS_DIR="${TMP_ROOT}/secrets"
mkdir -p "${SECRETS_DIR}"
FAKE_SECRETS="${SECRETS_DIR}/zai.env"
printf 'ZAI_AUTH_TOKEN=test-token-not-real\n' > "${FAKE_SECRETS}"
chmod 600 "${FAKE_SECRETS}"

RUNS_DIR="${TMP_ROOT}/runs"
mkdir -p "${RUNS_DIR}"

STUBS_DIR="${TMP_ROOT}/stubs"
mkdir -p "${STUBS_DIR}"

# fake-claude-hang: never emits anything and never exits on its own within
# the test window -- used for case_timeout_fallback.
cat > "${STUBS_DIR}/hang.sh" <<'EOF'
#!/usr/bin/env bash
sleep 60
exit 0
EOF

# fake-claude-happy: immediate success, coherent non-error result.
cat > "${STUBS_DIR}/happy.sh" <<'EOF'
#!/usr/bin/env bash
printf '{"type":"system","subtype":"init","model":"glm-5.2"}\n'
printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"/tmp/x"}}],"usage":{"input_tokens":10,"output_tokens":5}}}\n'
printf '{"type":"result","result":"done","is_error":false}\n'
exit 0
EOF

# fake-claude-clean-permanent-failure: ran to completion, produced a
# COHERENT/non-error result, but genuinely exited non-zero -- a real task
# failure, not a provider problem.
cat > "${STUBS_DIR}/clean-permanent-failure.sh" <<'EOF'
#!/usr/bin/env bash
printf '{"type":"system","subtype":"init","model":"glm-5.2"}\n'
printf '{"type":"result","result":"task failed: could not apply patch","is_error":false}\n'
exit 1
EOF

# fake-claude-error-result (FIX2): terminal result explicitly marked
# is_error:true, nonzero exit -- must route to fallback, not permanent.
cat > "${STUBS_DIR}/error-result.sh" <<'EOF'
#!/usr/bin/env bash
printf '{"type":"system","subtype":"init","model":"glm-5.2"}\n'
printf '{"type":"result","result":"overloaded, giving up","is_error":true}\n'
exit 1
EOF

# fake-claude-garbage: unparsable output, no init/result, non-zero exit.
cat > "${STUBS_DIR}/garbage.sh" <<'EOF'
#!/usr/bin/env bash
printf 'not json at all\n'
printf 'still garbage {{{\n'
exit 2
EOF

# fake-claude-provider-retry: emits several api_retry (overload) events,
# never resolves, never exits on its own within the test window -- proves
# (a) PROVIDER_RETRY visibility in progress.log, (b) the run is still bounded
# solely by GLM_TIMEOUT (no independent overload detection any more).
cat > "${STUBS_DIR}/provider-retry.sh" <<'EOF'
#!/usr/bin/env bash
i=0
while [[ $i -lt 30 ]]; do
  printf '{"type":"system","subtype":"api_retry","attempt":%d,"max_retries":300,"retry_delay_ms":100,"error_status":529,"error":"overloaded"}\n' "$i"
  i=$((i + 1))
  sleep 1
done
exit 1
EOF

# fake-claude-provider-retry-then-success (fix-round-5, closes the
# retries-then-SUCCESS gap): emits 2x api_retry (overload) events THEN
# resolves normally with a coherent, non-error result. The existing
# provider-retry.sh stub only covers retries-then-timeout; this proves
# PROVIDER_RETRY visibility does NOT interfere with a run that recovers on
# its own and completes.
cat > "${STUBS_DIR}/provider-retry-then-success.sh" <<'EOF'
#!/usr/bin/env bash
printf '{"type":"system","subtype":"api_retry","attempt":1,"max_retries":300,"retry_delay_ms":100,"error_status":529,"error":"overloaded"}\n'
sleep 0.2
printf '{"type":"system","subtype":"api_retry","attempt":2,"max_retries":300,"retry_delay_ms":100,"error_status":529,"error":"overloaded"}\n'
sleep 0.2
printf '{"type":"system","subtype":"init","model":"glm-5.2"}\n'
printf '{"type":"result","result":"done after retries","is_error":false}\n'
exit 0
EOF

chmod +x "${STUBS_DIR}"/*.sh

# Runs one `bg` scenario end-to-end and polls meta.yaml until it leaves
# "running". Prints space-separated fields: wall status exit_code
# fallback_sentinel_present permanent_sentinel_present timedout_marker
# provider_retry_line_count run_complete_present. Optional 4th/5th args
# override GLM_TIMEOUT (default 30s, kept generous) and max_wait_s
# (default 20s).
run_scenario() {
  local name="$1" stub="$2" max_wait_s="${3:-20}" timeout_s="${4:-30}"
  local cwd_dir="${TMP_ROOT}/repo-${name}"
  mkdir -p "${cwd_dir}"

  local run_id
  run_id="$(
    cd "${cwd_dir}" && \
    GLM_SECRETS_FILE="${FAKE_SECRETS}" \
    GLM_RUNS_DIR="${RUNS_DIR}" \
    GLM_CLAUDE_BIN="${STUBS_DIR}/${stub}" \
    GLM_TIMEOUT="${timeout_s}" \
    bash "${GLM_CODER}" bg "test prompt for ${name}"
  )"

  local start_ts end_ts waited=0
  start_ts="$(date +%s)"
  local run_dir="${RUNS_DIR}/${run_id}"
  local meta="${run_dir}/meta.yaml"
  while [[ "${waited}" -lt "${max_wait_s}" ]]; do
    if [[ -f "${meta}" ]]; then
      local st
      st="$(grep '^status:' "${meta}" | head -1 | cut -d: -f2 | tr -d ' ')"
      [[ "${st}" != "running" ]] && break
    fi
    sleep 1
    waited=$((waited + 1))
  done
  end_ts="$(date +%s)"

  local wall status exit_code fb_present=0 pf_present=0 to_marker=0 pr_count=0 rc_present=0
  wall=$(( end_ts - start_ts ))
  status="$(grep '^status:' "${meta}" 2>/dev/null | head -1 | cut -d: -f2 | tr -d ' ')"
  exit_code="$(grep '^exit_code:' "${meta}" 2>/dev/null | head -1 | cut -d: -f2 | tr -d ' ')"
  grep -q 'GLM_FALLBACK_TO_SONNET' "${run_dir}/progress.log" 2>/dev/null && fb_present=1
  grep -q 'GLM_PERMANENT_FAILURE' "${run_dir}/progress.log" 2>/dev/null && pf_present=1
  [[ -f "${run_dir}/.timed_out" ]] && to_marker=1
  pr_count="$(grep -c '^PROVIDER_RETRY' "${run_dir}/progress.log" 2>/dev/null || echo 0)"
  grep -q '^RUN_COMPLETE$' "${run_dir}/progress.log" 2>/dev/null && rc_present=1
  printf '%s %s %s %s %s %s %s %s\n' "${wall}" "${status:-unknown}" "${exit_code:-none}" "${fb_present}" "${pf_present}" "${to_marker}" "${pr_count}" "${rc_present}"
}

# ---------------------------------------------------------------------------
# case_timeout_fallback: run never completes within a (test-shrunk)
# GLM_TIMEOUT -> .timed_out written -> GLM_FALLBACK_TO_SONNET + exit 76.
# ---------------------------------------------------------------------------
read -r WALL1 STATUS1 EXIT1 FB1 PF1 TO1 PR1 RC1 <<< "$(run_scenario "timeout-fallback" "hang.sh" 20 3)"
printf 'case_timeout_fallback: wall=%ss status=%s exit=%s fallback=%s timed_out_marker=%s\n' "${WALL1}" "${STATUS1}" "${EXIT1}" "${FB1}" "${TO1}"
if [[ "${STATUS1}" == "failed" && "${EXIT1}" == "76" && "${FB1}" == "1" && "${TO1}" == "1" && "${WALL1}" -lt 15 ]]; then
  pass "case_timeout_fallback (wall=${WALL1}s, well under the old ~3600s/1h hang)"
else
  fail "case_timeout_fallback" "status=${STATUS1} exit=${EXIT1} fb=${FB1} to_marker=${TO1} wall=${WALL1}"
fi

# ---------------------------------------------------------------------------
# case_permanent_failure: coherent non-zero result -> GLM_PERMANENT_FAILURE
# + real exit code, NO fallback.
# ---------------------------------------------------------------------------
read -r WALL2 STATUS2 EXIT2 FB2 PF2 TO2 PR2 RC2 <<< "$(run_scenario "permanent-failure" "clean-permanent-failure.sh")"
if [[ "${STATUS2}" == "failed" && "${EXIT2}" == "1" && "${FB2}" == "0" && "${PF2}" == "1" ]]; then
  pass "case_permanent_failure (real exit=1 preserved, GLM_PERMANENT_FAILURE)"
else
  fail "case_permanent_failure" "status=${STATUS2} exit=${EXIT2} fb=${FB2} pf=${PF2} (want exit=1 fb=0 pf=1)"
fi

# ---------------------------------------------------------------------------
# case_success: exit-0 + valid non-error result -> success (FIX3
# precedence), no fallback, no timeout marker.
# ---------------------------------------------------------------------------
read -r WALL3 STATUS3 EXIT3 FB3 PF3 TO3 PR3 RC3 <<< "$(run_scenario "success" "happy.sh")"
if [[ "${STATUS3}" == "complete" && "${EXIT3}" == "0" && "${FB3}" == "0" && "${PF3}" == "0" && "${TO3}" == "0" ]]; then
  pass "case_success"
else
  fail "case_success" "status=${STATUS3} exit=${EXIT3} fb=${FB3} pf=${PF3} to=${TO3}"
fi

# ---------------------------------------------------------------------------
# case_result_is_error (FIX2): error terminal result -> fallback, not
# permanent.
# ---------------------------------------------------------------------------
read -r WALL4 STATUS4 EXIT4 FB4 PF4 TO4 PR4 RC4 <<< "$(run_scenario "result-is-error" "error-result.sh")"
if [[ "${STATUS4}" == "failed" && "${EXIT4}" == "76" && "${FB4}" == "1" && "${PF4}" == "0" ]]; then
  pass "case_result_is_error"
else
  fail "case_result_is_error" "status=${STATUS4} exit=${EXIT4} fb=${FB4} pf=${PF4} (want exit=76 fb=1 pf=0)"
fi

# ---------------------------------------------------------------------------
# case_garbage: no coherent result / unparsable stream -> fallback
# (ambiguous, fail-safe).
# ---------------------------------------------------------------------------
read -r WALL5 STATUS5 EXIT5 FB5 PF5 TO5 PR5 RC5 <<< "$(run_scenario "garbage" "garbage.sh")"
if [[ "${STATUS5}" == "failed" && "${EXIT5}" == "76" && "${FB5}" == "1" && "${PF5}" == "0" ]]; then
  pass "case_garbage"
else
  fail "case_garbage" "status=${STATUS5} exit=${EXIT5} fb=${FB5} pf=${PF5}"
fi

# ---------------------------------------------------------------------------
# case_provider_retry_visible: stub emits api_retry events -> progress.log
# contains PROVIDER_RETRY lines (proves the visibility KEEP item); run is
# still bounded solely by the (test-shrunk) GLM_TIMEOUT -> fallback, NOT an
# independent overload-detection trip (that mechanism no longer exists).
# ---------------------------------------------------------------------------
read -r WALL6 STATUS6 EXIT6 FB6 PF6 TO6 PR6 RC6 <<< "$(run_scenario "provider-retry-visible" "provider-retry.sh" 20 3)"
printf 'case_provider_retry_visible: wall=%ss status=%s exit=%s fallback=%s provider_retry_lines=%s\n' "${WALL6}" "${STATUS6}" "${EXIT6}" "${FB6}" "${PR6}"
if [[ "${STATUS6}" == "failed" && "${EXIT6}" == "76" && "${FB6}" == "1" && "${TO6}" == "1" && "${PR6}" -ge 1 ]]; then
  pass "case_provider_retry_visible (${PR6} PROVIDER_RETRY lines logged, bounded by GLM_TIMEOUT at wall=${WALL6}s)"
else
  fail "case_provider_retry_visible" "status=${STATUS6} exit=${EXIT6} fb=${FB6} to_marker=${TO6} provider_retry_lines=${PR6} (want failed/76/fb=1/to=1/pr>=1)"
fi

# ---------------------------------------------------------------------------
# case_provider_retry_then_success (fix-round-5): stub emits 2x api_retry
# events THEN exits 0 with a coherent, non-error result. Closes the
# retries-then-SUCCESS gap that case_provider_retry_visible (retries-then-
# TIMEOUT) doesn't cover -- proves PROVIDER_RETRY visibility never
# interferes with a run that recovers and completes on its own.
# ---------------------------------------------------------------------------
read -r WALL7 STATUS7 EXIT7 FB7 PF7 TO7 PR7 RC7 <<< "$(run_scenario "provider-retry-then-success" "provider-retry-then-success.sh")"
printf 'case_provider_retry_then_success: wall=%ss status=%s exit=%s fallback=%s provider_retry_lines=%s run_complete=%s\n' "${WALL7}" "${STATUS7}" "${EXIT7}" "${FB7}" "${PR7}" "${RC7}"
if [[ "${STATUS7}" == "complete" && "${EXIT7}" == "0" && "${FB7}" == "0" && "${TO7}" == "0" && "${PR7}" -ge 2 && "${RC7}" == "1" ]]; then
  pass "case_provider_retry_then_success (${PR7} PROVIDER_RETRY lines + RUN_COMPLETE, no fallback)"
else
  fail "case_provider_retry_then_success" "status=${STATUS7} exit=${EXIT7} fb=${FB7} to_marker=${TO7} provider_retry_lines=${PR7} run_complete=${RC7} (want complete/0/fb=0/to=0/pr>=2/rc=1)"
fi

# ---------------------------------------------------------------------------
# case_secrets_and_runsdir_seam: confirm the GLM_SECRETS_FILE/GLM_RUNS_DIR
# test seams actually isolated every run above into TMP_ROOT, and prod
# ~/.claude/cache/glm-runs/ was never touched by this suite.
# ---------------------------------------------------------------------------
PROD_RUNS_DIR="${HOME}/.claude/cache/glm-runs"
ALL_UNDER_TMP=1
for d in "${RUNS_DIR}"/*/; do
  [[ -d "${d}" ]] || continue
  case "${d}" in
    "${TMP_ROOT}"/*) ;;
    *) ALL_UNDER_TMP=0 ;;
  esac
done
PROD_TOUCHED=0
if [[ -d "${PROD_RUNS_DIR}" ]]; then
  # None of our run_ids should ever appear under prod -- they were created
  # entirely under GLM_RUNS_DIR=TMP_ROOT/runs via the seam.
  for d in "${RUNS_DIR}"/*/; do
    [[ -d "${d}" ]] || continue
    rid="$(basename "${d}")"
    [[ -d "${PROD_RUNS_DIR}/${rid}" ]] && PROD_TOUCHED=1
  done
fi
if [[ "${ALL_UNDER_TMP}" -eq 1 && "${PROD_TOUCHED}" -eq 0 ]]; then
  pass "case_secrets_and_runsdir_seam (all run dirs isolated under TMP_ROOT, prod glm-runs untouched)"
else
  fail "case_secrets_and_runsdir_seam" "all_under_tmp=${ALL_UNDER_TMP} prod_touched=${PROD_TOUCHED}"
fi

echo "---"
TOTAL=9
if [[ "${FAILURES}" -eq 0 ]]; then
  echo "ALL PASS (${TOTAL}/${TOTAL})"
  exit 0
else
  echo "${FAILURES} FAILURE(S) out of ${TOTAL}"
  exit 1
fi
