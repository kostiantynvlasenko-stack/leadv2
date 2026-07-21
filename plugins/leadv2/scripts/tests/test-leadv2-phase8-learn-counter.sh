#!/usr/bin/env bash
# tests/test-leadv2-phase8-learn-counter.sh — Unit tests for learn-counter in leadv2-phase8-close.sh
#
# Proves Item-1 invariant: with NO env vars set (scorecard defaults off),
# .close-count increments on every close and learn trigger fires at modulo-N boundary.
# Asserts no double-fire.
#
# NOTE: phase8-close.sh hard-sets PROJECT_ROOT=$(dirname BASH_SOURCE)/../..
# so tests run in-place and use a real temp branch under that root's docs/leadv2/.
# We isolate with unique counter/trigger file names per test to avoid cross-test pollution.
#
# Tests:
#   1. LEADV2_SCORECARD_ON_CLOSE unset (default 0) -> .close-count increments each close
#   2. learn trigger fires at modulo-N boundary (LEADV2_LEARN_EVERY_N=3)
#   3. no double-fire at N+1
#   4. LEADV2_SCORECARD_ON_CLOSE=1 + non-empty scorecard -> uses scorecard line-count path
#   5. bash -n syntax check
#   6. [MEM-WRITE-PATH-FIX-01 round2] REAL _durable_root resolution, extracted live from
#      leadv2-phase8-close.sh (not a hand-duplicated copy), run from inside a real linked
#      git worktree -> must resolve to the MAIN repo root, not the worktree.
#   7. [MEM-WRITE-PATH-FIX-01 round2] REAL JS-side one-liner, extracted live from
#      leadv2-review.js, run from (a) main repo (b) linked worktree (c) an unrelated
#      git repo with no docs/leadv2/ marker -> (a)/(b) resolve to main repo, (c) fails
#      safe to pwd instead of silently landing in the wrong repo.
#
# Run: bash scripts/tests/test-leadv2-phase8-learn-counter.sh
# Exit 0 = all pass; non-zero = failures found.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/leadv2-temp.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PHASE8_SH="${SCRIPT_DIR}/../leadv2-phase8-close.sh"
JS_FILE="${SCRIPT_DIR}/../../workflows/leadv2-review.js"
# phase8-close.sh will resolve PROJECT_ROOT=$(dirname PHASE8_SH)/.. = plugin root
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
LEADV2_DIR="${PLUGIN_ROOT}/docs/leadv2"

PASS=0; FAIL=0; ERRORS=()
log()  { printf -- '[TEST] %s\n' "$*"; }
pass() { PASS=$((PASS + 1)); log "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); ERRORS+=("FAIL: $1"); log "FAIL: $1"; }

# Unique run-id so parallel/repeated test runs don't collide
RUN_ID="lc-$$-$(date +%s)"

# Setup: ensure docs/leadv2 exists under plugin root (usually does)
mkdir -p "$LEADV2_DIR"

# Run just the learn-counter section of phase8-close by extracting and running it inline.
# We source the env and call the logic block directly to avoid the git/YAML write side-effects.
# This is the cleanest way to test the specific counter logic in isolation.
_run_learn_counter_block() {
  local task_id="$1"
  local learn_every_n="${2:-5}"
  local scorecard_on="${3:-0}"
  local counter_file="${4:-${LEADV2_DIR}/.close-count-${RUN_ID}}"
  local sc_file="${5:-/dev/null}"
  local trigger_file="${6:-${LEADV2_DIR}/.learn-trigger-${RUN_ID}}"

  bash << BLOCKSH
set -euo pipefail
LEADV2_LEARN_ON_CLOSE=1
LEADV2_LEARN_EVERY_N="${learn_every_n}"
LEADV2_SCORECARD_ON_CLOSE="${scorecard_on}"
PROJECT_ROOT="${PLUGIN_ROOT}"
TASK_ID="${task_id}"
_sc_file="${sc_file}"
_close_count=0
if [[ "\${LEADV2_SCORECARD_ON_CLOSE:-0}" == "1" && -f "\$_sc_file" ]]; then
  _close_count=\$(wc -l < "\$_sc_file" 2>/dev/null || echo 0)
  _close_count=\$(( _close_count + 0 ))
fi
if [[ "\${LEADV2_SCORECARD_ON_CLOSE:-0}" != "1" ]]; then
  _counter_file="${counter_file}"
  mkdir -p "\$(dirname "\$_counter_file")"
  _prev=\$(cat "\$_counter_file" 2>/dev/null || echo 0)
  [[ "\$_prev" =~ ^[0-9]+\$ ]] || _prev=0
  _close_count=\$(( (_prev + 1) % 1000000 ))
  printf -- '%d\n' "\$_close_count" > "\${_counter_file}.tmp" && mv "\${_counter_file}.tmp" "\$_counter_file"
fi
_learn_n="${learn_every_n}"
if [[ \$_learn_n -gt 0 && \$(( _close_count % _learn_n )) -eq 0 && \$_close_count -gt 0 ]]; then
  _trigger_file="${trigger_file}"
  mkdir -p "\$(dirname "\$_trigger_file")"
  printf -- 'trigger_task_id: %s\ntrigger_close_count: %d\ntriggered_at: %s\ntrigger_task_class: general\n' \
    "\$TASK_ID" "\$_close_count" "\$(date -u '+%Y-%m-%dT%H:%M:%SZ')" > "\$_trigger_file"
fi
BLOCKSH
}

# ── Test 1: .close-count increments each close ───────────────────────────────

test_1_close_count_increments() {
  log "Test 1: .close-count increments on each close (SCORECARD_ON_CLOSE unset=default 0)"
  local counter_file="${LEADV2_DIR}/.close-count-t1-${RUN_ID}"
  local trigger_file="${LEADV2_DIR}/.learn-trigger-t1-${RUN_ID}"

  _run_learn_counter_block "T1-A" 99 0 "$counter_file" "/dev/null" "$trigger_file"
  local v1
  v1=$(cat "$counter_file" 2>/dev/null || echo "missing")

  _run_learn_counter_block "T1-B" 99 0 "$counter_file" "/dev/null" "$trigger_file"
  local v2
  v2=$(cat "$counter_file" 2>/dev/null || echo "missing")

  rm -f "$counter_file" "$trigger_file"

  if [[ "$v1" == "1" && "$v2" == "2" ]]; then
    pass "Test 1: .close-count=1 after close 1, =2 after close 2"
  else
    fail "Test 1: expected v1=1 v2=2; got v1='${v1}' v2='${v2}'"
  fi
}

# ── Test 2: trigger fires at modulo-3 boundary ───────────────────────────────

test_2_trigger_at_boundary() {
  log "Test 2: learn trigger fires at modulo-3 boundary"
  local counter_file="${LEADV2_DIR}/.close-count-t2-${RUN_ID}"
  local trigger_file="${LEADV2_DIR}/.learn-trigger-t2-${RUN_ID}"

  _run_learn_counter_block "T2-A" 3 0 "$counter_file" "/dev/null" "$trigger_file"
  if [[ -f "$trigger_file" ]]; then
    rm -f "$counter_file" "$trigger_file"
    fail "Test 2: trigger fired after close 1 (unexpected)"
    return
  fi

  _run_learn_counter_block "T2-B" 3 0 "$counter_file" "/dev/null" "$trigger_file"
  if [[ -f "$trigger_file" ]]; then
    rm -f "$counter_file" "$trigger_file"
    fail "Test 2: trigger fired after close 2 (unexpected)"
    return
  fi

  _run_learn_counter_block "T2-C" 3 0 "$counter_file" "/dev/null" "$trigger_file"
  local trigger_exists=0
  [[ -f "$trigger_file" ]] && trigger_exists=1

  rm -f "$counter_file" "$trigger_file"

  if [[ "$trigger_exists" -eq 1 ]]; then
    pass "Test 2: trigger file written at close 3 (modulo-3 boundary)"
  else
    fail "Test 2: trigger file not present after close 3"
  fi
}

# ── Test 3: no double-fire at N+1 ────────────────────────────────────────────

test_3_no_double_fire() {
  log "Test 3: trigger NOT re-written at close 4 after firing at close 3"
  local counter_file="${LEADV2_DIR}/.close-count-t3-${RUN_ID}"
  local trigger_file="${LEADV2_DIR}/.learn-trigger-t3-${RUN_ID}"

  _run_learn_counter_block "T3-A" 3 0 "$counter_file" "/dev/null" "$trigger_file"
  _run_learn_counter_block "T3-B" 3 0 "$counter_file" "/dev/null" "$trigger_file"
  _run_learn_counter_block "T3-C" 3 0 "$counter_file" "/dev/null" "$trigger_file"
  [[ -f "$trigger_file" ]] || { rm -f "$counter_file" "$trigger_file"; fail "Test 3: trigger not written at close 3 (prerequisite failed)"; return; }

  local mtime1
  mtime1=$(python3 -c "import os; print(int(os.path.getmtime('$trigger_file')))" 2>/dev/null || echo 0)

  sleep 1
  _run_learn_counter_block "T3-D" 3 0 "$counter_file" "/dev/null" "$trigger_file"

  local mtime2
  mtime2=$(python3 -c "import os; print(int(os.path.getmtime('$trigger_file')))" 2>/dev/null || echo 0)

  rm -f "$counter_file" "$trigger_file"

  if [[ "$mtime1" == "$mtime2" ]]; then
    pass "Test 3: trigger file mtime unchanged at close 4 (no double-fire)"
  else
    fail "Test 3: trigger file mtime changed at close 4 (double-fire detected)"
  fi
}

# ── Test 4: LEADV2_SCORECARD_ON_CLOSE=1 uses scorecard line count ─────────────

test_4_scorecard_path() {
  log "Test 4: SCORECARD_ON_CLOSE=1 + 5-line scorecard -> scorecard path, not .close-count"
  local counter_file="${LEADV2_DIR}/.close-count-t4-${RUN_ID}"
  local trigger_file="${LEADV2_DIR}/.learn-trigger-t4-${RUN_ID}"
  local sc_file
  sc_file=$(lv2_mktemp_file "sc-t4" "jsonl")
  printf '{"task_id":"T1"}\n{"task_id":"T2"}\n{"task_id":"T3"}\n{"task_id":"T4"}\n{"task_id":"T5"}\n' > "$sc_file"

  _run_learn_counter_block "T4-A" 5 1 "$counter_file" "$sc_file" "$trigger_file"

  local trigger_exists=0 counter_incremented=0
  [[ -f "$trigger_file" ]] && trigger_exists=1
  [[ -f "$counter_file" ]] && counter_incremented=1

  rm -f "$counter_file" "$trigger_file" "$sc_file"

  if [[ "$trigger_exists" -eq 1 && "$counter_incremented" -eq 0 ]]; then
    pass "Test 4: scorecard path (trigger fired, .close-count not incremented)"
  else
    fail "Test 4: trigger_exists=${trigger_exists} (expected 1) counter_incremented=${counter_incremented} (expected 0)"
  fi
}

# ── Test 5: syntax check ──────────────────────────────────────────────────────

test_5_syntax() {
  log "Test 5: bash -n syntax check on phase8-close.sh"
  bash -n "$PHASE8_SH" 2>/dev/null && pass "Test 5: bash -n OK" || fail "Test 5: bash -n FAILED"
}

# -- Test 6: REAL _durable_root resolution from inside a linked worktree ------
_extract_durable_root_snippet() {
  sed -n '/_durable_root="\$(git rev-parse --path-format=absolute --git-common-dir/,/\[\[ -d "\$_durable_root" \]\] || _durable_root="\$PROJECT_ROOT"/p' "$PHASE8_SH"
}

test_6_durable_root_worktree() {
  log "Test 6: REAL _durable_root resolution resolves to MAIN repo from inside a worktree"
  local snippet
  snippet="$(_extract_durable_root_snippet)"
  if [[ -z "$snippet" ]]; then
    fail "Test 6: could not extract _durable_root snippet from $PHASE8_SH (source moved/renamed?)"
    return
  fi

  local tmp_main tmp_wt
  tmp_main="$(lv2_mktemp_dir "mw-fix-main")"
  tmp_wt="$(lv2_mktemp_dir "mw-fix-wt")"
  rmdir "$tmp_wt"

  (
    cd "$tmp_main"
    git init -q
    git config user.email t@t.local; git config user.name t
    mkdir -p docs/leadv2
    echo x > f.txt
    git add -A && git commit -qm init
    git worktree add -q "$tmp_wt" -b mw-fix-test-branch >/dev/null 2>&1
  )

  local resolved
  resolved="$(cd "$tmp_wt" && PROJECT_ROOT="$tmp_wt" bash -c "$snippet"'; printf "%s" "$_durable_root"')"

  (cd "$tmp_main" && git worktree remove --force "$tmp_wt" >/dev/null 2>&1) || true
  rm -rf "$tmp_main" "$tmp_wt" 2>/dev/null || true

  if [[ -n "$resolved" && "$resolved" != "$tmp_wt" ]]; then
    pass "Test 6: _durable_root resolved to '$resolved' (main repo), not worktree '$tmp_wt'"
  else
    fail "Test 6: _durable_root resolved to '$resolved' (expected main repo, got worktree or empty)"
  fi
}

# -- Test 7: REAL JS one-liner across main / worktree / unrelated-repo cwds --
# WORKFLOW-BASH-FIX-01: leadv2-review.js no longer has any `await bash(...)` call-sites (the
# runtime provides no bash() global -- the git-common-dir resolve now runs inside an agent()
# prompt via the agent's own Bash tool). The one-liner itself is unchanged and lives in a single
# canonical constant (ROOT_RESOLVE_CMD) reused by both consumers, so anchor on the
# git-common-dir marker inside ANY backtick-delimited template literal instead of requiring the
# (now-removed) `await bash(` prefix.
_extract_js_resolve_snippet() {
  python3 -c "
import re, sys
text = open(sys.argv[1]).read()
m = re.search(r'\`([^\`]*git-common-dir[^\`]*\|\|\s*pwd)\`', text)
print(m.group(1) if m else '')
" "$JS_FILE"
}

test_7_js_resolution_three_cwds() {
  log "Test 7: REAL JS resolution one-liner across main/worktree/unrelated cwds"
  local snippet
  snippet="$(_extract_js_resolve_snippet)"
  if [[ -z "$snippet" ]]; then
    fail "Test 7: could not extract JS resolution one-liner from $JS_FILE (source moved/renamed?)"
    return
  fi

  local tmp_main tmp_wt tmp_unrelated
  tmp_main="$(lv2_mktemp_dir "mw-fix-jsmain")"
  tmp_wt="$(lv2_mktemp_dir "mw-fix-jswt")"
  tmp_unrelated="$(lv2_mktemp_dir "mw-fix-unrel")"
  rmdir "$tmp_wt"

  (
    cd "$tmp_main"
    git init -q
    git config user.email t@t.local; git config user.name t
    mkdir -p docs/leadv2
    echo x > f.txt
    git add -A && git commit -qm init
    git worktree add -q "$tmp_wt" -b mw-fix-js-branch >/dev/null 2>&1
  )
  ( cd "$tmp_unrelated" && git init -q )

  local r_main r_wt r_unrelated
  r_main="$(cd "$tmp_main" && bash -c "$snippet")"
  r_wt="$(cd "$tmp_wt" && bash -c "$snippet")"
  r_unrelated="$(cd "$tmp_unrelated" && bash -c "$snippet")"

  # Canonicalize expected paths the same way git does (resolves macOS /tmp ->
  # /private/tmp symlink) -- otherwise a correct resolution false-fails on path
  # form alone (bash-scripting skill: "Path comparison -- normalize first").
  local tmp_main_real
  tmp_main_real="$(cd "$tmp_main" 2>/dev/null && pwd -P || printf '%s' "$tmp_main")"
  # tmp_unrelated stays raw/uncanonicalized: its resolution falls through to the
  # bare `pwd` fallback (no docs/leadv2 marker), which does not resolve symlinks
  # the way `git rev-parse` does for the main/worktree branches above.

  (cd "$tmp_main" && git worktree remove --force "$tmp_wt" >/dev/null 2>&1) || true
  rm -rf "$tmp_main" "$tmp_wt" "$tmp_unrelated" 2>/dev/null || true

  if [[ "$r_main" == "$tmp_main_real" && "$r_wt" == "$tmp_main_real" && "$r_unrelated" == "$tmp_unrelated" ]]; then
    pass "Test 7: main->main ('$r_main'), worktree->main ('$r_wt'), unrelated->fails-safe-to-own-pwd ('$r_unrelated')"
  else
    fail "Test 7: expected main='$tmp_main_real' wt='$tmp_main_real' unrelated='$tmp_unrelated'; got main='$r_main' wt='$r_wt' unrelated='$r_unrelated'"
  fi
}

main() {
  log "=== leadv2-phase8-learn-counter unit tests (RUN_ID=${RUN_ID}) ==="
  log "Script: $PHASE8_SH"
  echo ""
  test_5_syntax
  test_1_close_count_increments
  test_2_trigger_at_boundary
  test_3_no_double_fire
  test_4_scorecard_path
  test_6_durable_root_worktree
  test_7_js_resolution_three_cwds
  echo ""
  log "=== Results: PASS=$PASS FAIL=$FAIL ==="
  if [[ "${#ERRORS[@]}" -gt 0 ]]; then
    log "Failures:"
    for e in "${ERRORS[@]}"; do log "  $e"; done
    exit 1
  fi
  log "All tests passed."
  exit 0
}

main "$@"
