#!/usr/bin/env bash
# leadv2-eval-harness.sh -- Golden fixture regression gate for leadv2.
#
# Runs all golden fixtures under LEADV2_DRY_RUN=1.
# Exits 1 if any golden fixture fails; prints fixture id + failed assertion.
# Called by shadow-apply.sh before any promote/revert (D7).
#
# Usage:
#   bash leadv2-eval-harness.sh [--fixture <id>] [--golden-dir <path>] [--verbose]
#
# Exit codes:
#   0 = all fixtures passed
#   1 = one or more fixture assertions failed
#   2 = argument error
#   4 = harness disabled (LEADV2_EVAL_HARNESS_ON=0) -- backward-compat no-op
#
# Opt-in guard: LEADV2_EVAL_HARNESS_ON (default 0 = disabled).
# Absent flag = byte-identical existing flow (D6).
#
# Stub loader: reads pre-recorded stubs from golden/stubs/<task_id>/
# to prevent live LLM calls (resolves C-high-4).

set -euo pipefail

# ── guard: opt-in only (D6) ──────────────────────────────────────────────────
if [[ "${LEADV2_EVAL_HARNESS_ON:-0}" != "1" ]]; then
  exit 4
fi

# ── path resolution (D1/R6: LEADV2_PROJECT_ROOT, never script-relative) ──────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LEADV2_PROJECT_ROOT="${LEADV2_PROJECT_ROOT:-${CLAUDE_PROJECT_DIR:-${PROJECT_ROOT:-$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || pwd)}}}"
export LEADV2_PROJECT_ROOT

# ── source helpers (provides leadv2_dry_run_guard) ────────────────────────────
# shellcheck source=./leadv2-helpers.sh
if [[ -f "$SCRIPT_DIR/leadv2-helpers.sh" ]]; then
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/leadv2-helpers.sh"
fi

log()       { printf -- '[eval-harness] %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
log_error() { log "ERROR: $*"; }
log_ok()    { log "OK: $*"; }

# ── defaults ──────────────────────────────────────────────────────────────────
FIXTURE_FILTER=""
VERBOSE=0
GOLDEN_DIR="${LEADV2_PROJECT_ROOT}/.claude/leadv2-overrides/golden"

# ── argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --fixture)     FIXTURE_FILTER="$2"; shift 2 ;;
    --golden-dir)  GOLDEN_DIR="$2";    shift 2 ;;
    --verbose|-v)  VERBOSE=1;          shift   ;;
    -h|--help)
      printf -- 'Usage: %s [--fixture <id>] [--golden-dir <path>] [--verbose]\n' \
        "$(basename "$0")" >&2
      exit 0
      ;;
    *)
      log_error "unknown argument: $1"
      exit 2
      ;;
  esac
done

# ── validate golden dir ───────────────────────────────────────────────────────
if [[ ! -d "$GOLDEN_DIR" ]]; then
  log_error "golden dir not found: $GOLDEN_DIR"
  exit 1
fi

# ── force DRY_RUN=1 for all fixture replay ────────────────────────────────────
export LEADV2_DRY_RUN=1

# ── collect fixtures ──────────────────────────────────────────────────────────
FIXTURES=()
while IFS= read -r -d '' f; do
  fname="$(basename "$f" .json)"
  if [[ -n "$FIXTURE_FILTER" && "$fname" != "$FIXTURE_FILTER" ]]; then
    continue
  fi
  FIXTURES+=("$f")
done < <(find "$GOLDEN_DIR" -maxdepth 1 -name "*.json" -print0 2>/dev/null | sort -z)

if [[ ${#FIXTURES[@]} -eq 0 ]]; then
  log "no fixtures found in $GOLDEN_DIR"
  exit 0
fi

log "found ${#FIXTURES[@]} fixture(s) in $GOLDEN_DIR"

# ── Python assertion engine ───────────────────────────────────────────────────
HARNESS_PY="${LEADV2_PROJECT_ROOT}/.claude/leadv2-overrides/golden/eval_engine.py"

if [[ ! -f "$HARNESS_PY" ]]; then
  log_error "eval engine not found: $HARNESS_PY"
  exit 1
fi

# ── run fixtures ──────────────────────────────────────────────────────────────
PASS_COUNT=0
FAIL_COUNT=0
FAIL_FIXTURES=()

VERBOSE_FLAG=""
[[ "$VERBOSE" == "1" ]] && VERBOSE_FLAG="--verbose"

for fixture_file in "${FIXTURES[@]}"; do
  fixture_id="$(basename "$fixture_file" .json)"
  log "running fixture: $fixture_id"

  set +e
  output=$(python3 "$HARNESS_PY" \
    "$fixture_file" \
    --golden-dir "$GOLDEN_DIR" \
    --project-root "$LEADV2_PROJECT_ROOT" \
    ${VERBOSE_FLAG:+"$VERBOSE_FLAG"} 2>&1)
  rc=$?
  set -e

  if [[ $rc -ne 0 ]]; then
    log_error "fixture FAILED: $fixture_id"
    while IFS= read -r line; do
      [[ "$line" == FAIL* ]] && printf -- '  %s\n' "$line" >&2
    done <<< "$output"
    FAIL_COUNT=$(( FAIL_COUNT + 1 ))
    FAIL_FIXTURES+=("$fixture_id")
    # Canary failure stops harness immediately
    if python3 -c "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get('is_canary') else 1)" "$fixture_file" 2>/dev/null; then
      log_error "CANARY FIXTURE FAILED: $fixture_id -- stopping harness"
      printf -- '\nFAILED FIXTURES (%d):\n' "$FAIL_COUNT" >&2
      printf -- '  - %s\n' "${FAIL_FIXTURES[@]}" >&2
      exit 1
    fi
    continue
  fi

  PASS_COUNT=$(( PASS_COUNT + 1 ))
  log_ok "fixture passed: $fixture_id"
done

# ── summary ───────────────────────────────────────────────────────────────────
TOTAL=$(( PASS_COUNT + FAIL_COUNT ))
log "SUMMARY: $PASS_COUNT/$TOTAL fixtures passed"

if [[ $FAIL_COUNT -gt 0 ]]; then
  log_error "$FAIL_COUNT fixture(s) FAILED:"
  for fid in "${FAIL_FIXTURES[@]}"; do
    printf -- '  - %s\n' "$fid" >&2
  done
  exit 1
fi

exit 0
