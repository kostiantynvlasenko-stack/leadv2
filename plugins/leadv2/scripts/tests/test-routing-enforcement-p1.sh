#!/usr/bin/env bash
# Offline regression for ROUTER-DOOR-ENFORCE-01 Part 0.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCH_BIN="${SCRIPT_DIR}/../leadv2-dispatch-code.sh"
QUOTA_GATE_BIN="${SCRIPT_DIR}/../leadv2-glm-quota-gate.sh"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "${TMP_ROOT}"' EXIT
FAIL=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s -- %s\n' "$1" "$2"; FAIL=1; }

make_root() {
  local root="$1"
  mkdir -p "${root}/.claude/ref"
  cat > "${root}/.claude/ref/leadv2-routing.yaml" <<'YAML'
  glm_policy:
    sonnet_exceptions:
      - id: safety_gate_publish_payments
YAML
}

make_refusing_glm() {
  local path="$1"
  cat > "${path}" <<'SH'
#!/usr/bin/env bash
echo '[glm-quota-gate] LEADV2_DISPATCH_REFUSED: quota_gate' >&2
echo '[glm-quota-gate] REROUTE — GLM quota ≥ 80% on: weekly=82%.' >&2
exit 1
SH
  chmod +x "${path}"
}

make_peak_refusing_glm() {
  local path="$1"
  cat > "${path}" <<'SH'
#!/usr/bin/env bash
echo '[glm-quota-gate] LEADV2_DISPATCH_REFUSED: peak_hours' >&2
echo '[glm-quota-gate] PEAK HOURS — GLM-5.2 costs 3×.' >&2
exit 2
SH
  chmod +x "${path}"
}

make_live_glm() {
  local path="$1" delay="${2:-0}"
  cat > "${path}" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  bg) sleep ${delay}; echo 'glm-test-run' ;;
  status) exit 0 ;;
  *) exit 2 ;;
esac
SH
  chmod +x "${path}"
}

make_crashing_glm() {
  local path="$1"
  cat > "${path}" <<'SH'
#!/usr/bin/env bash
echo 'simulated launcher crash' >&2
exit 42
SH
  chmod +x "${path}"
}

make_failing_launcher() {
  local path="$1"
  cat > "${path}" <<'SH'
#!/usr/bin/env bash
echo 'simulated launcher crash' >&2
exit 42
SH
  chmod +x "${path}"
}

make_live_codex() {
  local path="$1"
  cat > "${path}" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  task) echo 'Dispatch started in the background as task-test-abc123.' ;;
  status) exit 0 ;;
  *) exit 2 ;;
esac
SH
  chmod +x "${path}"
}

make_quota_live() {
  local path="$1" five="$2" weekly="$3"
  cat > "${path}" <<SH
#!/usr/bin/env bash
printf '%s\\n' '{"status":"ok","five_hour":{"pct":${five},"reset_iso":"2026-07-28T12:00:00"},"weekly":{"pct":${weekly},"reset_iso":"2026-08-01T12:00:00"}}'
SH
  chmod +x "${path}"
}

make_quota_live "${TMP_ROOT}/quota-reroute-live.sh" 81 10
quota_reroute_out="$(LEADV2_QUOTA_LIVE="${TMP_ROOT}/quota-reroute-live.sh" GLM_SIMULATE_UTC_HOUR=1 \
  bash "${QUOTA_GATE_BIN}" 2>&1)"
quota_reroute_rc=$?
if [[ ${quota_reroute_rc} -eq 1 ]] && grep -q 'LEADV2_DISPATCH_REFUSED: quota_gate' <<<"${quota_reroute_out}"; then
  pass 'quota gate emits machine-readable reroute marker'
else
  fail 'quota gate reroute marker' "rc=${quota_reroute_rc} output=${quota_reroute_out}"
fi

make_quota_live "${TMP_ROOT}/quota-peak-live.sh" 10 10
quota_peak_out="$(LEADV2_QUOTA_LIVE="${TMP_ROOT}/quota-peak-live.sh" GLM_SIMULATE_UTC_HOUR=6 \
  bash "${QUOTA_GATE_BIN}" 2>&1)"
quota_peak_rc=$?
if [[ ${quota_peak_rc} -eq 2 ]] && grep -q 'LEADV2_DISPATCH_REFUSED: peak_hours' <<<"${quota_peak_out}"; then
  pass 'quota gate emits machine-readable peak marker'
else
  fail 'quota gate peak marker' "rc=${quota_peak_rc} output=${quota_peak_out}"
fi

make_root "${TMP_ROOT}/refusal-root"
make_refusing_glm "${TMP_ROOT}/refusing-glm.sh"
make_live_codex "${TMP_ROOT}/live-codex.sh"
refusal_out="$(CLAUDE_PROJECT_ROOT="${TMP_ROOT}/refusal-root" \
  LEADV2_DISPATCH_CACHE_DIR="${TMP_ROOT}/refusal-cache" \
  LEADV2_DISPATCH_GLM_BIN="${TMP_ROOT}/refusing-glm.sh" \
  LEADV2_DISPATCH_CODEX_BIN="${TMP_ROOT}/live-codex.sh" \
  bash "${DISPATCH_BIN}" 'quota refusal advances chain' 2>&1)"
refusal_rc=$?
if [[ ${refusal_rc} -eq 0 ]] \
  && grep -q 'reason=glm_refused_quota_gate' <<<"${refusal_out}" \
  && grep -q 'worker_spawned by=router model=codex' <<<"${refusal_out}" \
  && ! grep -q 'dispatch_rolled_back' <<<"${refusal_out}" \
  && ! grep -q 'spawn_failed by=router model=glm' <<<"${refusal_out}"; then
  pass 'quota refusal journals refusal and advances GLM -> Codex'
else
  fail 'quota refusal advances chain' "rc=${refusal_rc} output=${refusal_out}"
fi

make_root "${TMP_ROOT}/peak-root"
make_peak_refusing_glm "${TMP_ROOT}/peak-glm.sh"
peak_out="$(CLAUDE_PROJECT_ROOT="${TMP_ROOT}/peak-root" \
  LEADV2_DISPATCH_CACHE_DIR="${TMP_ROOT}/peak-cache" \
  LEADV2_DISPATCH_GLM_BIN="${TMP_ROOT}/peak-glm.sh" \
  LEADV2_DISPATCH_CODEX_BIN="${TMP_ROOT}/live-codex.sh" \
  bash "${DISPATCH_BIN}" 'peak refusal advances chain' 2>&1)"
peak_rc=$?
if [[ ${peak_rc} -eq 0 ]] \
  && grep -q 'reason=glm_refused_peak_hours' <<<"${peak_out}" \
  && grep -q 'worker_spawned by=router model=codex' <<<"${peak_out}" \
  && ! grep -q 'spawn_failed by=router model=glm' <<<"${peak_out}"; then
  pass 'peak-hours refusal journals refusal and advances GLM -> Codex'
else
  fail 'peak-hours refusal advances chain' "rc=${peak_rc} output=${peak_out}"
fi

make_root "${TMP_ROOT}/crash-root"
make_crashing_glm "${TMP_ROOT}/crashing-glm.sh"
make_failing_launcher "${TMP_ROOT}/failing-codex.sh"
make_failing_launcher "${TMP_ROOT}/failing-sonnet.sh"
crash_out="$(CLAUDE_PROJECT_ROOT="${TMP_ROOT}/crash-root" \
  LEADV2_DISPATCH_CACHE_DIR="${TMP_ROOT}/crash-cache" \
  LEADV2_DISPATCH_GLM_BIN="${TMP_ROOT}/crashing-glm.sh" \
  LEADV2_DISPATCH_CODEX_BIN="${TMP_ROOT}/failing-codex.sh" \
  LEADV2_DISPATCH_SUBSESSION_BIN="${TMP_ROOT}/failing-sonnet.sh" \
  bash "${DISPATCH_BIN}" 'launcher crash stays failure' 2>&1)"
crash_rc=$?
if [[ ${crash_rc} -eq 4 ]] \
  && grep -q 'spawn_failed by=router model=glm.*rc=42.*reason=launcher_nonzero_exit' <<<"${crash_out}" \
  && ! grep -q 'glm_refused_' <<<"${crash_out}" \
  && grep -q 'dispatch_rolled_back reason=all_arms_unavailable.*glm_failed_launcher' <<<"${crash_out}"; then
  pass 'launcher crash remains a failure'
else
  fail 'launcher crash remains failure' "rc=${crash_rc} output=${crash_out}"
fi

make_root "${TMP_ROOT}/dedup-root"
make_live_glm "${TMP_ROOT}/live-glm.sh"
dedup_first="$(CLAUDE_PROJECT_ROOT="${TMP_ROOT}/dedup-root" \
  LEADV2_DISPATCH_CACHE_DIR="${TMP_ROOT}/dedup-cache" \
  LEADV2_DISPATCH_GLM_BIN="${TMP_ROOT}/live-glm.sh" \
  bash "${DISPATCH_BIN}" 'one mission only once' 2>&1)"
dedup_first_rc=$?
dedup_second="$(CLAUDE_PROJECT_ROOT="${TMP_ROOT}/dedup-root" \
  LEADV2_DISPATCH_CACHE_DIR="${TMP_ROOT}/dedup-cache" \
  LEADV2_DISPATCH_GLM_BIN="${TMP_ROOT}/live-glm.sh" \
  bash "${DISPATCH_BIN}" 'one mission only once' 2>&1)"
dedup_second_rc=$?
if [[ ${dedup_first_rc} -eq 0 && ${dedup_second_rc} -eq 2 ]] \
  && grep -q 'dispatch_refused reason=duplicate_task_signature' <<<"${dedup_second}"; then
  pass 'duplicate dispatch is refused and journalled'
else
  fail 'duplicate dispatch refusal' "first_rc=${dedup_first_rc} second_rc=${dedup_second_rc} output=${dedup_first} ${dedup_second}"
fi

diff_hash='0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
review_first="$(CLAUDE_PROJECT_ROOT="${TMP_ROOT}/dedup-root" LEADV2_DISPATCH_CACHE_DIR="${TMP_ROOT}/review-cache" \
  bash "${DISPATCH_BIN}" record-review --diff-hash "${diff_hash}" --verdict PASS 2>&1)"
review_first_rc=$?
review_second="$(CLAUDE_PROJECT_ROOT="${TMP_ROOT}/dedup-root" LEADV2_DISPATCH_CACHE_DIR="${TMP_ROOT}/review-cache" \
  bash "${DISPATCH_BIN}" record-review --diff-hash "${diff_hash}" --verdict PASS 2>&1)"
review_second_rc=$?
if [[ ${review_first_rc} -eq 0 && ${review_second_rc} -eq 2 ]] \
  && grep -q 'review_refused reason=duplicate_diff_hash' <<<"${review_second}"; then
  pass 'record-review refuses duplicate diff hash'
else
  fail 'duplicate review refusal' "first_rc=${review_first_rc} second_rc=${review_second_rc} output=${review_first} ${review_second}"
fi

make_root "${TMP_ROOT}/race-root"
make_live_glm "${TMP_ROOT}/slow-glm.sh" 1
race_cache="${TMP_ROOT}/race-cache"
CLAUDE_PROJECT_ROOT="${TMP_ROOT}/race-root" LEADV2_DISPATCH_CACHE_DIR="${race_cache}" \
  LEADV2_DISPATCH_GLM_BIN="${TMP_ROOT}/slow-glm.sh" bash "${DISPATCH_BIN}" 'racing reservation' >"${TMP_ROOT}/race-one.out" 2>&1 &
race_one_pid=$!
sleep 0.1
CLAUDE_PROJECT_ROOT="${TMP_ROOT}/race-root" LEADV2_DISPATCH_CACHE_DIR="${race_cache}" \
  LEADV2_DISPATCH_GLM_BIN="${TMP_ROOT}/slow-glm.sh" bash "${DISPATCH_BIN}" 'racing reservation' >"${TMP_ROOT}/race-two.out" 2>&1 &
race_two_pid=$!
wait "${race_one_pid}"; race_one_rc=$?
wait "${race_two_pid}"; race_two_rc=$?
race_successes=0; [[ ${race_one_rc} -eq 0 ]] && race_successes=$((race_successes + 1)); [[ ${race_two_rc} -eq 0 ]] && race_successes=$((race_successes + 1))
race_refusals=0; [[ ${race_one_rc} -eq 2 ]] && race_refusals=$((race_refusals + 1)); [[ ${race_two_rc} -eq 2 ]] && race_refusals=$((race_refusals + 1))
if [[ ${race_successes} -eq 1 && ${race_refusals} -eq 1 ]] \
  && (grep -q 'dispatch_refused reason=duplicate_task_signature' "${TMP_ROOT}/race-one.out" || grep -q 'dispatch_refused reason=duplicate_task_signature' "${TMP_ROOT}/race-two.out"); then
  pass 'racing reserves admit exactly one dispatch'
else
  fail 'racing reserve exclusivity' "rcs=${race_one_rc},${race_two_rc} outputs=$(cat "${TMP_ROOT}/race-one.out") $(cat "${TMP_ROOT}/race-two.out")"
fi

[[ ${FAIL} -eq 0 ]]
