#!/usr/bin/env bash
# tests/test-fanout-heavy-max-collision.sh — HEAVY-MAX-2-WITH-COLLISION-GUARD-01
# E2E test for the heavy_max=2 + collision-guard cap in leadv2-fanout.sh.
#
# Calls the REAL leadv2-fanout.sh --dry-run (NEVER reimplements the cap logic)
# over a sandboxed repo and asserts the 7 required behaviors:
#   a. two NON-colliding Heavy (different group_key, no prod risk) -> BOTH LAUNCH
#   b. two prod-deploy Heavy (both risk_tags include publish) -> 2nd is SKIP (serialize)
#   c. two SAME-group_key Heavy -> 2nd is SKIP (serialize)
#   d. heavy_max=2 respected -> a 3rd Heavy is SKIP "heavy_max reached"
#   e. kill-switch: meta.heavy_strategic_solo=true (+heavy_max) -> 2nd non-colliding Heavy SKIP
#   f. --force does NOT exceed heavy_max (3rd Heavy still blocked at the ceiling)
#   g. legacy meta: heavy_strategic_solo=true with NO heavy_max key -> serializes (back-compat)
#
# Codex Phase-5 review fix-round-1 (HEAVY-MAX-2-WITH-COLLISION-GUARD-01) added 3 more:
#   b'. two prod-deploy Heavy WITH --force -> 2nd STILL SKIP (HARD collision, non-bypassable)
#   h.  two same-known-group NON-PROD Heavy WITH --force -> 2nd LAUNCHES (SOFT collision bypassable)
#   i.  2nd Heavy has unknown risk_tags (no risk keyword match) though its group_key
#       DIFFERS from the 1st -> still SKIP (fail-closed on unknown, independent of group)
#
# F6/FIX3/FIX4 note: the register-time under-lock re-count (F6), the under-lock
# pairwise HARD-collision re-check (FIX3), and the kill-spawned-child-on-refused-
# registration behavior (FIX4) are NOT asserted here -- --dry-run exits before
# _fanout_register_session/launch_* ever run (see leadv2-fanout.sh's
# `if [[ "$DRY_RUN" == "true" ]]; then ... exit 0; fi` guard), so none of the
# three are reachable from a deterministic single-process --dry-run harness.
# Verified by code inspection instead -- see build-report.md for exact line
# ranges.
#
# Portable: no GNU-only date/sed -i/timeout/flock. Sandboxed via
# LEADV2_PROJECT_ROOT / LEADV2_STATE_ROOT / LEADV2_SKIP_DRIFT_GUARD -- never
# touches the real repo's docs/leadv2/active.yaml or a real "leadv2" tmux
# session. Run: bash scripts/tests/test-fanout-heavy-max-collision.sh
# Exit 0 = all 10 pass; non-zero = failures found.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/leadv2-temp.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
FANOUT_SH="${SCRIPTS_ROOT}/leadv2-fanout.sh"

PASS=0; FAIL=0; ERRORS=()
log()  { printf -- '[TEST] %s\n' "$*"; }
pass() { PASS=$((PASS + 1)); log "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); ERRORS+=("FAIL: $1"); log "FAIL: $1"; }

# Every Heavy row carries an explicit class: Heavy (so the classifier preserves
# it regardless of intent wording) + a group_key + an intent whose risk keyword
# drives risk_tags. Non-prod rows use "auth" (NOT in the prod-risk set); prod
# rows use deploy/publish/migration (->[publish] risk tag, a prod-risk).
_make_sandbox() {
  local d
  d="$(lv2_mktemp_dir "fanouthm-test")"
  mkdir -p "${d}/proj/docs/leadv2" "${d}/state"
  cat > "${d}/proj/docs/tasks.yaml" <<'YAML'
tasks:
  - {id: HMC-A1, status: queued, priority: 5, group_key: grp-alpha, class: Heavy, intent: "refactor the auth module internals"}
  - {id: HMC-A2, status: queued, priority: 5, group_key: grp-beta,  class: Heavy, intent: "rewrite the auth helpers cleanly"}
  - {id: HMC-B1, status: queued, priority: 5, group_key: grp-b1, class: Heavy, intent: "deploy a schema migration to prod"}
  - {id: HMC-B2, status: queued, priority: 5, group_key: grp-b2, class: Heavy, intent: "publish a data migration"}
  - {id: HMC-C1, status: queued, priority: 5, group_key: grp-same, class: Heavy, intent: "refactor the auth cookie store"}
  - {id: HMC-C2, status: queued, priority: 5, group_key: grp-same, class: Heavy, intent: "clean up the auth flow"}
  - {id: HMC-D1, status: queued, priority: 5, group_key: grp-d1, class: Heavy, intent: "refactor the auth module part one"}
  - {id: HMC-D2, status: queued, priority: 5, group_key: grp-d2, class: Heavy, intent: "refactor the auth module part two"}
  - {id: HMC-D3, status: queued, priority: 5, group_key: grp-d3, class: Heavy, intent: "refactor the auth module part three"}
  - {id: HMC-E1, status: queued, priority: 5, group_key: grp-e1, class: Heavy, intent: "refactor the auth layer east"}
  - {id: HMC-E2, status: queued, priority: 5, group_key: grp-e2, class: Heavy, intent: "refactor the auth layer west"}
  - {id: HMC-F1, status: queued, priority: 5, group_key: grp-f1, class: Heavy, intent: "refactor the auth layer f1"}
  - {id: HMC-F2, status: queued, priority: 5, group_key: grp-f2, class: Heavy, intent: "refactor the auth layer f2"}
  - {id: HMC-F3, status: queued, priority: 5, group_key: grp-f3, class: Heavy, intent: "refactor the auth layer f3"}
  - {id: HMC-G1, status: queued, priority: 5, group_key: grp-g1, class: Heavy, intent: "refactor the auth layer g1"}
  - {id: HMC-G2, status: queued, priority: 5, group_key: grp-g2, class: Heavy, intent: "refactor the auth layer g2"}
  - {id: HMC-BP1, status: queued, priority: 5, group_key: grp-bp1, class: Heavy, intent: "deploy a schema migration to prod bp1"}
  - {id: HMC-BP2, status: queued, priority: 5, group_key: grp-bp2, class: Heavy, intent: "publish a data migration bp2"}
  - {id: HMC-H1, status: queued, priority: 5, group_key: grp-hsame, class: Heavy, intent: "refactor the auth cookie store h1"}
  - {id: HMC-H2, status: queued, priority: 5, group_key: grp-hsame, class: Heavy, intent: "clean up the auth flow h2"}
  - {id: HMC-I1, status: queued, priority: 5, group_key: grp-i1, class: Heavy, intent: "refactor the auth module i1"}
  - {id: HMC-I2, status: queued, priority: 5, group_key: grp-i2, class: Heavy, intent: "reformat the css spacing on the settings page i2"}
YAML
  printf -- '%s' "$d"
}

# _write_active <sandbox> <heavy_max|omit> <heavy_strategic_solo|omit>
_write_active() {
  local d="$1" hm="$2" solo="$3"
  {
    printf -- 'meta:\n'
    printf -- '  schema_version: 2\n'
    printf -- '  hard_limit: 20\n'
    [[ "$hm" != "omit" ]]    && printf -- '  heavy_max: %s\n' "$hm"
    [[ "$solo" != "omit" ]] && printf -- '  heavy_strategic_solo: %s\n' "$solo"
    printf -- '  light_max: 3\n'
    printf -- '  standard_max: 2\n'
    printf -- '  rendered_at: ""\n'
    printf -- 'sessions: []\n'
  } > "${d}/proj/docs/leadv2/active.yaml"
}

# _run <sandbox> <fanout args...> -> combined stdout+stderr
_run() {
  local d="$1"; shift
  LEADV2_PROJECT_ROOT="${d}/proj" LEADV2_STATE_ROOT="${d}/state" \
    LEADV2_SKIP_DRIFT_GUARD=1 \
    bash "$FANOUT_SH" --provider claude --dry-run "$@" 2>&1 || true
}

# report line (LAUNCH or skip) mentioning a task id
_line_for() { printf '%s\n' "$1" | grep -E -- '- (LAUNCH|skip)' | grep -F -- "$2" | head -1; }
_is_launch() { local l; l="$(_line_for "$1" "$2")"; [[ "$l" == *LAUNCH* ]]; }
_is_skip()   { local l; l="$(_line_for "$1" "$2")"; [[ "$l" == *skip* ]]; }
_skip_has()  { local l; l="$(_line_for "$1" "$2")"; [[ "$l" == *"$3"* ]]; }

# ---- assertions a..g --------------------------------------------------------

t_a() {
  log "a: two non-colliding Heavy (diff group_key, non-prod) -> BOTH LAUNCH"
  local d out
  d="$(_make_sandbox)"; _write_active "$d" 2 omit
  out="$(_run "$d" --tasks HMC-A1,HMC-A2)"
  rm -rf "$d"
  if _is_launch "$out" HMC-A1 && _is_launch "$out" HMC-A2; then
    pass "a: both non-colliding Heavy LAUNCH"
  else fail "a: out=$out"; fi
}

t_b() {
  log "b: two prod-deploy Heavy (both publish) -> 2nd SKIP (serialize)"
  local d out
  d="$(_make_sandbox)"; _write_active "$d" 2 omit
  out="$(_run "$d" --tasks HMC-B1,HMC-B2)"
  rm -rf "$d"
  if _is_launch "$out" HMC-B1 && _is_skip "$out" HMC-B2 && _skip_has "$out" HMC-B2 "collision"; then
    pass "b: 2nd prod-deploy Heavy serialized (collision)"
  else fail "b: out=$out"; fi
}

t_c() {
  log "c: two SAME-group_key Heavy -> 2nd SKIP (serialize)"
  local d out
  d="$(_make_sandbox)"; _write_active "$d" 2 omit
  out="$(_run "$d" --tasks HMC-C1,HMC-C2)"
  rm -rf "$d"
  if _is_launch "$out" HMC-C1 && _is_skip "$out" HMC-C2 && _skip_has "$out" HMC-C2 "collision"; then
    pass "c: 2nd same-group_key Heavy serialized (collision)"
  else fail "c: out=$out"; fi
}

t_d() {
  log "d: heavy_max=2 -> 3rd Heavy SKIP 'heavy_max reached'"
  local d out
  d="$(_make_sandbox)"; _write_active "$d" 2 omit
  out="$(_run "$d" --tasks HMC-D1,HMC-D2,HMC-D3)"
  rm -rf "$d"
  if _is_launch "$out" HMC-D1 && _is_launch "$out" HMC-D2 \
     && _is_skip "$out" HMC-D3 && _skip_has "$out" HMC-D3 "heavy_max"; then
    pass "d: 3rd Heavy blocked at heavy_max ceiling"
  else fail "d: out=$out"; fi
}

t_e() {
  log "e: kill-switch heavy_strategic_solo=true (+heavy_max) -> 2nd non-colliding Heavy SKIP"
  local d out
  d="$(_make_sandbox)"; _write_active "$d" 2 true
  out="$(_run "$d" --tasks HMC-E1,HMC-E2)"
  rm -rf "$d"
  if _is_launch "$out" HMC-E1 && _is_skip "$out" HMC-E2 && _skip_has "$out" HMC-E2 "heavy_strategic_solo"; then
    pass "e: explicit solo kill-switch serializes 2nd Heavy"
  else fail "e: out=$out"; fi
}

t_f() {
  log "f: --force does NOT exceed heavy_max -> 3rd Heavy still blocked"
  local d out
  d="$(_make_sandbox)"; _write_active "$d" 2 omit
  out="$(_run "$d" --force --tasks HMC-F1,HMC-F2,HMC-F3)"
  rm -rf "$d"
  if _is_launch "$out" HMC-F1 && _is_launch "$out" HMC-F2 \
     && _is_skip "$out" HMC-F3 && _skip_has "$out" HMC-F3 "heavy_max"; then
    pass "f: --force cannot push past heavy_max (hard ceiling)"
  else fail "f: out=$out"; fi
}

t_g() {
  log "g: legacy meta (heavy_strategic_solo=true, NO heavy_max key) -> serializes"
  local d out
  d="$(_make_sandbox)"; _write_active "$d" omit true
  out="$(_run "$d" --tasks HMC-G1,HMC-G2)"
  rm -rf "$d"
  if _is_launch "$out" HMC-G1 && _is_skip "$out" HMC-G2 && _skip_has "$out" HMC-G2 "heavy_strategic_solo"; then
    pass "g: legacy solo-only meta serializes (back-compat)"
  else fail "g: out=$out"; fi
}

# ---- fix-round-1 assertions: b', h, i ---------------------------------------

t_bprime() {
  log "b': two prod-deploy Heavy WITH --force -> 2nd STILL SKIP (HARD, non-bypassable)"
  local d out
  d="$(_make_sandbox)"; _write_active "$d" 2 omit
  out="$(_run "$d" --force --tasks HMC-BP1,HMC-BP2)"
  rm -rf "$d"
  if _is_launch "$out" HMC-BP1 && _is_skip "$out" HMC-BP2 && _skip_has "$out" HMC-BP2 "collision"; then
    pass "b': --force cannot bypass a prod/prod HARD collision"
  else fail "b': out=$out"; fi
}

t_h() {
  log "h: two same-known-group NON-PROD Heavy WITH --force -> 2nd LAUNCHES (SOFT, bypassable)"
  local d out
  d="$(_make_sandbox)"; _write_active "$d" 2 omit
  out="$(_run "$d" --force --tasks HMC-H1,HMC-H2)"
  rm -rf "$d"
  if _is_launch "$out" HMC-H1 && _is_launch "$out" HMC-H2; then
    pass "h: --force bypasses a same-known-group SOFT collision"
  else fail "h: out=$out"; fi
}

t_i() {
  log "i: 2nd Heavy has unknown risk_tags, DIFFERENT group_key -> still SKIP (fail-closed)"
  local d out
  d="$(_make_sandbox)"; _write_active "$d" 2 omit
  out="$(_run "$d" --tasks HMC-I1,HMC-I2)"
  rm -rf "$d"
  if _is_launch "$out" HMC-I1 && _is_skip "$out" HMC-I2 && _skip_has "$out" HMC-I2 "collision"; then
    pass "i: unknown risk_tags collides independently of group_key match"
  else fail "i: out=$out"; fi
}

main() {
  log "=== leadv2-fanout.sh heavy_max + collision-guard E2E (HEAVY-MAX-2-WITH-COLLISION-GUARD-01) ==="
  log "fanout: $FANOUT_SH"
  printf -- '\n'
  t_a
  t_b
  t_c
  t_d
  t_e
  t_f
  t_g
  t_bprime
  t_h
  t_i
  printf -- '\n'
  log "=== Results: PASS=$PASS FAIL=$FAIL ==="
  if [[ "${#ERRORS[@]}" -gt 0 ]]; then
    log "Failures:"
    for e in "${ERRORS[@]}"; do log "  $e"; done
    exit 1
  fi
  log "All 10 assertions passed."
  exit 0
}

main "$@"
