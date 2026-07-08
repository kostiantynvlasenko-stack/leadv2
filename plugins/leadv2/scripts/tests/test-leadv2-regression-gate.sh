#!/usr/bin/env bash
# test-leadv2-regression-gate.sh -- T10 PROPOSAL-REGRESSION-GATE-01.
# Drives the REAL `leadv2-shadow-apply.sh --promote` path end-to-end against a fresh proposal
# fixture per scenario. Uses a STUB leadv2-immune-lookup.sh (copied alongside a private copy of
# the real shadow-apply.sh in an isolated SCRIPT_DIR) so the test never depends on the real
# immune-patterns.yaml keyword-matching internals -- it exercises shadow-apply.sh's own
# consumption contract (argv, tempfile-capture, timeout, exit-code handling) directly.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAL_SHADOW_APPLY="${SCRIPT_DIR}/../leadv2-shadow-apply.sh"
STUB_DIR="$(mktemp -d)"
trap 'rm -rf "$STUB_DIR"' EXIT

PASS=0
FAIL=0

log_pass() { PASS=$((PASS + 1)); printf -- 'PASS: %s\n' "$1"; }
log_fail() { FAIL=$((FAIL + 1)); printf -- 'FAIL: %s\n' "$1"; }

# ── isolated SCRIPT_DIR: private copy of the real shadow-apply.sh + a swappable
#    leadv2-immune-lookup.sh stub living right next to it (SCRIPT_DIR is derived from
#    dirname "${BASH_SOURCE[0]}" inside shadow-apply.sh itself -- not env-overridable, so the
#    only clean way to control what it calls is to control what's on disk beside it) ──────────
mkdir -p "${STUB_DIR}/bin"
cp "$REAL_SHADOW_APPLY" "${STUB_DIR}/bin/leadv2-shadow-apply.sh"
if [[ -f "${SCRIPT_DIR}/../leadv2-helpers.sh" ]]; then
  cp "${SCRIPT_DIR}/../leadv2-helpers.sh" "${STUB_DIR}/bin/leadv2-helpers.sh"
fi
ISOLATED_SHADOW_APPLY="${STUB_DIR}/bin/leadv2-shadow-apply.sh"
IMMUNE_LOOKUP_TARGET="${STUB_DIR}/bin/leadv2-immune-lookup.sh"

set_lookup_stub() {
  # $1 = script body (without shebang)
  printf -- '#!/usr/bin/env bash\n%s\n' "$1" > "$IMMUNE_LOOKUP_TARGET"
  chmod +x "$IMMUNE_LOOKUP_TARGET"
}
remove_lookup_stub() { rm -f "$IMMUNE_LOOKUP_TARGET"; }

set_lookup_stub 'printf -- "matches:\n- id: known-failed-pattern-abc\n  summary: retry without backoff caused a stampede\n  action: Check retry has exponential backoff\n  score: 0.9\n"'
STUB_MATCH_CONFIRMED="$(cat "$IMMUNE_LOOKUP_TARGET")"
set_lookup_stub 'printf -- "matches: []\n"'
STUB_NO_MATCH="$(cat "$IMMUNE_LOOKUP_TARGET")"
set_lookup_stub 'exit 1'
STUB_UNAVAILABLE="$(cat "$IMMUNE_LOOKUP_TARGET")"
set_lookup_stub 'printf -- "not: [valid, yaml: at all\n"'
STUB_UNPARSABLE="$(cat "$IMMUNE_LOOKUP_TARGET")"
set_lookup_stub '( sleep 10 ) &
printf -- "matches: []\n"'
STUB_ORPHAN_GRANDCHILD="$(cat "$IMMUNE_LOOKUP_TARGET")"
set_lookup_stub 'printf -- "matches:\n- id: below-threshold-pattern\n  summary: low-confidence coincidental overlap\n  action: Check nothing in particular\n  score: 0.2\n"'
STUB_MATCH_BELOW_THRESHOLD="$(cat "$IMMUNE_LOOKUP_TARGET")"
set_lookup_stub 'printf -- "matches:\n- id: boundary-pattern\n  summary: exact threshold boundary match\n  action: Check the boundary\n  score: 0.5\n"'
STUB_MATCH_AT_THRESHOLD="$(cat "$IMMUNE_LOOKUP_TARGET")"
set_lookup_stub 'printf -- "matches:\n- id: malformed-score-pattern\n  summary: malformed score value\n  action: Check nothing\n  score: 0.9junk\n"'
STUB_NON_NUMERIC_SCORE="$(cat "$IMMUNE_LOOKUP_TARGET")"
remove_lookup_stub

# ── signature-capture stub (fix-round-1 #1 -- proves FIRST-NON-EMPTY, not concatenation) ────────
SIG_CAPTURE_FILE="${STUB_DIR}/sig_capture.txt"
set_lookup_stub 'printf -- "%s" "$1" > "'"${SIG_CAPTURE_FILE}"'"; printf -- "matches: []\n"'
STUB_SIG_CAPTURE="$(cat "$IMMUNE_LOOKUP_TARGET")"
remove_lookup_stub

# ── fixture builder: fresh isolated LEADV2_PROJECT_ROOT + proposal + target file ────────────────
setup_fixture() {
  local root="$1"
  mkdir -p "${root}/docs/leadv2/shadow/proposals" "${root}/docs/leadv2/shadow/snapshots"
  printf -- 'line one\nline two\n' > "${root}/target.txt"
  local pid
  pid=$(python3 -c "import hashlib; print(hashlib.sha1(b'regression-gate-test').hexdigest())")
  local patch_body
  patch_body=$(cd "$root" && diff -u target.txt <(printf -- 'line one\nline TWO-CANDIDATE\n') || true)
  patch_body="${patch_body//target.txt/a\/target.txt}"
  python3 - "$root" "$pid" "$patch_body" << 'PYEOF'
import sys, yaml
root, pid, patch_body = sys.argv[1], sys.argv[2], sys.argv[3]
proposal = {
    "id": pid,
    "task_id": "REGRESSION-GATE-01-fixture",
    "kind": "cross-repo-pattern",
    "risk_level": "low",
    "target_file": "target.txt",
    "before_snapshot": "",
    "diff_patch": patch_body,
    "arm": "A",
    "status": "pending",
    "proposed_at": "2026-01-01T00:00:00Z",
    "min_n_per_arm": 1,
    "representative_summary": "retry without backoff caused a stampede",
    "keywords": ["retry", "timeout"],
    "title": "[cross-repo] retry, timeout pattern",
}
with open(f"{root}/docs/leadv2/shadow/proposals/{pid}.yaml", "w") as f:
    yaml.dump(proposal, f, default_flow_style=False, sort_keys=False)
PYEOF
  printf -- '%s' "$pid"
}

# fix-round-1 #1: representative_summary is DELIBERATELY unrelated to title/keywords/kind so a
# concatenation-based signature (the pre-fix bug) is trivially distinguishable from the
# first-non-empty signature (the fix) when the stub captures the argv it actually received.
setup_fixture_noisy_signature() {
  local root="$1"
  mkdir -p "${root}/docs/leadv2/shadow/proposals" "${root}/docs/leadv2/shadow/snapshots"
  printf -- 'line one\nline two\n' > "${root}/target.txt"
  local pid
  pid=$(python3 -c "import hashlib; print(hashlib.sha1(b'regression-gate-signature-test').hexdigest())")
  local patch_body
  patch_body=$(cd "$root" && diff -u target.txt <(printf -- 'line one\nline TWO-CANDIDATE\n') || true)
  patch_body="${patch_body//target.txt/a\/target.txt}"
  python3 - "$root" "$pid" "$patch_body" << 'PYEOF'
import sys, yaml
root, pid, patch_body = sys.argv[1], sys.argv[2], sys.argv[3]
proposal = {
    "id": pid,
    "task_id": "REGRESSION-GATE-01-signature-fixture",
    "kind": "cross-repo-pattern",
    "risk_level": "low",
    "target_file": "target.txt",
    "before_snapshot": "",
    "diff_patch": patch_body,
    "arm": "A",
    "status": "pending",
    "proposed_at": "2026-01-01T00:00:00Z",
    "min_n_per_arm": 1,
    "representative_summary": "the-primary-signature",
    "keywords": ["unrelated", "noise", "padding"],
    "title": "[cross-repo] totally different noisy unrelated title",
}
with open(f"{root}/docs/leadv2/shadow/proposals/{pid}.yaml", "w") as f:
    yaml.dump(proposal, f, default_flow_style=False, sort_keys=False)
PYEOF
  printf -- '%s' "$pid"
}

run_promote() {
  local script="$1" root="$2" pid="$3"
  shift 3
  ( cd "$root" && env -i PATH="$PATH" HOME="$HOME" \
      LEADV2_PROJECT_ROOT="$root" LEADV2_SHADOW_ON_CLOSE=1 \
      "$@" bash "$script" --promote --proposal-id "$pid" ) 2>&1
}

proposal_status() {
  local root="$1" pid="$2"
  python3 -c "
import yaml
p = yaml.safe_load(open('${root}/docs/leadv2/shadow/proposals/${pid}.yaml')) or {}
print(p.get('status',''))
"
}

strip_ts() { sed -E 's/[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z/<TS>/g'; }

# ── Test 1: flag-off golden -- output identical between pre-diff (git HEAD) and patched script ──
test_flag_off_golden() {
  local orig_script="${STUB_DIR}/orig-shadow-apply.sh"
  git -C "$SCRIPT_DIR" show HEAD:plugins/leadv2/scripts/leadv2-shadow-apply.sh > "$orig_script" 2>/dev/null
  chmod +x "$orig_script"
  # keep helper-sourcing symmetric between the two runs (SCRIPT_DIR-adjacent lookup)
  if [[ -f "${SCRIPT_DIR}/../leadv2-helpers.sh" ]]; then
    cp "${SCRIPT_DIR}/../leadv2-helpers.sh" "${STUB_DIR}/leadv2-helpers.sh"
  fi

  local root_a root_b pid_a pid_b out_a out_b
  root_a="$(mktemp -d)"; root_b="$(mktemp -d)"
  pid_a="$(setup_fixture "$root_a")"
  pid_b="$(setup_fixture "$root_b")"

  out_a="$(run_promote "$orig_script" "$root_a" "$pid_a" | strip_ts)"
  out_b="$(run_promote "$ISOLATED_SHADOW_APPLY" "$root_b" "$pid_b" | strip_ts)"
  out_a="${out_a//$pid_a/PID}"; out_a="${out_a//$root_a/ROOT}"
  out_b="${out_b//$pid_b/PID}"; out_b="${out_b//$root_b/ROOT}"

  local status_a status_b target_a target_b
  status_a="$(proposal_status "$root_a" "$pid_a")"
  status_b="$(proposal_status "$root_b" "$pid_b")"
  target_a="$(cat "${root_a}/target.txt")"
  target_b="$(cat "${root_b}/target.txt")"

  if [[ "$out_a" == "$out_b" && "$status_a" == "$status_b" && "$target_a" == "$target_b" ]]; then
    log_pass "flag-off byte-identical golden (status=${status_a}) -- LEADV2_REGRESSION_GATE unset never invoked in either run"
  else
    log_fail "flag-off golden MISMATCH (status ${status_a} vs ${status_b})"
    diff <(printf -- '%s' "$out_a") <(printf -- '%s' "$out_b") || true
  fi
  rm -rf "$root_a" "$root_b"
}

# ── Test 2: flag-on + CONFIRMED negmem match -> HELD (rc=6, target unchanged, status unchanged) ─
test_confirmed_match_held() {
  set_lookup_stub "$STUB_MATCH_CONFIRMED"
  local root pid rc out status target
  root="$(mktemp -d)"; pid="$(setup_fixture "$root")"
  out="$(run_promote "$ISOLATED_SHADOW_APPLY" "$root" "$pid" LEADV2_REGRESSION_GATE=1)"
  rc=$?
  status="$(proposal_status "$root" "$pid")"
  target="$(cat "${root}/target.txt")"
  if [[ $rc -eq 6 && "$status" == "pending" && "$target" == *"line two"* && "$target" != *"CANDIDATE"* \
        && "$out" == *"regression-gate HELD"* && "$out" == *"known-failed-pattern-abc"* ]]; then
    log_pass "confirmed negmem match -> HELD (rc=6, status unchanged=pending, target unchanged, distinct log reason naming matched pattern)"
  else
    log_fail "confirmed match expected HELD, got rc=${rc} status=${status}"
    printf -- '%s\n' "$out"
  fi
  remove_lookup_stub
  rm -rf "$root"
}

# ── Test 3: flag-on + no match -> applied (rc=0, promoted, target patched) ──────────────────────
test_no_match_applied() {
  set_lookup_stub "$STUB_NO_MATCH"
  local root pid rc out status target
  root="$(mktemp -d)"; pid="$(setup_fixture "$root")"
  out="$(run_promote "$ISOLATED_SHADOW_APPLY" "$root" "$pid" LEADV2_REGRESSION_GATE=1)"
  rc=$?
  status="$(proposal_status "$root" "$pid")"
  target="$(cat "${root}/target.txt")"
  if [[ $rc -eq 0 && "$status" == "promoted" && "$target" == *"line TWO-CANDIDATE"* \
        && "$out" == *"no negmem match"* ]]; then
    log_pass "no match -> applied (rc=0, status=promoted, target patched, warn logged)"
  else
    log_fail "no-match expected applied, got rc=${rc} status=${status}"
    printf -- '%s\n' "$out"
  fi
  remove_lookup_stub
  rm -rf "$root"
}

# ── Test 4: flag-on + lookup unavailable (nonzero exit) -> applied-with-warn (fail-open) ────────
test_lookup_unavailable_applied() {
  set_lookup_stub "$STUB_UNAVAILABLE"
  local root pid rc out status target
  root="$(mktemp -d)"; pid="$(setup_fixture "$root")"
  out="$(run_promote "$ISOLATED_SHADOW_APPLY" "$root" "$pid" LEADV2_REGRESSION_GATE=1)"
  rc=$?
  status="$(proposal_status "$root" "$pid")"
  target="$(cat "${root}/target.txt")"
  if [[ $rc -eq 0 && "$status" == "promoted" && "$target" == *"line TWO-CANDIDATE"* \
        && "$out" == *"lookup unavailable"* ]]; then
    log_pass "lookup unavailable (nonzero exit) -> applied-with-warn (fail-open proven)"
  else
    log_fail "lookup-unavailable expected applied-with-warn, got rc=${rc} status=${status}"
    printf -- '%s\n' "$out"
  fi
  remove_lookup_stub
  rm -rf "$root"
}

# ── Test 5: flag-on + unparsable YAML output -> applied-with-warn (fail-open) ───────────────────
test_unparsable_applied() {
  set_lookup_stub "$STUB_UNPARSABLE"
  local root pid rc out status target
  root="$(mktemp -d)"; pid="$(setup_fixture "$root")"
  out="$(run_promote "$ISOLATED_SHADOW_APPLY" "$root" "$pid" LEADV2_REGRESSION_GATE=1)"
  rc=$?
  status="$(proposal_status "$root" "$pid")"
  target="$(cat "${root}/target.txt")"
  if [[ $rc -eq 0 && "$status" == "promoted" && "$target" == *"line TWO-CANDIDATE"* \
        && "$out" == *"unparsable"* ]]; then
    log_pass "unparsable immune-lookup output -> applied-with-warn (fail-open proven)"
  else
    log_fail "unparsable expected applied-with-warn, got rc=${rc} status=${status}"
    printf -- '%s\n' "$out"
  fi
  remove_lookup_stub
  rm -rf "$root"
}

# ── Test 6: lookup script missing entirely -> applied-with-warn (fail-open) ─────────────────────
test_lookup_missing_applied() {
  remove_lookup_stub
  local root pid rc out status target
  root="$(mktemp -d)"; pid="$(setup_fixture "$root")"
  out="$(run_promote "$ISOLATED_SHADOW_APPLY" "$root" "$pid" LEADV2_REGRESSION_GATE=1)"
  rc=$?
  status="$(proposal_status "$root" "$pid")"
  target="$(cat "${root}/target.txt")"
  if [[ $rc -eq 0 && "$status" == "promoted" && "$target" == *"line TWO-CANDIDATE"* \
        && "$out" == *"script not found"* ]]; then
    log_pass "lookup script missing -> applied-with-warn (fail-open proven)"
  else
    log_fail "lookup-missing expected applied-with-warn, got rc=${rc} status=${status}"
    printf -- '%s\n' "$out"
  fi
  rm -rf "$root"
}

# ── Test 7: lookup backgrounds a stdout-inheriting grandchild -> returns promptly, no pipe wedge ─
test_orphan_grandchild_no_wedge() {
  set_lookup_stub "$STUB_ORPHAN_GRANDCHILD"
  local root pid rc out status target start end elapsed
  root="$(mktemp -d)"; pid="$(setup_fixture "$root")"
  start=$(date +%s)
  out="$(run_promote "$ISOLATED_SHADOW_APPLY" "$root" "$pid" LEADV2_REGRESSION_GATE=1)"
  rc=$?
  end=$(date +%s)
  elapsed=$((end - start))
  status="$(proposal_status "$root" "$pid")"
  target="$(cat "${root}/target.txt")"
  # bug (if $(...) capture were used): would block ~10s on the orphaned grandchild's fd 1.
  # fixed (tempfile capture): returns as soon as the lookup script itself exits -- well under 5s.
  if [[ $elapsed -le 5 && $rc -eq 0 && "$status" == "promoted" && "$target" == *"line TWO-CANDIDATE"* ]]; then
    log_pass "orphan-grandchild -> returned promptly (${elapsed}s <= 5s, not ~10s), correct decision (applied, no match)"
  else
    log_fail "orphan-grandchild expected prompt return (<=5s) + applied, got elapsed=${elapsed}s rc=${rc} status=${status}"
    printf -- '%s\n' "$out"
  fi
  remove_lookup_stub
  rm -rf "$root"
}

# ── Test 8: bash -n syntax check on the patched script ──────────────────────────────────────────
test_bash_n() {
  if bash -n "$REAL_SHADOW_APPLY" 2>/dev/null; then
    log_pass "bash -n leadv2-shadow-apply.sh -- syntax OK"
  else
    log_fail "bash -n leadv2-shadow-apply.sh -- SYNTAX ERROR"
  fi
}

# ── Test 9 (fix-round-1): score < threshold -> applied (proceed) ────────────────────────────────
test_score_below_threshold_applied() {
  set_lookup_stub "$STUB_MATCH_BELOW_THRESHOLD"
  local root pid rc out status target
  root="$(mktemp -d)"; pid="$(setup_fixture "$root")"
  out="$(run_promote "$ISOLATED_SHADOW_APPLY" "$root" "$pid" LEADV2_REGRESSION_GATE=1)"
  rc=$?
  status="$(proposal_status "$root" "$pid")"
  target="$(cat "${root}/target.txt")"
  if [[ $rc -eq 0 && "$status" == "promoted" && "$target" == *"line TWO-CANDIDATE"* \
        && "$out" == *"below threshold"* ]]; then
    log_pass "score (0.2) < threshold (0.5) -> applied (proceed)"
  else
    log_fail "score-below-threshold expected applied, got rc=${rc} status=${status}"
    printf -- '%s\n' "$out"
  fi
  remove_lookup_stub
  rm -rf "$root"
}

# ── Test 10 (fix-round-1): score == threshold -> HELD (inclusive boundary) ──────────────────────
test_score_at_threshold_held() {
  set_lookup_stub "$STUB_MATCH_AT_THRESHOLD"
  local root pid rc out status target
  root="$(mktemp -d)"; pid="$(setup_fixture "$root")"
  out="$(run_promote "$ISOLATED_SHADOW_APPLY" "$root" "$pid" LEADV2_REGRESSION_GATE=1)"
  rc=$?
  status="$(proposal_status "$root" "$pid")"
  target="$(cat "${root}/target.txt")"
  if [[ $rc -eq 6 && "$status" == "pending" && "$target" == *"line two"* && "$target" != *"CANDIDATE"* \
        && "$out" == *"regression-gate HELD"* && "$out" == *"boundary-pattern"* ]]; then
    log_pass "score (0.5) == threshold (0.5) -> HELD (inclusive boundary)"
  else
    log_fail "score-at-threshold expected HELD, got rc=${rc} status=${status}"
    printf -- '%s\n' "$out"
  fi
  remove_lookup_stub
  rm -rf "$root"
}

# ── Test 11 (fix-round-1): non-numeric score ("0.9junk") -> applied-with-warn, NOT held ──────────
test_non_numeric_score_applied() {
  set_lookup_stub "$STUB_NON_NUMERIC_SCORE"
  local root pid rc out status target
  root="$(mktemp -d)"; pid="$(setup_fixture "$root")"
  out="$(run_promote "$ISOLATED_SHADOW_APPLY" "$root" "$pid" LEADV2_REGRESSION_GATE=1)"
  rc=$?
  status="$(proposal_status "$root" "$pid")"
  target="$(cat "${root}/target.txt")"
  if [[ $rc -eq 0 && "$status" == "promoted" && "$target" == *"line TWO-CANDIDATE"* \
        && "$out" == *"non-numeric score"* ]]; then
    log_pass "non-numeric score (0.9junk) -> applied-with-warn (does NOT spuriously HOLD)"
  else
    log_fail "non-numeric-score expected applied-with-warn, got rc=${rc} status=${status}"
    printf -- '%s\n' "$out"
  fi
  remove_lookup_stub
  rm -rf "$root"
}

# ── Test 12 (fix-round-1): FIRST-NON-EMPTY signature, not concatenation ─────────────────────────
test_first_non_empty_signature() {
  set_lookup_stub "$STUB_SIG_CAPTURE"
  rm -f "$SIG_CAPTURE_FILE"
  local root pid rc out captured
  root="$(mktemp -d)"; pid="$(setup_fixture_noisy_signature "$root")"
  out="$(run_promote "$ISOLATED_SHADOW_APPLY" "$root" "$pid" LEADV2_REGRESSION_GATE=1)"
  rc=$?
  captured="$(cat "$SIG_CAPTURE_FILE" 2>/dev/null || echo "<no capture>")"
  if [[ $rc -eq 0 && "$captured" == "the-primary-signature" ]]; then
    log_pass "signature == representative_summary ALONE ('${captured}'), not concatenated with noisy title/keywords"
  else
    log_fail "expected captured signature == 'the-primary-signature', got '${captured}' (rc=${rc})"
    printf -- '%s\n' "$out"
  fi
  remove_lookup_stub
  rm -rf "$root"
}

test_flag_off_golden
test_confirmed_match_held
test_no_match_applied
test_lookup_unavailable_applied
test_unparsable_applied
test_lookup_missing_applied
test_orphan_grandchild_no_wedge
test_bash_n
test_score_below_threshold_applied
test_score_at_threshold_held
test_non_numeric_score_applied
test_first_non_empty_signature

printf -- '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
