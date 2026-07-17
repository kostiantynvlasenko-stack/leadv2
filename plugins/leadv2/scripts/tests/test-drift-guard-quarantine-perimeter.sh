#!/usr/bin/env bash
# tests/test-drift-guard-quarantine-perimeter.sh — DRIFT-GUARD-UNSATISFIABLE-01
# round-2. Coverage for the two Codex REGRESSION findings on e399c95:
#
#   Finding 1 — quarantine-then-reconcile: warn-mode must PRESERVE an un-landed
#     fix to ~/.claude/leadv2-quarantine/<ts>/<copy>/<relpath> BEFORE rsync
#     overwrites it. This test FAILS if quarantine is ever skipped (the e399c95
#     plain-warn regression silently lost exactly this content — a warning in a
#     log nobody reads is not a guard). Verifies: copy reconciled to canonical
#     AND original content present in quarantine AND warning names the path.
#
#   Finding 2 — guard perimeter == warn-mode perimeter: the guard must catch a
#     single-byte divergence in EVERY warn-mode subdir (scripts via PASS 1 +
#     contracts/workflows/hooks/config/skills/commands/agents/docs via PASS 2),
#     and must NOT flag declared runtime state (docs/leadv2/) — proving the
#     exclusion that prevents a perpetual false-RED.
#
# Sandbox-only: LEADV2_CANONICAL_ROOT/LEADV2_HOME_ROOT/LEADV2_QUARANTINE_ROOT
# point at mktemp paths; the real ~/Projects/leadv2 and ~/.claude trees are
# never read or written.
# Run: bash scripts/tests/test-drift-guard-quarantine-perimeter.sh
# Exit 0 = all pass; non-zero = failures found.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PLUGIN_SYNC="${SCRIPTS_ROOT}/leadv2-plugin-sync.sh"
DRIFT_GUARD="${SCRIPTS_ROOT}/leadv2-drift-guard.sh"
CACHE_SYNC_DRIVER="${SCRIPT_DIR}/fixtures/pe_run_cache_sync.sh"

FAIL=0
pass() { printf -- 'PASS: %s\n' "$*"; }
fail() { printf -- 'FAIL: %s\n' "$*" >&2; FAIL=1; }

TMPROOT="$(mktemp -d)"
trap 'rm -rf "${TMPROOT}"' EXIT

# ════════════════════════════════════════════════════════════════════════════
# Finding 1: quarantine-then-reconcile (warn preserves, then reconciles)
# ════════════════════════════════════════════════════════════════════════════
Q_CANON="${TMPROOT}/q-canon"
mkdir -p "${Q_CANON}/plugins/leadv2/scripts"
printf -- '#!/usr/bin/env bash\necho canonical\n' > "${Q_CANON}/plugins/leadv2/scripts/probe.sh"
# canonical MUST be a git repo with probe.sh in history — direction-safety
# shells out to `git log --all -- <relpath>` to decide SAFE vs UNSAFE.
git -C "${Q_CANON}" init -q
git -C "${Q_CANON}" config user.email "test@test.local"
git -C "${Q_CANON}" config user.name "test"
git -C "${Q_CANON}" add -A
git -C "${Q_CANON}" commit -q -m "canonical probe"

Q_HOME="${TMPROOT}/q-home"
Q_CACHE="${Q_HOME}/.claude/plugins/cache/leadv2-local/leadv2/0.1.0/scripts"
Q_QUARANTINE="${TMPROOT}/q-quarantine"
mkdir -p "${Q_CACHE}"
# The copy holds an UN-LANDED FIX canonical has never seen (unique marker).
UNLANDED='#!/usr/bin/env bash
echo UNLANDED-FIX-MARKER-9f3a7c1e
'
printf -- '%s' "${UNLANDED}" > "${Q_CACHE}/probe.sh"

SYNC_STDERR="${TMPROOT}/sync-stderr.log"
env -u LEADV2_PROJECT_ROOT \
  HOME="${Q_HOME}" LEADV2_CANONICAL_ROOT="${Q_CANON}" \
  LEADV2_QUARANTINE_ROOT="${Q_QUARANTINE}" \
  PYTHONPATH="$(python3 -c 'import site; print(site.getusersitepackages())')" \
  bash "${CACHE_SYNC_DRIVER}" "${PLUGIN_SYNC}" "${SCRIPTS_ROOT}" \
  "${Q_CANON}/plugins/leadv2/scripts/" "${Q_CACHE}" \
  > /dev/null 2> "${SYNC_STDERR}"

# 1a. copy reconciled to canonical (the guard-satisfiability property).
if diff -q "${Q_CANON}/plugins/leadv2/scripts/probe.sh" "${Q_CACHE}/probe.sh" >/dev/null 2>&1; then
  pass "quarantine: cache/probe.sh reconciled to canonical (guard stays satisfiable)"
else
  fail "quarantine: cache/probe.sh should be reconciled to canonical (got: $(cat "${Q_CACHE}/probe.sh"))"
fi

# 1b. original un-landed content PRESERVED in quarantine (the nothing-lost
#     property). This is the bar e399c95 failed — plain-warn left no
#     quarantine at all. FAILS if quarantine is ever skipped.
Q_PRESERVED="$(find "${Q_QUARANTINE}" -path '*/cache/scripts/probe.sh' -type f 2>/dev/null | head -1)"
if [[ -n "${Q_PRESERVED}" ]] && [[ -f "${Q_PRESERVED}" ]]; then
  pass "quarantine: original content preserved at ${Q_PRESERVED}"
else
  fail "quarantine: expected preserved copy under ${Q_QUARANTINE}/*/cache/scripts/probe.sh — NONE FOUND (quarantine was skipped)"
fi
# 1c. preserved content byte-identical to what we put there.
if [[ -n "${Q_PRESERVED}" ]] && diff -q <(printf -- '%s' "${UNLANDED}") "${Q_PRESERVED}" >/dev/null 2>&1; then
  pass "quarantine: preserved content byte-identical to the un-landed fix"
else
  fail "quarantine: preserved content must byte-match the un-landed fix (path=${Q_PRESERVED})"
fi
# 1d. warning named the quarantine path (recoverable: one `cp` away).
if grep -q "warn+quarantine" "${SYNC_STDERR}" && grep -qF "${Q_QUARANTINE}" "${SYNC_STDERR}"; then
  pass "quarantine: warning named the warn+quarantine mode + the quarantine root"
else
  fail "quarantine: warning must name warn+quarantine + quarantine path (stderr: $(tr '\n' ' ' < "${SYNC_STDERR}"))"
fi

# ════════════════════════════════════════════════════════════════════════════
# Finding 2: guard catches divergence in EVERY warn-mode subdir (per copy,
# the perimeter the sync --delete-pushes), and ignores runtime state.
# ════════════════════════════════════════════════════════════════════════════
P_CANON="${TMPROOT}/p-canon"
P_PLUGIN="${P_CANON}/plugins/leadv2"
mkdir -p "${P_PLUGIN}"/{scripts,contracts,workflows,hooks,config,skills,commands,agents,docs}
mkdir -p "${P_PLUGIN}/docs/leadv2"   # runtime-state location (must be excluded)
printf 'scripts-v\n'   > "${P_PLUGIN}/scripts/probe.sh"
printf 'contracts-v\n' > "${P_PLUGIN}/contracts/probe.json"
printf 'workflows-v\n' > "${P_PLUGIN}/workflows/probe.js"
printf 'hooks-v\n'     > "${P_PLUGIN}/hooks/probe.sh"
printf 'config-v\n'    > "${P_PLUGIN}/config/probe.yaml"
printf 'skills-v\n'    > "${P_PLUGIN}/skills/probe.md"
printf 'commands-v\n'  > "${P_PLUGIN}/commands/probe.md"
printf 'agents-v\n'    > "${P_PLUGIN}/agents/probe.md"
printf 'docs-v\n'      > "${P_PLUGIN}/docs/probe.md"
printf 'runtime-v\n'   > "${P_PLUGIN}/docs/leadv2/active.yaml"

P_HOME="${TMPROOT}/p-home"
P_CACHE="${P_HOME}/.claude/plugins/cache/leadv2-local/leadv2/0.1.0"
P_SHARED="${P_HOME}/.claude/leadv2-shared"
P_VENDORED="${P_CANON}/.claude/scripts"   # leadv2-repo-vendored copy

# Mirror: plugin-cache = full plugin tree (all 9 subdirs); shared = scripts+
# contracts; vendored = scripts-only. No cross-repo-paths.yaml -> guard WARNs
# and skips per-repo vendored copies (sandbox, never touches real yaml).
mkdir -p "${P_CACHE}"
for sub in scripts contracts workflows hooks config skills commands agents docs; do
  cp -R "${P_PLUGIN}/${sub}" "${P_CACHE}/${sub}"
done
mkdir -p "${P_SHARED}/scripts" "${P_SHARED}/contracts" "${P_VENDORED}"
cp "${P_PLUGIN}/scripts/probe.sh"     "${P_SHARED}/scripts/probe.sh"
cp "${P_PLUGIN}/contracts/probe.json" "${P_SHARED}/contracts/probe.json"
cp "${P_PLUGIN}/scripts/probe.sh"     "${P_VENDORED}/probe.sh"

# 2-base. healthy baseline -> exit 0 (no false-RED from the new PASS 2).
if LEADV2_CANONICAL_ROOT="${P_CANON}" LEADV2_HOME_ROOT="${P_HOME}" \
   bash "${DRIFT_GUARD}" --quiet >/dev/null 2>&1; then
  pass "perimeter: healthy baseline (all 9 subdirs mirrored) -> exit 0"
else
  fail "perimeter: healthy baseline should exit 0 (PASS 2 false-RED?)"
fi

# 2-loop. per warn-mode subdir: perturb the plugin-cache copy, expect the
# guard to catch it with the exact entry. scripts uses PASS 1 (no subdir
# prefix in the relpath); the other 8 use PASS 2 (<subdir>/<file>).
# format: <subdir>|<file-within-subdir>|<expected-entry-suffix>
CASES=(
  "scripts|probe.sh|probe.sh"
  "contracts|probe.json|contracts/probe.json"
  "workflows|probe.js|workflows/probe.js"
  "hooks|probe.sh|hooks/probe.sh"
  "config|probe.yaml|config/probe.yaml"
  "skills|probe.md|skills/probe.md"
  "commands|probe.md|commands/probe.md"
  "agents|probe.md|agents/probe.md"
  "docs|probe.md|docs/probe.md"
)
for c in "${CASES[@]}"; do
  sub="${c%%|*}"; rest="${c#*|}"; file="${rest%%|*}"; entry_suffix="${rest#*|}"
  cache_file="${P_CACHE}/${sub}/${file}"
  canon_file="${P_PLUGIN}/${sub}/${file}"
  printf 'PERTURBED\n' >> "${cache_file}"   # single change, in place
  json="$(LEADV2_CANONICAL_ROOT="${P_CANON}" LEADV2_HOME_ROOT="${P_HOME}" \
    bash "${DRIFT_GUARD}" --quiet --json 2>/dev/null)"; rc=$?
  if [[ ${rc} -ne 0 ]] && printf '%s' "${json}" | grep -qF "plugin-cache:${entry_suffix}:CONTENT_DIFFERS"; then
    pass "perimeter: ${sub}/ divergence caught (rc!=0, entry plugin-cache:${entry_suffix}:CONTENT_DIFFERS)"
  else
    fail "perimeter: ${sub}/ divergence should be caught (rc=${rc}, json=${json})"
  fi
  cp "${canon_file}" "${cache_file}"   # restore for the next sub-case
done

# 2-runtime. docs/leadv2/ is declared runtime state — perturbing the cache's
# copy must NOT flag (proves the exclusion that keeps a healthy system GREEN).
printf 'runtime-PERTURBED\n' > "${P_CACHE}/docs/leadv2/active.yaml"
if LEADV2_CANONICAL_ROOT="${P_CANON}" LEADV2_HOME_ROOT="${P_HOME}" \
   bash "${DRIFT_GUARD}" --quiet >/dev/null 2>&1; then
  pass "perimeter: docs/leadv2/ runtime state excluded (perturbed, no drift)"
else
  fail "perimeter: docs/leadv2/ runtime state should be excluded but flagged drift"
fi
cp "${P_PLUGIN}/docs/leadv2/active.yaml" "${P_CACHE}/docs/leadv2/active.yaml"

echo "---"
if [[ ${FAIL} -eq 0 ]]; then
  echo "ALL TESTS PASSED"
  exit 0
else
  echo "TESTS FAILED"
  exit 1
fi
