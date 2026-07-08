#!/usr/bin/env bash
# leadv2-coverage-gate.sh — compute new-code coverage after Build phase
# Usage: leadv2-coverage-gate.sh --start-sha <sha> --task-id <id> [--threshold <n>]
# Exit: 0 = passed, 1 = failed (coverage below threshold), 2 = error
set -euo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
readonly REPO_ROOT

# Source helpers for stack.yaml reader (no python3 required)
# shellcheck source=leadv2-helpers.sh
LEADV2_PROJECT_ROOT="$REPO_ROOT"
export LEADV2_PROJECT_ROOT
# shellcheck disable=SC1091
if ! source "${SCRIPT_DIR}/leadv2-helpers.sh" 2>/dev/null; then
  # FAIL-LOUD-FLAGS-01: helpers.sh failed to source -> the stack.yaml reader
  # is unavailable below, so this gate may silently fall back to wrong-stack
  # defaults (e.g. treating a non-Python repo as Python, or vice versa)
  # instead of the visible "no src_roots configured" skip it already has.
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/leadv2-strict.sh" 2>/dev/null || true
  # FIX ROUND (C1): guard against strict_or_warn being undefined (helper
  # missing/unreadable) — see leadv2-semantic-recall.sh for full rationale.
  if command -v strict_or_warn >/dev/null 2>&1; then
    if ! strict_or_warn "coverage-gate-helpers-source-fail" \
        "leadv2-helpers.sh failed to source -- stack.yaml reader unavailable, coverage gate may use wrong-language defaults"; then
      exit 2
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log()       { printf -- '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }
log_info()  { log "INFO:  $*"; }
log_error() { log "ERROR: $*"; }
log_warn()  { log "WARN:  $*"; }

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
START_SHA=""
TASK_ID=""
THRESHOLD=50
OUTPUT_DIR=""

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
usage() {
  printf -- 'Usage: %s --start-sha <sha> --task-id <id> [--threshold <n>]\n' "$(basename "$0")" >&2
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --start-sha)  START_SHA="${2:-}";   shift 2 ;;
    --task-id)    TASK_ID="${2:-}";     shift 2 ;;
    --threshold)  THRESHOLD="${2:-50}"; shift 2 ;;
    --output-dir) OUTPUT_DIR="${2:-}";  shift 2 ;;
    -h|--help)    usage ;;
    *) log_error "Unknown argument: $1"; usage ;;
  esac
done

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------
[[ -z "$START_SHA" ]] && { log_error "--start-sha is required"; usage; }
[[ -z "$TASK_ID"   ]] && { log_error "--task-id is required";   usage; }

# Refuse interactive when no tty (safety: don't block in CI/agent pipelines)
if [[ ! -t 0 && "${FORCE_INTERACTIVE:-}" != "true" ]]; then
  log_info "No TTY detected — running non-interactive"
fi

cd "$REPO_ROOT"

# Verify sha exists
if ! git cat-file -e "${START_SHA}^{commit}" 2>/dev/null; then
  log_error "Start SHA '${START_SHA}' not found in repo"
  exit 2
fi

# ---------------------------------------------------------------------------
# Output path
# ---------------------------------------------------------------------------
if [[ -z "$OUTPUT_DIR" ]]; then
  OUTPUT_DIR="${REPO_ROOT}/docs/handoff/${TASK_ID}"
fi
mkdir -p "$OUTPUT_DIR"
COVERAGE_YAML="${OUTPUT_DIR}/coverage.yaml"
COVERAGE_JSON_TMP="$(mktemp /tmp/leadv2-coverage-XXXXXX.json)"

# shellcheck disable=SC2329
cleanup() {
  rm -f "$COVERAGE_JSON_TMP"
}
trap 'cleanup' EXIT

# ---------------------------------------------------------------------------
# Step 1: Changed Python files (src_roots from stack.yaml, fallback: platform agent)
# ---------------------------------------------------------------------------

# Read stack.yaml overrides (helpers sourced above; fallback safe if source failed)
_LV2_SRC_ROOTS=""
if command -v _lv2_stack_list &>/dev/null; then
  _LV2_SRC_ROOTS="$(_lv2_stack_list 'src_roots' 'platform agent')"
else
  _LV2_SRC_ROOTS="platform agent"
fi
_LV2_LANG=""
if command -v _lv2_stack_scalar &>/dev/null; then
  _LV2_LANG="$(_lv2_stack_scalar 'lang' 'python')"
else
  _LV2_LANG="python"
fi

# Non-python repos without explicit src_roots get a visible skip (not silent pass)
if [[ "$_LV2_LANG" != "python" && "$_LV2_SRC_ROOTS" == "platform agent" ]]; then
  printf -- 'coverage gate: no src_roots configured for stack=%s, skipping\n' "$_LV2_LANG" >&2
  exit 0
fi

# Build grep alternation from src_roots (space-separated list)
_LV2_SRC_GREP_ALT=""
for _root in $_LV2_SRC_ROOTS; do
  if [[ -n "$_LV2_SRC_GREP_ALT" ]]; then
    _LV2_SRC_GREP_ALT="${_LV2_SRC_GREP_ALT}|${_root}"
  else
    _LV2_SRC_GREP_ALT="${_root}"
  fi
done
# Pattern: ^(platform|agent)/.*\.py$  (or whatever src_roots are configured)
_LV2_SRC_PATTERN="^(${_LV2_SRC_GREP_ALT})/.*\\.py\$"

log_info "Computing changed Python files since ${START_SHA} (src_roots: ${_LV2_SRC_ROOTS})"
CHANGED_PY_FILES="$(git diff --name-only "${START_SHA}..HEAD" | grep -E "${_LV2_SRC_PATTERN}" || true)"

if [[ -z "$CHANGED_PY_FILES" ]]; then
  log_info "No Python files changed in src_roots (${_LV2_SRC_ROOTS}) — gate skipped"
  cat > "$COVERAGE_YAML" <<YAML
new_code_lines: 0
covered_lines: 0
coverage_pct: 100.0
threshold: ${THRESHOLD}
passed: true
synthesis_attempted: false
founder_override: null
note: "gate skipped — no Python production files changed"
uncovered: []
YAML
  exit 0
fi

log_info "Changed Python files:"
printf -- '%s\n' "$CHANGED_PY_FILES" | while read -r f; do log_info "  $f"; done

# ---------------------------------------------------------------------------
# Step 2: Identify new/changed function names (for reporting)
# ---------------------------------------------------------------------------
UNCOVERED_JSON="[]"
NEW_FUNC_COUNT=0

while IFS= read -r pyfile; do
  [[ -z "$pyfile" ]] && continue
  funcs="$(git diff -U0 "${START_SHA}..HEAD" -- "$pyfile" 2>/dev/null \
    | grep -E '^\+[[:space:]]*(async[[:space:]]+)?def ' \
    | sed 's/^+[[:space:]]*//' \
    | sed 's/def \([a-zA-Z_][a-zA-Z0-9_]*\).*/\1/' \
    || true)"
  if [[ -n "$funcs" ]]; then
    while IFS= read -r fn; do
      [[ -z "$fn" ]] && continue
      NEW_FUNC_COUNT=$(( NEW_FUNC_COUNT + 1 ))
      entry="$(printf -- '{"file":"%s","function":"%s","lines":[]}' "$pyfile" "$fn")"
      UNCOVERED_JSON="$(printf -- '%s' "$UNCOVERED_JSON" | python3 -c "
import sys, json
arr = json.load(sys.stdin)
arr.append(json.loads('''${entry}'''))
print(json.dumps(arr))
" 2>/dev/null || printf -- '%s' "$UNCOVERED_JSON")"
    done <<< "$funcs"
  fi
done <<< "$CHANGED_PY_FILES"

log_info "New/changed functions detected: ${NEW_FUNC_COUNT}"

# ---------------------------------------------------------------------------
# Step 3: Build coverage module list
# ---------------------------------------------------------------------------
# Compute top-level source roots for --cov= flags
COV_ROOTS="$(printf -- '%s\n' "$CHANGED_PY_FILES" \
  | awk -F'/' '{print $1}' \
  | sort -u \
  | tr '\n' ',' \
  | sed 's|,$||')"

log_info "Coverage sources: ${COV_ROOTS}"

# ---------------------------------------------------------------------------
# Step 4: Run pytest coverage
# ---------------------------------------------------------------------------
COVERAGE_AVAILABLE=true

# Check if pytest-cov is available
if ! python3 -m pytest --co -q --co 2>&1 | grep -q "no tests ran\|collected" 2>/dev/null; then
  log_warn "Could not probe pytest collection — proceeding anyway"
fi

if ! python3 -c "import pytest_cov" 2>/dev/null; then
  log_warn "pytest-cov not installed — coverage gate cannot run"
  COVERAGE_AVAILABLE=false
fi

if [[ "$COVERAGE_AVAILABLE" == "true" ]]; then
  log_info "Running pytest coverage (scope: ${COV_ROOTS})"

  # Build --cov= flags from roots
  COV_FLAGS=""
  IFS=',' read -ra ROOTS <<< "$COV_ROOTS"
  for root in "${ROOTS[@]}"; do
    COV_FLAGS="${COV_FLAGS} --cov=${root}"
  done

  set +e
  # shellcheck disable=SC2086
  python3 -m pytest \
    ${COV_FLAGS} \
    --cov-report="json:${COVERAGE_JSON_TMP}" \
    --cov-report=term-missing \
    -q \
    tests/ 2>&1 | tail -30
  PYTEST_RC=$?
  set -e

  if [[ $PYTEST_RC -ne 0 && $PYTEST_RC -ne 1 ]]; then
    log_warn "pytest exited with code ${PYTEST_RC} — coverage data may be incomplete"
  fi
fi

# ---------------------------------------------------------------------------
# Step 5: Parse coverage and compute new-code pct
# ---------------------------------------------------------------------------
NEW_CODE_LINES=0
COVERED_LINES=0
COVERAGE_PCT=0

if [[ "$COVERAGE_AVAILABLE" == "true" && -s "$COVERAGE_JSON_TMP" ]]; then
  # Use python3 stdlib to parse coverage.json and compute coverage for changed files
  COVERAGE_RESULT="$(python3 - "$COVERAGE_JSON_TMP" "$CHANGED_PY_FILES" <<'PYEOF'
import sys, json, pathlib

cov_path = sys.argv[1]
changed_files_raw = sys.argv[2]

with open(cov_path) as f:
    cov = json.load(f)

changed = [p.strip() for p in changed_files_raw.splitlines() if p.strip()]

total_new = 0
total_covered = 0
uncovered_detail = []

files_data = cov.get("files", {})

for cf in changed:
    # coverage.json keys use relative paths from repo root
    entry = files_data.get(cf) or files_data.get("./" + cf)
    if entry is None:
        # Try matching by filename stem
        for k, v in files_data.items():
            if k.endswith(cf) or cf.endswith(k.lstrip("./")):
                entry = v
                break
    if entry is None:
        continue
    executed = set(entry.get("executed_lines", []))
    missing  = set(entry.get("missing_lines", []))
    all_lines = executed | missing
    total_new     += len(all_lines)
    total_covered += len(executed)
    if missing:
        uncovered_detail.append({"file": cf, "missing": sorted(missing)})

pct = (total_covered / total_new * 100) if total_new > 0 else 100.0
result = {
    "new_code_lines": total_new,
    "covered_lines": total_covered,
    "coverage_pct": round(pct, 1),
    "uncovered_detail": uncovered_detail,
}
print(json.dumps(result))
PYEOF
)"

  NEW_CODE_LINES="$(printf -- '%s' "$COVERAGE_RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['new_code_lines'])")"
  COVERED_LINES="$(printf -- '%s' "$COVERAGE_RESULT"  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['covered_lines'])")"
  COVERAGE_PCT="$(printf -- '%s' "$COVERAGE_RESULT"   | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['coverage_pct'])")"
  log_info "New code lines: ${NEW_CODE_LINES}, covered: ${COVERED_LINES}, pct: ${COVERAGE_PCT}%"
fi

# ---------------------------------------------------------------------------
# Step 6: Determine pass/fail
# ---------------------------------------------------------------------------
PASSED="false"
if [[ "$COVERAGE_AVAILABLE" == "false" ]]; then
  PASSED="true"
  log_warn "Coverage unavailable — gate passes with warning"
elif python3 -c "import sys; sys.exit(0 if float('${COVERAGE_PCT}') >= ${THRESHOLD} else 1)" 2>/dev/null; then
  PASSED="true"
  log_info "Coverage gate PASSED (${COVERAGE_PCT}% >= ${THRESHOLD}%)"
else
  log_warn "Coverage gate FAILED (${COVERAGE_PCT}% < ${THRESHOLD}%)"
fi

# ---------------------------------------------------------------------------
# Step 7: Write coverage.yaml
# ---------------------------------------------------------------------------
NOTE=""
[[ "$COVERAGE_AVAILABLE" == "false" ]] && NOTE="coverage-unavailable — pytest-cov not installed"

python3 - "$COVERAGE_YAML" "$NEW_CODE_LINES" "$COVERED_LINES" "$COVERAGE_PCT" \
        "$THRESHOLD" "$PASSED" "$NOTE" "$UNCOVERED_JSON" <<'PYEOF'
import sys, json, pathlib

out_path, new_lines, covered, pct, threshold, passed, note, uncovered_raw = sys.argv[1:]
uncovered = json.loads(uncovered_raw)

lines = [
    f"new_code_lines: {new_lines}",
    f"covered_lines: {covered}",
    f"coverage_pct: {float(pct):.1f}",
    f"threshold: {threshold}",
    f"passed: {'true' if passed == 'true' else 'false'}",
    "synthesis_attempted: false",
    "founder_override: null",
]
if note:
    lines.append(f'note: "{note}"')

lines.append("uncovered:")
if uncovered:
    for entry in uncovered:
        lines.append(f"  - file: {entry['file']}")
        lines.append(f"    function: {entry['function']}")
        lines.append(f"    lines: []")
else:
    lines.append("  []")

pathlib.Path(out_path).write_text("\n".join(lines) + "\n")
PYEOF

log_info "Coverage report written to ${COVERAGE_YAML}"

# ---------------------------------------------------------------------------
# Exit
# ---------------------------------------------------------------------------
if [[ "$PASSED" == "true" ]]; then
  exit 0
else
  exit 1
fi
