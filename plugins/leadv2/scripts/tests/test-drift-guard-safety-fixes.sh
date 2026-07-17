#!/usr/bin/env bash
# tests/test-drift-guard-safety-fixes.sh — PLUGIN-CACHE-THIRD-COPY-REVERTS-FIXES-01
# fix1 (review-1.md C3): coverage for the previously-untested new logic that
# now gates every fanout dispatch and every plugin-sync run.
#
# Covers:
#   1. leadv2-direction-safety-check.py's 4 exit paths (missing dst -> 0,
#      no history -> 1, matching historical blob -> 0, non-matching -> 1).
#   2. leadv2-drift-guard.sh detecting a deliberately-introduced single-byte
#      diff in one copy (sandboxed via LEADV2_CANONICAL_ROOT/LEADV2_HOME_ROOT
#      test hooks — never touches the real 5 copies).
#   3. leadv2-drift-only-vendored-check.py — the REAL classification helper
#      leadv2-fanout.sh's preflight calls (extracted from an inline heredoc
#      specifically so it's unit-testable): confirms drift confined to
#      leadv2-repo-vendored -> "1" (WARN-and-proceed), drift touching any
#      other copy or no drift -> "0" (hard-block/no-op) — the new C1
#      WARN-vs-block distinction.
#
# Portable: no GNU-only date/sed -i/timeout/flock. Everything runs under a
# mktemp sandbox; nothing under ~/Projects/leadv2, ~/.claude, or any real
# vendored repo is ever read or written.
# Run: bash scripts/tests/test-drift-guard-safety-fixes.sh
# Exit 0 = all pass; non-zero = failures found.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DIRECTION_SAFETY="${SCRIPTS_ROOT}/leadv2-direction-safety-check.py"
DRIFT_GUARD="${SCRIPTS_ROOT}/leadv2-drift-guard.sh"
CLASSIFY="${SCRIPTS_ROOT}/leadv2-drift-only-vendored-check.py"

FAIL=0
pass() { printf -- 'PASS: %s\n' "$*"; }
fail() { printf -- 'FAIL: %s\n' "$*" >&2; FAIL=1; }

TMPROOT="$(mktemp -d)"
trap 'rm -rf "${TMPROOT}"' EXIT

# ─────────────────────────────────────────────────────────────────────────
# 1. direction-safety-check.py — 4 exit paths, against a throwaway git repo
# ─────────────────────────────────────────────────────────────────────────
DS_REPO="${TMPROOT}/ds-repo"
mkdir -p "${DS_REPO}"
git -C "${DS_REPO}" init -q
git -C "${DS_REPO}" config user.email "test@test.local"
git -C "${DS_REPO}" config user.name "test"

# 1a. missing dst -> SAFE (0)
if python3 "${DIRECTION_SAFETY}" "${DS_REPO}" "some/path.sh" "${TMPROOT}/does-not-exist"; then
  pass "direction-safety: missing dst_file -> exit 0 (SAFE)"
else
  fail "direction-safety: missing dst_file should exit 0"
fi

# 1b. no history for relpath -> UNSAFE (1)
DST_NOHIST="${TMPROOT}/nohist.txt"
printf -- 'nobody has ever seen this content\n' > "${DST_NOHIST}"
if python3 "${DIRECTION_SAFETY}" "${DS_REPO}" "relpath/with/no/history.sh" "${DST_NOHIST}"; then
  fail "direction-safety: no-history relpath should exit 1 (UNSAFE)"
else
  pass "direction-safety: no history for relpath -> exit 1 (UNSAFE)"
fi

# 1c/1d. commit a real file, then test matching vs non-matching content
mkdir -p "${DS_REPO}/tracked"
printf -- 'canonical content v1\n' > "${DS_REPO}/tracked/file.sh"
git -C "${DS_REPO}" add tracked/file.sh
git -C "${DS_REPO}" commit -q -m "add tracked file"

DST_MATCH="${TMPROOT}/match.txt"
printf -- 'canonical content v1\n' > "${DST_MATCH}"
if python3 "${DIRECTION_SAFETY}" "${DS_REPO}" "tracked/file.sh" "${DST_MATCH}"; then
  pass "direction-safety: content matches historical blob -> exit 0 (SAFE)"
else
  fail "direction-safety: matching historical content should exit 0"
fi

DST_NOMATCH="${TMPROOT}/nomatch.txt"
printf -- 'some un-landed local fix, never in canonical history\n' > "${DST_NOMATCH}"
if python3 "${DIRECTION_SAFETY}" "${DS_REPO}" "tracked/file.sh" "${DST_NOMATCH}"; then
  fail "direction-safety: non-matching content should exit 1 (UNSAFE)"
else
  pass "direction-safety: content never in history -> exit 1 (UNSAFE)"
fi

# ─────────────────────────────────────────────────────────────────────────
# 2. drift-guard.sh — sandboxed 5-copy layout, single-byte diff detection
# ─────────────────────────────────────────────────────────────────────────
DG_CANON="${TMPROOT}/canon"
mkdir -p "${DG_CANON}/plugins/leadv2/scripts"
printf -- '#!/usr/bin/env bash\necho hello\n' > "${DG_CANON}/plugins/leadv2/scripts/probe.sh"

DG_HOME="${TMPROOT}/home"
mkdir -p "${DG_HOME}/.claude/plugins/cache/leadv2-local/leadv2/0.1.0/scripts"
mkdir -p "${DG_HOME}/.claude/leadv2-shared/scripts"
mkdir -p "${DG_CANON}/.claude/scripts"
# no cross-repo-paths.yaml under DG_HOME -> drift-guard WARNs + skips
# per-repo vendored copies (fine — sandboxed, never touches real yaml).

# 2a. all 3 copies byte-identical to canonical -> OK (exit 0)
cp "${DG_CANON}/plugins/leadv2/scripts/probe.sh" "${DG_HOME}/.claude/plugins/cache/leadv2-local/leadv2/0.1.0/scripts/probe.sh"
cp "${DG_CANON}/plugins/leadv2/scripts/probe.sh" "${DG_HOME}/.claude/leadv2-shared/scripts/probe.sh"
cp "${DG_CANON}/plugins/leadv2/scripts/probe.sh" "${DG_CANON}/.claude/scripts/probe.sh"
if LEADV2_CANONICAL_ROOT="${DG_CANON}" LEADV2_HOME_ROOT="${DG_HOME}" \
   bash "${DRIFT_GUARD}" --quiet; then
  pass "drift-guard: 3 identical copies -> exit 0 (OK)"
else
  fail "drift-guard: identical copies should report OK"
fi

# 2b. flip a single byte in the leadv2-repo-vendored copy only -> DRIFT
#     (exit nonzero), confined entirely to leadv2-repo-vendored
printf -- '#!/usr/bin/env bash\necho hellO\n' > "${DG_CANON}/.claude/scripts/probe.sh"
DG_JSON="$(LEADV2_CANONICAL_ROOT="${DG_CANON}" LEADV2_HOME_ROOT="${DG_HOME}" \
  bash "${DRIFT_GUARD}" --quiet --json)"
DG_RC=$?
if [[ ${DG_RC} -ne 0 ]] && printf -- '%s' "${DG_JSON}" | grep -q 'leadv2-repo-vendored:probe.sh:CONTENT_DIFFERS'; then
  pass "drift-guard: single-byte diff in leadv2-repo-vendored -> detected, exit nonzero"
else
  fail "drift-guard: expected single-byte diff detected in leadv2-repo-vendored (rc=${DG_RC}, json=${DG_JSON})"
fi
ONLY_VENDORED="$(python3 "${CLASSIFY}" "${DG_JSON}")"
if [[ "${ONLY_VENDORED}" == "1" ]]; then
  pass "classify-check: drift-guard output for vendored-only diff classified as vendored-only (1)"
else
  fail "classify-check: expected vendored-only classification (got ${ONLY_VENDORED})"
fi
# restore for the next sub-test
cp "${DG_CANON}/plugins/leadv2/scripts/probe.sh" "${DG_CANON}/.claude/scripts/probe.sh"

# 2c. flip a single byte in plugin-cache (a copy fanout actually reads from)
#     -> classification must NOT be vendored-only
printf -- '#!/usr/bin/env bash\necho hellO\n' > "${DG_HOME}/.claude/plugins/cache/leadv2-local/leadv2/0.1.0/scripts/probe.sh"
DG_JSON2="$(LEADV2_CANONICAL_ROOT="${DG_CANON}" LEADV2_HOME_ROOT="${DG_HOME}" \
  bash "${DRIFT_GUARD}" --quiet --json)"
ONLY_VENDORED2="$(python3 "${CLASSIFY}" "${DG_JSON2}")"
if [[ "${ONLY_VENDORED2}" == "0" ]]; then
  pass "classify-check: drift in plugin-cache classified as NOT vendored-only (must hard-block)"
else
  fail "classify-check: plugin-cache drift incorrectly classified as vendored-only"
fi
# restore
cp "${DG_CANON}/plugins/leadv2/scripts/probe.sh" "${DG_HOME}/.claude/plugins/cache/leadv2-local/leadv2/0.1.0/scripts/probe.sh"

# ─────────────────────────────────────────────────────────────────────────
# 3. leadv2-drift-only-vendored-check.py — direct unit tests (the exact
#    classifier leadv2-fanout.sh's preflight calls) against synthetic
#    drift-guard JSON, covering fanout's 3 real preflight outcomes.
# ─────────────────────────────────────────────────────────────────────────
# 3a. no drift at all -> "0" (the classifier itself must not claim
#     vendored-only on empty entries; fanout never even reaches this branch
#     when drift-guard's own exit code is 0)
NO_DRIFT_JSON='{"drift":false,"entries":[]}'
R3A="$(python3 "${CLASSIFY}" "${NO_DRIFT_JSON}")"
if [[ "${R3A}" == "0" ]]; then
  pass "classify-check: empty entries -> 0 (never falsely proceeds)"
else
  fail "classify-check: empty entries should classify as 0 (got ${R3A})"
fi

# 3b. drift confined to leadv2-repo-vendored -> "1" (fanout: WARN + proceed)
VENDORED_ONLY_JSON='{"drift":true,"entries":["leadv2-repo-vendored:probe.sh:CONTENT_DIFFERS"]}'
R3B="$(python3 "${CLASSIFY}" "${VENDORED_ONLY_JSON}")"
if [[ "${R3B}" == "1" ]]; then
  pass "classify-check: vendored-only drift -> 1 (fanout WARN-and-proceeds, C1 fix)"
else
  fail "classify-check: vendored-only drift should classify as 1 (got ${R3B})"
fi

# 3c. drift touching another copy (even alongside vendored) -> "0" (fanout:
#     hard-block, exit 1)
MIXED_JSON='{"drift":true,"entries":["leadv2-repo-vendored:probe.sh:CONTENT_DIFFERS","plugin-cache:probe.sh:CONTENT_DIFFERS"]}'
R3C="$(python3 "${CLASSIFY}" "${MIXED_JSON}")"
if [[ "${R3C}" == "0" ]]; then
  pass "classify-check: mixed vendored+other-copy drift -> 0 (fanout hard-blocks)"
else
  fail "classify-check: mixed drift should classify as 0 / hard-block (got ${R3C})"
fi

# 3d. malformed JSON -> "0" (fail closed, never fail-open into a false proceed)
MALFORMED='not valid json{{{'
R3D="$(python3 "${CLASSIFY}" "${MALFORMED}")"
if [[ "${R3D}" == "0" ]]; then
  pass "classify-check: malformed JSON -> 0 (fails closed)"
else
  fail "classify-check: malformed JSON should fail closed to 0 (got ${R3D})"
fi

# ─────────────────────────────────────────────────────────────────────────
# 4. vendors_scripts skip mechanism (review-2.md CRITICAL) — the actual C2
#    fix, previously untested: _resolve_project_roots' per-repo emission,
#    _sync_project_root's .claude/scripts/ skip, and drift-guard's per-repo
#    vendored-copy skip. Everything is sandboxed: HOME/LEADV2_CANONICAL_ROOT
#    point at TMPROOT-only paths; the real ~/.claude and
#    ~/Projects/leadv2 trees are never read or written.
# ─────────────────────────────────────────────────────────────────────────
PLUGIN_SYNC="${SCRIPTS_ROOT}/leadv2-plugin-sync.sh"

# Sandbox canonical tree (so PLUGIN_ROOT's -d check + CANONICAL_SCRIPTS resolve)
VS_CANON="${TMPROOT}/vs-canon"
mkdir -p "${VS_CANON}/plugins/leadv2/scripts"
printf -- '#!/usr/bin/env bash\necho hi\n' > "${VS_CANON}/plugins/leadv2/scripts/probe.sh"

# Sandbox HOME (so CROSS_REPO_CONFIG, CACHE_TARGET, SHARED_TARGET all resolve
# under TMPROOT when this subprocess's $HOME is overridden — plugin-sync.sh
# has no LEADV2_HOME_ROOT hook of its own, but every $HOME-derived path in it
# is exactly what a real $HOME override redirects, safely, in a subprocess).
VS_HOME="${TMPROOT}/vs-home"
mkdir -p "${VS_HOME}/.claude/leadv2-shared"

VS_REPO_A="${TMPROOT}/vs-repo-a"
VS_REPO_B="${TMPROOT}/vs-repo-b"
mkdir -p "${VS_REPO_A}" "${VS_REPO_B}"
cat > "${VS_HOME}/.claude/leadv2-shared/cross-repo-paths.yaml" <<YAML
repos:
  repo-a:
    path: "${VS_REPO_A}"
  repo-b:
    path: "${VS_REPO_B}"
    vendors_scripts: false
YAML

# Harness: source only the function-definitions portion of leadv2-plugin-sync.sh
# (everything before its top-level execution body starts at "changed_summary=()")
# in a throwaway bash -c subprocess, then invoke a named function directly.
# Positional params are captured into named vars and cleared (`set --`) BEFORE
# sourcing, so the sourced script's own arg-parsing loop never consumes them.
_vs_call() {
  local func_name="$1"; shift
  # -u LEADV2_PROJECT_ROOT: the calling /leadv2 session may export this for
  # its own orchestration — it must never leak into this sandbox's
  # _resolve_project_roots call (would short-circuit before ever reading the
  # synthetic cross-repo-paths.yaml).
  # PYTHONPATH: overriding HOME below (to sandbox every $HOME-derived path in
  # leadv2-plugin-sync.sh) also relocates python3's user-site-packages lookup
  # (site.getusersitepackages() is HOME-relative) — which is where pyyaml is
  # actually installed on this machine. Pin PYTHONPATH to the REAL user
  # site-packages dir so `import yaml` keeps resolving under the sandboxed HOME.
  env -u LEADV2_PROJECT_ROOT HOME="${VS_HOME}" LEADV2_CANONICAL_ROOT="${VS_CANON}" \
    PYTHONPATH="$(python3 -c 'import site; print(site.getusersitepackages())')" bash -c '
    set -uo pipefail
    plugin_sync="$1"; func_name="$2"; shift 2
    func_args=("$@")
    set --
    # Cut before the top-level execution body (starts at "changed_summary=()")
    # rather than a hardcoded line number — a M-B/L-B-style edit that adds
    # lines above that marker must not silently desync this sandbox harness
    # from real function source.
    cutoff_line="$(grep -n "^changed_summary=()" "${plugin_sync}" | head -1 | cut -d: -f1)"
    cutoff_line="$((cutoff_line - 1))"
    # shellcheck disable=SC1090
    source <(sed -n "1,${cutoff_line}p" "${plugin_sync}")
    "${func_name}" "${func_args[@]}"
  ' _ "${PLUGIN_SYNC}" "${func_name}" "$@"
}

# 4a. _resolve_project_roots distinguishes vendors_scripts:false from default-true
VS_ROOTS_OUT="$(_vs_call _resolve_project_roots)"
if printf -- '%s\n' "${VS_ROOTS_OUT}" | grep -qF "$(printf -- '%s\t%s' "${VS_REPO_A}" "true")"; then
  pass "_resolve_project_roots: repo-a (no vendors_scripts field) -> true"
else
  fail "_resolve_project_roots: expected repo-a -> true (got: ${VS_ROOTS_OUT})"
fi
if printf -- '%s\n' "${VS_ROOTS_OUT}" | grep -qF "$(printf -- '%s\t%s' "${VS_REPO_B}" "false")"; then
  pass "_resolve_project_roots: repo-b (vendors_scripts: false) -> false"
else
  fail "_resolve_project_roots: expected repo-b -> false (got: ${VS_ROOTS_OUT})"
fi

# 4b. _sync_project_root with vendors_scripts=false never creates/touches
#     <root>/.claude/scripts/
VS_TARGET_ROOT="${TMPROOT}/vs-sync-target"
mkdir -p "${VS_TARGET_ROOT}"
_vs_call _sync_project_root "${VS_TARGET_ROOT}" false >/dev/null 2>&1 || true
if [[ ! -e "${VS_TARGET_ROOT}/.claude/scripts" ]]; then
  pass "_sync_project_root: vendors_scripts=false never creates .claude/scripts/"
else
  fail "_sync_project_root: vendors_scripts=false must never create .claude/scripts/ (found: ${VS_TARGET_ROOT}/.claude/scripts)"
fi

# sanity counterpart: vendors_scripts=true (default) DOES populate .claude/scripts/
VS_TARGET_ROOT2="${TMPROOT}/vs-sync-target-true"
mkdir -p "${VS_TARGET_ROOT2}"
_vs_call _sync_project_root "${VS_TARGET_ROOT2}" true >/dev/null 2>&1 || true
if [[ -f "${VS_TARGET_ROOT2}/.claude/scripts/probe.sh" ]]; then
  pass "_sync_project_root: vendors_scripts=true (default) still vendors .claude/scripts/ (no regression)"
else
  fail "_sync_project_root: vendors_scripts=true should still vendor .claude/scripts/probe.sh"
fi

# 4c. drift-guard.sh: a vendors_scripts:false repo whose .claude/scripts/
#     does not exist on disk must NOT appear as a MISSING_DIR entry.
DG2_CANON="${TMPROOT}/dg2-canon"
mkdir -p "${DG2_CANON}/plugins/leadv2/scripts"
printf -- '#!/usr/bin/env bash\necho hi\n' > "${DG2_CANON}/plugins/leadv2/scripts/probe.sh"
DG2_HOME="${TMPROOT}/dg2-home"
mkdir -p "${DG2_HOME}/.claude/plugins/cache/leadv2-local/leadv2/0.1.0/scripts"
mkdir -p "${DG2_HOME}/.claude/leadv2-shared/scripts"
mkdir -p "${DG2_CANON}/.claude/scripts"
cp "${DG2_CANON}/plugins/leadv2/scripts/probe.sh" "${DG2_HOME}/.claude/plugins/cache/leadv2-local/leadv2/0.1.0/scripts/probe.sh"
cp "${DG2_CANON}/plugins/leadv2/scripts/probe.sh" "${DG2_HOME}/.claude/leadv2-shared/scripts/probe.sh"
cp "${DG2_CANON}/plugins/leadv2/scripts/probe.sh" "${DG2_CANON}/.claude/scripts/probe.sh"
DG2_NOVENDOR_REPO="${TMPROOT}/dg2-novendor-repo"
mkdir -p "${DG2_NOVENDOR_REPO}"   # deliberately NO .claude/scripts/ under it
mkdir -p "${DG2_HOME}/.claude/leadv2-shared"
cat > "${DG2_HOME}/.claude/leadv2-shared/cross-repo-paths.yaml" <<YAML
repos:
  no-vendor-repo:
    path: "${DG2_NOVENDOR_REPO}"
    vendors_scripts: false
YAML
DG2_JSON="$(LEADV2_CANONICAL_ROOT="${DG2_CANON}" LEADV2_HOME_ROOT="${DG2_HOME}" \
  bash "${DRIFT_GUARD}" --quiet --json)"
if printf -- '%s' "${DG2_JSON}" | grep -q "no-vendor-repo"; then
  fail "drift-guard: vendors_scripts:false repo with no .claude/scripts/ must never appear in report (got: ${DG2_JSON})"
else
  pass "drift-guard: vendors_scripts:false repo with no .claude/scripts/ produces no MISSING_DIR entry"
fi

echo "---"
if [[ ${FAIL} -eq 0 ]]; then
  echo "ALL TESTS PASSED"
  exit 0
else
  echo "TESTS FAILED"
  exit 1
fi
