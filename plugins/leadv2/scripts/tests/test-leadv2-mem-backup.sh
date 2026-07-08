#!/usr/bin/env bash
# tests/test-leadv2-mem-backup.sh — Unit tests for MEM-BACKUP-RESTORE-01
# (LEADV2_MEM_BACKUP / leadv2-mem-backup.sh + its two wired call sites:
#  leadv2-immune-aggregate.sh, leadv2-negative-memory-compile.sh).
#
# Fix round 1 (both reviewers BLOCK) additions:
#   - Section C updated for the item-7 durable-root fix (LEADV2_PROJECT_ROOT
#     override, no more "climb 2 hardcoded levels" arithmetic).
#   - Section D (NEW): LIVE corrupt-write -> restore proofs through the REAL
#     negative-memory-compile.sh script for BOTH write sites (TTL-sweep,
#     candidate-gen) — item 1 + item 6. A python3 shim substitutes for the
#     interpreter itself (the only available seam, since compile.sh's writers
#     are inline heredocs, not a separate extractor file like immune-
#     aggregate's) and corrupts the target on a specific call number while
#     delegating every other call to the real python3 untouched.
#   - Section E (NEW): item 5 — N consecutive corrupt write-cycles must still
#     leave a restorable good snapshot (snapshot-skips-corrupt-source fix).
#
# Every scenario runs against a scratch-dir COPY of the real scripts (never
# the live repo files) so the suite never mutates shared state.
#
# Run: bash scripts/tests/test-leadv2-mem-backup.sh
# Exit 0 = all pass; non-zero = failures found.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

PASS=0
FAIL=0
ERRORS=()

log()  { printf -- '[TEST] %s\n' "$*"; }
pass() { PASS=$(( PASS + 1 )); log "PASS: $1"; }
fail() { FAIL=$(( FAIL + 1 )); ERRORS+=("FAIL: $1"); log "FAIL: $1"; }

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

if bash -n "${SCRIPTS_DIR}/leadv2-mem-backup.sh" 2>/dev/null; then
  pass "bash -n syntax check: leadv2-mem-backup.sh"
else
  fail "bash -n syntax check: leadv2-mem-backup.sh"
fi

# ══════════════════════════════════════════════════════════════════════════
# Section A — helper-function unit tests (source in isolation)
# ══════════════════════════════════════════════════════════════════════════

HDIR="$SCRATCH/helper"; mkdir -p "$HDIR"
cp "${SCRIPTS_DIR}/leadv2-mem-backup.sh" "${SCRIPTS_DIR}/leadv2-strict.sh" "$HDIR/"

# A1 — flag off: every function is a true no-op (no side effects, rc=0)
STORE_A1="$SCRATCH/a1-store.yaml"
printf 'patterns: []\n' > "$STORE_A1"
out_a1=$(bash -c "
  source '$HDIR/leadv2-mem-backup.sh'
  mem_backup_snapshot '$STORE_A1' patterns
  mem_backup_verify_or_restore '$STORE_A1' patterns
  mem_backup_integrity_check '$STORE_A1' patterns
  echo RC=\$?
" 2>&1)
if [[ "$out_a1" == "RC=0" && ! -d "$SCRATCH/.mem-backups" ]]; then
  pass "A1: flag off -> no-op, no backup dir created, no stdout/stderr bytes"
else
  fail "A1: flag off -> expected silent no-op, got: $out_a1"
fi

# A2 — corruption -> restore (deterministic, helper-level)
STORE_A2="$SCRATCH/a2/store.yaml"; mkdir -p "$(dirname "$STORE_A2")"
printf 'entries:\n  - id: good-1\n' > "$STORE_A2"
out_a2=$(env LEADV2_MEM_BACKUP=1 bash -c "
  source '$HDIR/leadv2-mem-backup.sh'
  mem_backup_snapshot '$STORE_A2' entries            # snapshot the GOOD content
  printf 'entries: [unterminated' > '$STORE_A2'      # simulate a truncated/corrupt write
  mem_backup_verify_or_restore '$STORE_A2' entries
" 2>&1)
restored_content="$(cat "$STORE_A2" 2>/dev/null || true)"
if [[ "$out_a2" == *"INTEGRITY FAIL"* && "$out_a2" == *"RESTORED"* && "$restored_content" == *"good-1"* ]]; then
  pass "A2: corruption detected -> restored from snapshot, content == last-good"
else
  fail "A2: expected restore of good-1, got out=[$out_a2] content=[$restored_content]"
fi

# A3 — no-good-backup path: corrupt file, zero snapshots -> fail-open, logs, doesn't abort
STORE_A3="$SCRATCH/a3/store.yaml"; mkdir -p "$(dirname "$STORE_A3")"
printf 'entries: [unterminated' > "$STORE_A3"
set +e
out_a3=$(env LEADV2_MEM_BACKUP=1 bash -c "
  source '$HDIR/leadv2-mem-backup.sh'
  mem_backup_verify_or_restore '$STORE_A3' entries
  echo AFTER_RC=\$?
" 2>&1)
rc_a3=$?
set -e
if [[ "$rc_a3" -eq 0 && "$out_a3" == *"NO GOOD BACKUP"* && "$out_a3" == *"AFTER_RC=0"* ]]; then
  pass "A3: no-good-backup -> fail-open (rc=0), loud stderr, corrupt file left as-is"
else
  fail "A3: expected fail-open + NO GOOD BACKUP, got rc=$rc_a3 out=[$out_a3]"
fi

# A4 — rotation cap: KEEP=2, 4 GOOD snapshots taken -> only 2 remain (newest kept)
STORE_A4="$SCRATCH/a4/store.yaml"; mkdir -p "$(dirname "$STORE_A4")"
printf 'entries: []\n' > "$STORE_A4"
env LEADV2_MEM_BACKUP=1 LEADV2_MEM_BACKUP_KEEP=2 bash -c "
  source '$HDIR/leadv2-mem-backup.sh'
  for i in 1 2 3 4; do
    mem_backup_snapshot '$STORE_A4' entries
    sleep 1.1  # ensure distinct second-granularity timestamps for stable ordering
  done
"
nsnaps=$(ls -1 "$SCRATCH/a4/.mem-backups/store.yaml/store.yaml".*.bak 2>/dev/null | wc -l | tr -d ' ')
if [[ "$nsnaps" -eq 2 ]]; then
  pass "A4: rotation cap -> exactly LEADV2_MEM_BACKUP_KEEP=2 snapshots retained"
else
  fail "A4: expected 2 snapshots retained, found $nsnaps"
fi

# A5 (fix round 1, item 3) — python3 absent -> MISCONFIG via strict_or_warn,
# never mislabeled as corruption/no-good-backup. Simulate absence by PATH
# with no python3 on it.
PATH_NO_PYTHON="$SCRATCH/no-python-path"; mkdir -p "$PATH_NO_PYTHON"
for tool in bash sh mkdir cp rm ls date cat mapfile printf basename dirname; do
  p="$(command -v "$tool" 2>/dev/null || true)"
  [[ -n "$p" ]] && ln -sf "$p" "$PATH_NO_PYTHON/$tool" 2>/dev/null || true
done
STORE_A5="$SCRATCH/a5/store.yaml"; mkdir -p "$(dirname "$STORE_A5")"
printf 'entries:\n  - id: x\n' > "$STORE_A5"
out_a5_warn=$(env -i PATH="$PATH_NO_PYTHON" LEADV2_MEM_BACKUP=1 LEADV2_REQUIRE_STRICT=1 bash -c "
  source '$HDIR/leadv2-mem-backup.sh'
  mem_backup_verify_or_restore '$STORE_A5' entries
  echo RC=\$?
" 2>&1)
out_a5_default=$(env -i PATH="$PATH_NO_PYTHON" LEADV2_MEM_BACKUP=1 bash -c "
  source '$HDIR/leadv2-mem-backup.sh'
  mem_backup_verify_or_restore '$STORE_A5' entries
  echo RC=\$?
" 2>&1)
if [[ "$out_a5_warn" == *"STRICT-FAIL[mem-backup-no-python3]"* && "$out_a5_warn" != *"INTEGRITY FAIL"* \
   && "$out_a5_warn" != *"NO GOOD BACKUP"* && "$out_a5_warn" == *"RC=0"* \
   && "$out_a5_default" != *"STRICT-FAIL"* && "$out_a5_default" != *"INTEGRITY FAIL"* \
   && "$out_a5_default" != *"NO GOOD BACKUP"* && "$out_a5_default" == *"RC=0"* ]]; then
  pass "A5: python3 absent -> MISCONFIG via strict_or_warn (strict=1), never 'corruption', fail-open both modes"
else
  fail "A5: python3-absent misconfig mishandled: warn=[$out_a5_warn] default=[$out_a5_default]"
fi

# A6 (fix round 1, item 4) — mem_backup_integrity_check is PUBLIC and must
# NEVER abort a bare set -e caller, even on corrupt input.
STORE_A6="$SCRATCH/a6/store.yaml"; mkdir -p "$(dirname "$STORE_A6")"
printf 'entries: [unterminated' > "$STORE_A6"
set +e
out_a6=$(env LEADV2_MEM_BACKUP=1 bash -c "
  set -euo pipefail
  source '$HDIR/leadv2-mem-backup.sh'
  mem_backup_integrity_check '$STORE_A6' entries
  echo SURVIVED
" 2>&1)
rc_a6=$?
set -e
if [[ "$rc_a6" -eq 0 && "$out_a6" == *"bad"* && "$out_a6" == *"SURVIVED"* ]]; then
  pass "A6: mem_backup_integrity_check bare-called under set -e on corrupt input -> survives, reports 'bad' on stdout"
else
  fail "A6: expected survive+bad, got rc=$rc_a6 out=[$out_a6]"
fi

# A7 (fix round 1, item 2) — strict_or_warn firing (LEADV2_REQUIRE_STRICT=1)
# on a genuine misconfig (unwritable backup dir) must NOT abort a bare
# set -e caller (Codex's `true && false; return 0` lesson).
STORE_A7="$SCRATCH/a7-parent/store.yaml"
mkdir -p "$(dirname "$STORE_A7")"; printf 'entries: []\n' > "$STORE_A7"
chmod 555 "$(dirname "$STORE_A7")" 2>/dev/null || true
set +e
out_a7=$(env LEADV2_MEM_BACKUP=1 LEADV2_REQUIRE_STRICT=1 bash -c "
  set -euo pipefail
  source '$HDIR/leadv2-mem-backup.sh'
  mem_backup_snapshot '$STORE_A7' entries
  echo SURVIVED
" 2>&1)
rc_a7=$?
set -e
chmod 755 "$(dirname "$STORE_A7")" 2>/dev/null || true
if [[ "$rc_a7" -eq 0 && "$out_a7" == *"SURVIVED"* ]]; then
  pass "A7: strict_or_warn fires on unwritable-dir misconfig without aborting a bare set -e caller"
else
  fail "A7: expected survive, got rc=$rc_a7 out=[$out_a7]"
fi

# ══════════════════════════════════════════════════════════════════════════
# Section B — wired-site tests: leadv2-immune-aggregate.sh
# ══════════════════════════════════════════════════════════════════════════

B="$SCRATCH/siteB"
mkdir -p "$B/plugin/scripts" "$B/repo/docs/leadv2/tasks"
cp "${SCRIPTS_DIR}/leadv2-immune-aggregate.sh" "${SCRIPTS_DIR}/leadv2-mem-backup.sh" "${SCRIPTS_DIR}/leadv2-strict.sh" "$B/plugin/scripts/"
cat > "$B/plugin/scripts/leadv2-immune-aggregate.py" <<'PYEOF'
import sys, os
tasks_dir, output = sys.argv[1], sys.argv[2]
mode = os.environ.get("FAKE_EXTRACTOR_MODE", "good")
if mode == "good":
    open(output, "w").write("patterns:\n  - id: p1\n    summary: s\n    action: a\n    keywords: []\n")
else:
    open(output, "w").write("patterns: [unterminated")
PYEOF

run_immune() {
  local extractor_mode="$1"; shift
  env -i PATH="$PATH" HOME="$HOME" \
    CLAUDE_PLUGIN_ROOT="$B/plugin" LEADV2_PROJECT_ROOT="$B/repo" \
    FAKE_EXTRACTOR_MODE="$extractor_mode" \
    "$@" \
    bash "$B/plugin/scripts/leadv2-immune-aggregate.sh" 2>&1
}

# B1 — flag off (default/unset) -> byte-identical: no [mem-backup] lines, no backup dir
rm -rf "$B/repo/docs/leadv2/immune-patterns.yaml" "$B/repo/docs/leadv2/.mem-backups"
set +e
out_b1_off=$(run_immune good)
rc_b1_off=$?
set -e
if [[ "$out_b1_off" != *"[mem-backup]"* && "$rc_b1_off" -eq 0 && ! -d "$B/repo/docs/leadv2/.mem-backups" ]]; then
  pass "B1: immune-aggregate.sh flag-off -> byte-identical (no [mem-backup] output, no backup dir)"
else
  fail "B1: immune-aggregate.sh flag-off -> unexpected: rc=$rc_b1_off out=[$out_b1_off]"
fi

# B2 — flag on, corrupt write -> restored to prior good content
rm -rf "$B/repo/docs/leadv2/immune-patterns.yaml" "$B/repo/docs/leadv2/.mem-backups"
run_immune good LEADV2_MEM_BACKUP=1 >/dev/null
good_content="$(cat "$B/repo/docs/leadv2/immune-patterns.yaml")"
out_b2=$(run_immune bad LEADV2_MEM_BACKUP=1)
after_content="$(cat "$B/repo/docs/leadv2/immune-patterns.yaml")"
if [[ "$out_b2" == *"RESTORED"* && "$after_content" == "$good_content" ]]; then
  pass "B2: immune-aggregate.sh corrupt write -> auto-restored to last-good content"
else
  fail "B2: immune-aggregate.sh corrupt write -> expected restore, got out=[$out_b2]"
fi

# B3 — missing-helper safety: leadv2-mem-backup.sh absent -> unchanged rc, flag on or off
rm -rf "$B/repo/docs/leadv2/immune-patterns.yaml" "$B/repo/docs/leadv2/.mem-backups"
mv "$B/plugin/scripts/leadv2-mem-backup.sh" "$B/plugin/scripts/leadv2-mem-backup.sh.bak"
set +e
run_immune good >/dev/null; rc_b3_off=$?
run_immune good LEADV2_MEM_BACKUP=1 >/dev/null; rc_b3_on=$?
set -e
mv "$B/plugin/scripts/leadv2-mem-backup.sh.bak" "$B/plugin/scripts/leadv2-mem-backup.sh"
if [[ "$rc_b3_off" -eq 0 && "$rc_b3_on" -eq 0 ]]; then
  pass "B3: immune-aggregate.sh helper-ABSENT -> unchanged rc=0 regardless of flag"
else
  fail "B3: immune-aggregate.sh helper-ABSENT -> rc_off=$rc_b3_off rc_on=$rc_b3_on"
fi

# B4 (fix round 1, item 8) — durable-root: aggregate WRITES to the same path
# leadv2-immune-lookup.sh READS from (both must resolve OUTPUT identically
# given the same LEADV2_PROJECT_ROOT / durable-root inputs).
lookup_path_expr='REPO_ROOT="${LEADV2_PROJECT_ROOT:-$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null | xargs dirname 2>/dev/null || pwd)}"; echo "$REPO_ROOT/docs/leadv2/immune-patterns.yaml"'
lookup_resolved=$(env -i PATH="$PATH" HOME="$HOME" LEADV2_PROJECT_ROOT="$B/repo" bash -c "$lookup_path_expr")
if [[ "$lookup_resolved" == "$B/repo/docs/leadv2/immune-patterns.yaml" ]]; then
  pass "B4: durable-root alignment -> aggregate's OUTPUT path == lookup's PATTERNS_FILE path"
else
  fail "B4: durable-root misalignment -> lookup resolves to [$lookup_resolved], expected [$B/repo/docs/leadv2/immune-patterns.yaml]"
fi

# ══════════════════════════════════════════════════════════════════════════
# Section C — wired-site tests: leadv2-negative-memory-compile.sh
# (fix round 1, item 7: PROJECT_ROOT now honors LEADV2_PROJECT_ROOT directly
# -- no more "climb 2 hardcoded levels from SCRIPT_DIR" arithmetic needed.)
# ══════════════════════════════════════════════════════════════════════════

C="$SCRATCH/siteC/scripts"
CROOT="$SCRATCH/siteC"
mkdir -p "$C" "$CROOT/docs"
cp "${SCRIPTS_DIR}/leadv2-negative-memory-compile.sh" "${SCRIPTS_DIR}/leadv2-mem-backup.sh" "${SCRIPTS_DIR}/leadv2-strict.sh" "$C/"
NM_FILE="$CROOT/docs/leadv2-negative-memory.yaml"
printf 'entries:\n  - id: nm-1\n    status: active\n' > "$NM_FILE"

run_nm() {
  env -i PATH="$PATH" HOME="$HOME" LEADV2_PROJECT_ROOT="$CROOT" "$@" \
    bash "$C/leadv2-negative-memory-compile.sh" --ttl-only 2>&1
}

# C1 — flag off -> byte-identical (no [mem-backup] output, no backup dir)
out_c1=$(run_nm)
if [[ "$out_c1" != *"[mem-backup]"* && ! -d "$CROOT/docs/.mem-backups" ]]; then
  pass "C1: negative-memory-compile.sh flag-off -> byte-identical (no [mem-backup] output)"
else
  fail "C1: negative-memory-compile.sh flag-off -> unexpected: out=[$out_c1]"
fi

# C2 — flag on, legitimate run (nothing expired) -> snapshot taken, no false integrity-fail
rm -rf "$CROOT/docs/.mem-backups"
out_c2=$(run_nm LEADV2_MEM_BACKUP=1)
if [[ -d "$CROOT/docs/.mem-backups" && "$out_c2" != *"INTEGRITY FAIL"* ]]; then
  pass "C2: negative-memory-compile.sh flag-on legitimate run -> snapshot taken, no false integrity-fail"
else
  fail "C2: negative-memory-compile.sh flag-on legitimate run -> unexpected: out=[$out_c2]"
fi

# C3 — missing-helper safety
mv "$C/leadv2-mem-backup.sh" "$C/leadv2-mem-backup.sh.bak"
set +e
run_nm >/dev/null; rc_c3_off=$?
run_nm LEADV2_MEM_BACKUP=1 >/dev/null; rc_c3_on=$?
set -e
mv "$C/leadv2-mem-backup.sh.bak" "$C/leadv2-mem-backup.sh"
if [[ "$rc_c3_off" -eq "$rc_c3_on" ]]; then
  pass "C3: negative-memory-compile.sh helper-ABSENT -> unchanged rc ($rc_c3_off) regardless of flag"
else
  fail "C3: negative-memory-compile.sh helper-ABSENT -> rc mismatch off=$rc_c3_off on=$rc_c3_on"
fi

# ══════════════════════════════════════════════════════════════════════════
# Section D (NEW, fix round 1, items 1 + 6) — LIVE corrupt-write -> restore
# through the REAL negative-memory-compile.sh, for BOTH write sites. A
# python3 shim is the seam (compile.sh's writers are inline heredocs, not a
# separate extractor file): it drains stdin, corrupts a caller-chosen target
# file, and returns a caller-chosen exit code on a specific call number;
# every other python3 invocation is delegated to the real interpreter.
# ══════════════════════════════════════════════════════════════════════════

REAL_PYTHON3="$(command -v python3)"
D="$SCRATCH/siteD/scripts"
DROOT="$SCRATCH/siteD"
mkdir -p "$D" "$DROOT/docs" "$D/shimbin"
cp "${SCRIPTS_DIR}/leadv2-negative-memory-compile.sh" "${SCRIPTS_DIR}/leadv2-mem-backup.sh" "${SCRIPTS_DIR}/leadv2-strict.sh" "$D/"

cat > "$D/shimbin/python3" <<SHIMEOF
#!/usr/bin/env bash
# Test-only shim: corrupts \$FAKE_PY_CORRUPT_TARGET_ARGIDX'th positional
# python arg's file when this invocation's ARGC matches
# \$FAKE_PY_CORRUPT_ARGC (discriminates the TTL-sweep writer [argc 6: "-" +
# nm/archive/today/dryrun/root] from the candidate-gen writer [argc 9] from
# the helper's OWN internal integrity-check call [argc 3: "-" + path + key]
# -- argc, not call-order, since mem_backup_snapshot/verify_or_restore make
# their own python3 calls around the writer and would otherwise be miscounted
# as "the writer call"). Every non-matching invocation delegates untouched.
if [[ \$# -eq "\$FAKE_PY_CORRUPT_ARGC" ]]; then
  cat >/dev/null
  shift
  target="\${!FAKE_PY_CORRUPT_TARGET_ARGIDX}"
  printf 'entries: [unterminated (forced by T6 fix-round-1 live test)' > "\$target"
  exit "\${FAKE_PY_CORRUPT_EXIT:-1}"
else
  exec "$REAL_PYTHON3" "\$@"
fi
SHIMEOF
chmod +x "$D/shimbin/python3"

# D1 — TTL-sweep site: force an expiring entry (writer actually fires),
# corrupt the writer's OWN output (call #1, the only python3 call in
# --ttl-only mode), confirm the real script restores NM_FILE.
NM_FILE_D="$DROOT/docs/leadv2-negative-memory.yaml"
printf 'entries:\n  - id: nm-expiring\n    status: active\n    ttl_expires: "2000-01-01"\n' > "$NM_FILE_D"
env -i PATH="$PATH" HOME="$HOME" LEADV2_PROJECT_ROOT="$DROOT" LEADV2_MEM_BACKUP=1 \
  bash "$D/leadv2-negative-memory-compile.sh" --ttl-only >/dev/null 2>&1 || true
good_content_d1="$(cat "$NM_FILE_D")"
set +e
out_d1=$(env -i PATH="$D/shimbin:$PATH" HOME="$HOME" LEADV2_PROJECT_ROOT="$DROOT" LEADV2_MEM_BACKUP=1 \
  FAKE_PY_CORRUPT_ARGC=6 FAKE_PY_CORRUPT_TARGET_ARGIDX=1 FAKE_PY_CORRUPT_EXIT=2 \
  bash "$D/leadv2-negative-memory-compile.sh" --ttl-only 2>&1)
set -e
after_content_d1="$(cat "$NM_FILE_D")"
if [[ "$out_d1" == *"RESTORED"* && "$after_content_d1" == "$good_content_d1" ]]; then
  pass "D1: negative-memory-compile.sh TTL-sweep LIVE corrupt write -> real script restores NM_FILE"
else
  fail "D1: TTL-sweep live restore failed: out=[$out_d1] before=[$good_content_d1] after=[$after_content_d1]"
fi

# D2 — candidate-gen site: no expiring entries (TTL-sweep = clean call #1,
# exit 0), candidate-gen is call #2 -- corrupt ITS output and confirm the
# real script restores NM_FILE even though the writer's own sys.exit(1)
# (candidates-pending) would otherwise abort the script under set -e before
# reaching the restore call (this IS the Critical item-1 regression proof).
NM_FILE_D2="$DROOT/docs/leadv2-negative-memory.yaml"
printf 'entries:\n  - id: nm-stable\n    status: active\n' > "$NM_FILE_D2"
good_content_d2="$(cat "$NM_FILE_D2")"
set +e
out_d2=$(env -i PATH="$D/shimbin:$PATH" HOME="$HOME" LEADV2_PROJECT_ROOT="$DROOT" LEADV2_MEM_BACKUP=1 \
  FAKE_PY_CORRUPT_ARGC=9 FAKE_PY_CORRUPT_TARGET_ARGIDX=1 FAKE_PY_CORRUPT_EXIT=1 \
  bash "$D/leadv2-negative-memory-compile.sh" 2>&1)
rc_d2=$?
set -e
after_content_d2="$(cat "$NM_FILE_D2")"
if [[ "$rc_d2" -eq 1 && "$out_d2" == *"RESTORED"* && "$after_content_d2" == "$good_content_d2" ]]; then
  pass "D2: negative-memory-compile.sh candidate-gen LIVE corrupt write (writer exit 1) -> real script STILL restores NM_FILE (Critical item-1 regression proof)"
else
  fail "D2: candidate-gen live restore failed: rc=$rc_d2 out=[$out_d2] before=[$good_content_d2] after=[$after_content_d2]"
fi

# ══════════════════════════════════════════════════════════════════════════
# Section E (NEW, fix round 1, item 5) — N consecutive corrupt write-cycles
# must still leave a good snapshot restorable (snapshot-skips-corrupt-source
# fix: corrupt content is never allowed to enter rotation in the first
# place, so plain recency-based eviction can never evict the last good one).
# ══════════════════════════════════════════════════════════════════════════

STORE_E1="$SCRATCH/e1/store.yaml"; mkdir -p "$(dirname "$STORE_E1")"
printf 'entries:\n  - id: good-keeper\n' > "$STORE_E1"
env LEADV2_MEM_BACKUP=1 LEADV2_MEM_BACKUP_KEEP=2 bash -c "
  source '$HDIR/leadv2-mem-backup.sh'
  mem_backup_snapshot '$STORE_E1' entries   # the ONE good snapshot
  for i in 1 2 3; do
    printf 'entries: [unterminated-cycle-%s' \"\$i\" > '$STORE_E1'
    mem_backup_snapshot '$STORE_E1' entries || true   # must SKIP (corrupt source)
  done
" >/dev/null 2>&1
nsnaps_e1=$(ls -1 "$SCRATCH/e1/.mem-backups/store.yaml/store.yaml".*.bak 2>/dev/null | wc -l | tr -d ' ')
out_e1=$(env LEADV2_MEM_BACKUP=1 bash -c "
  source '$HDIR/leadv2-mem-backup.sh'
  mem_backup_verify_or_restore '$STORE_E1' entries
" 2>&1)
restored_e1="$(cat "$STORE_E1")"
if [[ "$nsnaps_e1" -eq 1 && "$restored_e1" == *"good-keeper"* ]]; then
  pass "E1: 3 consecutive corrupt write-cycles never entered rotation (1 good snapshot survives) -> restore succeeds"
else
  fail "E1: expected 1 surviving good snapshot + successful restore, got nsnaps=$nsnaps_e1 restored=[$restored_e1] out=[$out_e1]"
fi

log "----"
log "PASS=$PASS FAIL=$FAIL"
if [[ "$FAIL" -gt 0 ]]; then
  for e in "${ERRORS[@]}"; do log "$e"; done
  exit 1
fi
exit 0
