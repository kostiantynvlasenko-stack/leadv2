#!/usr/bin/env bash
# scripts/tests/test-nested-count-fix.sh — FIX-NESTED-COUNT-01
#
# Tests:
#   1. LEADV2_TASK_ID set → hook produces both global and per-task log entries;
#      scorecard-write counts nested_spawns=1.
#   2. LEADV2_TASK_ID unset → hook produces only global log entry; per-task
#      log is absent.
#
# Run: bash scripts/tests/test-nested-count-fix.sh
# Exit 0 = all pass; non-zero = failures found.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="${SCRIPT_DIR}/../../hooks/leadv2-routing-guard.sh"
SCORECARD_WRITE_SH="${SCRIPT_DIR}/../leadv2-scorecard-write.sh"
SCHEMA_FILE="${SCRIPT_DIR}/../../contracts/leadv2-scorecard.schema.json"

PASS=0
FAIL=0
ERRORS=()

log()  { printf -- '[TEST] %s\n' "$*"; }
pass() { PASS=$((PASS + 1)); log "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); ERRORS+=("FAIL: $1"); log "FAIL: $1"; }

_mktemp_dir() { mktemp -d /tmp/nested-count-test-XXXXXX; }

# Build minimal fake hook input JSON for a subagent (caller has agent_type).
# Spawns a general-purpose/haiku agent (policy ALLOW).
_make_input() {
  local cwd="$1"
  python3 -c "
import json, sys
print(json.dumps({
    \"agent_type\": \"developer\",
    \"tool_input\": {\"subagent_type\": \"explore\", \"model\": \"claude-haiku-4-5\"},
    \"cwd\": sys.argv[1]
}))
" "$cwd"
}

# ── Test 1: LEADV2_TASK_ID set → both logs written; scorecard counts 1 ─────

T1_DIR="$(_mktemp_dir)"
TASK_ID="TEST-FIX-01"
# Provide a minimal .git dir so repo-root detection works
mkdir -p "${T1_DIR}/.git"

INPUT="$(_make_input "$T1_DIR")"
LEADV2_TASK_ID="$TASK_ID" bash "$GUARD_SH" <<< "$INPUT" 2>/dev/null || true

GLOBAL_LOG="${T1_DIR}/docs/leadv2/nested-spawns.log"
TASK_LOG="${T1_DIR}/docs/leadv2/tasks/${TASK_ID}/nested-spawns.log"

if [[ -f "$GLOBAL_LOG" ]]; then
  pass "T1: global log exists"
else
  fail "T1: global log missing at ${GLOBAL_LOG}"
fi

if [[ -f "$TASK_LOG" ]]; then
  pass "T1: per-task log exists"
else
  fail "T1: per-task log missing at ${TASK_LOG}"
fi

GLOBAL_COUNT=0
TASK_COUNT=0
[[ -f "$GLOBAL_LOG" ]] && GLOBAL_COUNT="$(wc -l < "$GLOBAL_LOG" | tr -d ' ')"
[[ -f "$TASK_LOG" ]]  && TASK_COUNT="$(wc -l < "$TASK_LOG" | tr -d ' ')"

if [[ "$GLOBAL_COUNT" -ge 1 ]]; then
  pass "T1: global log has >= 1 entry (got ${GLOBAL_COUNT})"
else
  fail "T1: global log empty"
fi

if [[ "$TASK_COUNT" -ge 1 ]]; then
  pass "T1: per-task log has >= 1 entry (got ${TASK_COUNT})"
else
  fail "T1: per-task log empty"
fi

# Verify scorecard-write.sh counts nested_spawns=1 from per-task log
# We use --dry-run + LEADV2_SCORECARD_ON_CLOSE=1 to get the JSON row.
# We need a minimal context.yaml, closed.yaml; costs.yaml and schema must exist.
HANDOFF_DIR="${T1_DIR}/docs/handoff/${TASK_ID}"
mkdir -p "$HANDOFF_DIR"
mkdir -p "${T1_DIR}/docs/leadv2/closed"
cat > "${HANDOFF_DIR}/context.yaml" <<EOF
task_class: Standard
EOF
cat > "${T1_DIR}/docs/leadv2/closed/${TASK_ID}.yaml" <<EOF
outcome: success
closed_at: "2026-06-12T10:00:00Z"
EOF

if [[ -f "$SCHEMA_FILE" ]]; then
  ROW_JSON="$(LEADV2_PROJECT_ROOT="${T1_DIR}" LEADV2_SCORECARD_ON_CLOSE=1 \
    bash "$SCORECARD_WRITE_SH" --task-id "$TASK_ID" --dry-run 2>/dev/null)"
  NESTED="$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('nested_spawns','MISSING'))" "$ROW_JSON" 2>/dev/null || echo "PARSE_ERROR")"
  if [[ "$NESTED" == "1" ]]; then
    pass "T1: scorecard nested_spawns=1"
  else
    fail "T1: scorecard nested_spawns=${NESTED} (expected 1)"
  fi
else
  log "SKIP T1 scorecard: schema not found at ${SCHEMA_FILE}"
fi

rm -rf "$T1_DIR"

# ── Test 2: LEADV2_TASK_ID unset → only global log, per-task absent ─────────

T2_DIR="$(_mktemp_dir)"
mkdir -p "${T2_DIR}/.git"

INPUT2="$(_make_input "$T2_DIR")"
bash "$GUARD_SH" <<< "$INPUT2" 2>/dev/null || true

GLOBAL_LOG2="${T2_DIR}/docs/leadv2/nested-spawns.log"
TASK_LOG2_GLOB="${T2_DIR}/docs/leadv2/tasks"

if [[ -f "$GLOBAL_LOG2" ]]; then
  pass "T2: global log exists without LEADV2_TASK_ID"
else
  fail "T2: global log missing"
fi

if [[ -d "$TASK_LOG2_GLOB" ]]; then
  fail "T2: per-task tasks/ dir unexpectedly created when LEADV2_TASK_ID unset"
else
  pass "T2: per-task tasks/ dir absent (correct)"
fi

rm -rf "$T2_DIR"

# ── Summary ──────────────────────────────────────────────────────────────────

printf -- '\n[TEST SUMMARY] PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
for e in "${ERRORS[@]+"${ERRORS[@]}"}"; do
  printf -- '  %s\n' "$e"
done

[[ "$FAIL" -eq 0 ]]
