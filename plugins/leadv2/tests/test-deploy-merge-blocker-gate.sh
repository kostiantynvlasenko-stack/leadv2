#!/usr/bin/env bash
# tests/test-deploy-merge-blocker-gate.sh — RISK-7-PERSIST-MERGE-RACE-01 smoke test.
#
# Scenario 1 (Step-0 divergence-preflight rebase conflict — NOT the literal
#   `git merge --ff-only` site; local main and a post-fork origin/main commit
#   conflict on the same line, so deploy-merge.sh's auto-rebase-of-current-
#   branch step fails):
#   1. leadv2-deploy-merge.sh exits nonzero and writes
#      docs/handoff/<task>/merge-blocker.flag with the expected reason.
#   2. leadv2-phase8-assert.sh's A6 check fails (exit 1, no phase8-passed.flag)
#      even with A1-A5 artifacts seeded (non-terminal tasks.yaml status).
#   3. leadv2-queue-release.sh (the DAEMON/lane-queue completion path —
#      leadv2-daemon.sh:584 / leadv2-helpers.sh::leadv2_po_release both call
#      this, bypassing render-close.sh entirely) does NOT flip tasks.yaml to
#      status=done while the blocker is present — proves the guard lives in
#      the true chokepoint (leadv2-tasks-lib.sh::leadv2_tasks_release), not
#      just in render-close.sh.
#   4. leadv2-render-close.sh also skips its own status=done write.
#   5. With tasks.yaml status flipped to a TERMINAL value (done) and all other
#      A1-A5 artifacts intact, phase8-assert.sh's ONLY failure is A6 — proves
#      A6 actually gates (not a tautology riding on an already-failing A2).
#
# Scenario 2 (the literal `git merge --ff-only` failure site): task branch
#   rebases/ancestor-checks cleanly (no Step-0 conflict), but a competing
#   commit is pushed to origin/main in the window between the ancestor check
#   and `git merge --ff-only` — simulated deterministically via a `git` PATH
#   shim that injects the competing push at the exact moment deploy-merge.sh
#   invokes `git pull --ff-only origin main` (immediately before the merge).
#
# Scenario 3 (merge-queue lock serialization — the actual point of change
#   (a)): backgrounds `leadv2-merge-queue.sh acquire LOCKTEST-A` (holds it),
#   asserts a second `acquire LOCKTEST-B` blocks while A holds, then that B
#   acquires promptly once A releases.
#
# Scenario 4 (release-before-deploy ordering): a clean successful merge run
#   of leadv2-deploy-merge.sh, whose deploy-override script checks
#   `leadv2-merge-queue.sh status` from INSIDE the "deploy" step — proves the
#   lock is already free (released right after COMMIT capture) while the
#   slow migration/deploy section is still running, not held through it.
#
# Fully hermetic: mktemp -d sandbox repos + per-scenario LEADV2_STATE_ROOT
# overrides so merge-queue.sh / leadv2-state-path.sh never touch the real
# ~/.claude/leadv2-state tree, and merge-blocker.flag / tasks.yaml /
# phase8-passed.flag all live under each sandbox repo's own docs/ tree.
#
# Usage: bash tests/test-deploy-merge-blocker-gate.sh
# Exit 0 = all pass; nonzero = failure count.

set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPTS_DIR}/.." && pwd)"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$(( PASS + 1 )); }
fail() { echo "FAIL: $1"; FAIL=$(( FAIL + 1 )); }

TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

# =============================================================================
# Scenario 1 — Step-0 divergence-preflight rebase conflict
# =============================================================================
TASK_ID="TEST-MERGE-RACE-01"

ORIGIN="${TMP_DIR}/origin.git"
git init -q --bare "$ORIGIN"

WORK="${TMP_DIR}/work"
git clone -q "$ORIGIN" "$WORK"
(
  cd "$WORK"
  git config user.email t@t.com
  git config user.name t
  echo "base" > file.txt
  git add file.txt
  git commit -q -m init
  git branch -M main
  git push -q origin main
)
BASE_SHA="$(git -C "$WORK" rev-parse HEAD)"

# A named task branch (unused by the failing path below, but realistic).
git -C "$WORK" branch -q "task/${TASK_ID}" "$BASE_SHA"

# Local main gets an unpushed commit on file.txt.
(
  cd "$WORK"
  echo "local-change" > file.txt
  git commit -aqm "local change on task branch"
)

# A second clone pushes a CONFLICTING commit to origin/main from the same
# base — simulates a concurrent session's merge landing first.
WORK2="${TMP_DIR}/work2"
git clone -q "$ORIGIN" "$WORK2"
(
  cd "$WORK2"
  git config user.email t2@t.com
  git config user.name t2
  echo "origin-change" > file.txt
  git commit -aqm "conflicting change pushed to origin"
  git push -q origin main
)

STATE_ROOT="${TMP_DIR}/state"
mkdir -p "$STATE_ROOT"

DM_OUT="${TMP_DIR}/deploy-merge.out"
rc=0
(
  cd "$WORK"
  LEADV2_TASK_ID="$TASK_ID" \
  CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
  LEADV2_STATE_ROOT="$STATE_ROOT" \
    bash "${SCRIPTS_DIR}/leadv2-deploy-merge.sh"
) > "$DM_OUT" 2>&1 || rc=$?

if [[ "$rc" -ne 0 ]]; then
  pass "S1: deploy-merge.sh exits nonzero on Step-0 rebase conflict (rc=$rc)"
else
  fail "S1: deploy-merge.sh exited 0 — expected nonzero on rebase conflict"
fi

BLOCKER="${WORK}/docs/handoff/${TASK_ID}/merge-blocker.flag"
if [[ -f "$BLOCKER" ]]; then
  pass "S1: merge-blocker.flag written: ${BLOCKER}"
else
  fail "S1: merge-blocker.flag NOT found at ${BLOCKER}; deploy-merge output:"
  cat "$DM_OUT" >&2
fi

if [[ -f "$BLOCKER" ]] && grep -q "^merge_blocked: true$" "$BLOCKER" \
   && grep -q "^reason: .*rebase conflict" "$BLOCKER" \
   && grep -q "^task_id: ${TASK_ID}$" "$BLOCKER"; then
  pass "S1: merge-blocker.flag has expected reason + task_id"
else
  fail "S1: merge-blocker.flag missing expected fields; content:"
  [[ -f "$BLOCKER" ]] && cat "$BLOCKER" >&2
fi

# ── seed A1-A5 close artifacts (non-terminal tasks.yaml status) ────────────
mkdir -p "${WORK}/docs/leadv2/closed"
cat > "${WORK}/docs/leadv2/closed/${TASK_ID}.yaml" <<EOF
task_id: ${TASK_ID}
closed_at: "2026-07-17T12:00:00Z"
title: "Test fixture close"
summary_one_line: "Fixture close for merge-blocker gate test"
class: Heavy
outcome: success
files_touched: []
commit: ${BASE_SHA}
vps_deployed: false
also_closes: []
followups: []
board_prose: "Fixture board prose."
dialogue_prose: "Fixture dialogue prose."
live_signal: "Deterministic fixture repro — see tests/test-deploy-merge-blocker-gate.sh."
EOF

mkdir -p "${WORK}/docs/agents/product-owner"
cat > "${WORK}/docs/tasks.yaml" <<EOF
- id: ${TASK_ID}
  lane: action
  status: queued
  summary_one_line: "Fixture task, pre-render"
EOF

cat > "${WORK}/docs/LEAD_V2_STATE.md" <<'EOF'
# LEAD_V2_STATE (fixture)
history:
EOF

cat > "${WORK}/docs/BOARD.md" <<'EOF'
<!-- BOARD HEAD -->
EOF

cat > "${WORK}/docs/agents/product-owner/DIALOGUE.md" <<'EOF'
<!-- last_outcome: none -->
EOF

mkdir -p "${WORK}/docs/leadv2"
cat > "${WORK}/docs/leadv2/reflect-history.yaml" <<EOF
entries:
  - task: ${TASK_ID}
    outcome: success
EOF

tasks_yaml_status() {
  python3 -c "
import yaml
d = yaml.safe_load(open('${WORK}/docs/tasks.yaml'))
items = d if isinstance(d, list) else d.get('tasks', [])
for it in items:
    if it.get('id') == '${TASK_ID}':
        print(it.get('status', ''))
        break
"
}

# ── (S1.3) phase8-assert.sh with A1-A5 seeded (non-terminal) — expect exit 1, A6 cited, no sentinel
PA_OUT="${TMP_DIR}/phase8-assert.out"
rc=0
(
  cd "$WORK"
  CLAUDE_PROJECT_ROOT="$WORK" \
  LEADV2_PROJECT_ROOT="$WORK" \
  LEADV2_STATE_ROOT="$STATE_ROOT" \
    bash "${SCRIPTS_DIR}/leadv2-phase8-assert.sh" "$TASK_ID"
) > "$PA_OUT" 2>&1 || rc=$?

if [[ "$rc" -eq 1 ]]; then
  pass "S1: phase8-assert.sh exits 1 with A1-A5 seeded (A6 blocks) (rc=$rc)"
else
  fail "S1: phase8-assert.sh exited $rc — expected 1; output:"
  cat "$PA_OUT" >&2
fi

if grep -q "A6: merge-blocker present" "$PA_OUT"; then
  pass "S1: phase8-assert.sh cites A6 merge-blocker failure"
else
  fail "S1: phase8-assert.sh output does not cite A6; output:"
  cat "$PA_OUT" >&2
fi

SENTINEL="${WORK}/docs/handoff/${TASK_ID}/phase8-passed.flag"
if [[ ! -f "$SENTINEL" ]]; then
  pass "S1: phase8-passed.flag NOT written"
else
  fail "S1: phase8-passed.flag was written despite A6 failure: ${SENTINEL}"
fi

# ── (S1.4) daemon/lane-queue completion path — leadv2-queue-release.sh directly.
#    This is the exact bypass the round-2 critic review found: BOTH
#    leadv2-daemon.sh:584 (release_claimed_item) and
#    leadv2-helpers.sh::leadv2_po_release call this script, never
#    render-close.sh. Must NOT flip status=done while blocker is present.
QR_OUT="${TMP_DIR}/queue-release.out"
rc=0
(
  cd "$WORK"
  PROJECT_ROOT="$WORK" \
    bash "${SCRIPTS_DIR}/leadv2-queue-release.sh" --lane action --id "$TASK_ID" --outcome success
) > "$QR_OUT" 2>&1 || rc=$?

STATUS_AFTER_QR="$(tasks_yaml_status)"
if [[ "$STATUS_AFTER_QR" != "done" ]]; then
  pass "S1: leadv2-queue-release.sh (daemon path) does NOT flip status to done (status=${STATUS_AFTER_QR})"
else
  fail "S1: leadv2-queue-release.sh flipped status to 'done' despite active merge-blocker.flag"
fi

if grep -q "merge-blocker.flag present" "$QR_OUT"; then
  pass "S1: leadv2-queue-release.sh logs the merge-blocker skip"
else
  fail "S1: leadv2-queue-release.sh did not log the merge-blocker skip; output:"
  cat "$QR_OUT" >&2
fi

# ── (S1.5) render-close.sh also skips its own status=done write ────────────
RC_OUT="${TMP_DIR}/render-close.out"
rc=0
(
  cd "$WORK"
  CLAUDE_PROJECT_ROOT="$WORK" \
  LEADV2_PROJECT_ROOT="$WORK" \
  PROJECT_ROOT="$WORK" \
    bash "${SCRIPTS_DIR}/leadv2-render-close.sh" "$TASK_ID"
) > "$RC_OUT" 2>&1 || rc=$?

if [[ "$rc" -eq 0 ]]; then
  pass "S1: render-close.sh exits 0 (best-effort render, blocker guard is internal)"
else
  fail "S1: render-close.sh exited $rc; output:"
  cat "$RC_OUT" >&2
fi

if grep -q "skipping status=done" "$RC_OUT"; then
  pass "S1: render-close.sh logs the status=done skip"
else
  fail "S1: render-close.sh did not log the status=done skip; output:"
  cat "$RC_OUT" >&2
fi

STATUS_AFTER_RC="$(tasks_yaml_status)"
if [[ "$STATUS_AFTER_RC" != "done" ]]; then
  pass "S1: tasks.yaml status still non-terminal after render-close.sh (status=${STATUS_AFTER_RC})"
else
  fail "S1: tasks.yaml status was flipped to 'done' despite active merge-blocker.flag"
fi

# ── (S1.6) A6-sole-failure — flip tasks.yaml to a TERMINAL status directly
#    (simulating a lead that force-closed it out-of-band) so A1-A5 all PASS,
#    then assert A6 is the ONLY failure phase8-assert.sh cites.
python3 -c "
import yaml
path = '${WORK}/docs/tasks.yaml'
d = yaml.safe_load(open(path))
items = d if isinstance(d, list) else d.get('tasks', [])
for it in items:
    if it.get('id') == '${TASK_ID}':
        it['status'] = 'done'
with open(path, 'w') as f:
    yaml.safe_dump(items, f, sort_keys=False)
"

PA_OUT2="${TMP_DIR}/phase8-assert-sole.out"
rc=0
(
  cd "$WORK"
  CLAUDE_PROJECT_ROOT="$WORK" \
  LEADV2_PROJECT_ROOT="$WORK" \
  LEADV2_STATE_ROOT="$STATE_ROOT" \
    bash "${SCRIPTS_DIR}/leadv2-phase8-assert.sh" "$TASK_ID"
) > "$PA_OUT2" 2>&1 || rc=$?

if [[ "$rc" -eq 1 ]]; then
  pass "S1: phase8-assert.sh with A1-A5 terminal still exits 1 (A6 alone blocks) (rc=$rc)"
else
  fail "S1: phase8-assert.sh exited $rc with A1-A5 terminal — expected 1; output:"
  cat "$PA_OUT2" >&2
fi

FAILCOUNT="$(grep -c '^  - A[0-9]:' "$PA_OUT2" || true)"
if [[ "$FAILCOUNT" -eq 1 ]] && grep -q '^  - A6: merge-blocker present' "$PA_OUT2"; then
  pass "S1: A6 is the SOLE cited failure once A1-A5 pass (not a tautology riding on A2)"
else
  fail "S1: expected exactly 1 failure (A6), got ${FAILCOUNT}; output:"
  cat "$PA_OUT2" >&2
fi

if grep -q "re-run leadv2-deploy-merge.sh ${TASK_ID}" "$PA_OUT2"; then
  pass "S1: A6 failure message includes recovery guidance"
else
  fail "S1: A6 failure message missing recovery guidance; output:"
  cat "$PA_OUT2" >&2
fi

# ── (S1.7) clearing the sole blocker publishes both local and shared proof ──
rm -f "$BLOCKER"
PA_OUT3="${TMP_DIR}/phase8-assert-pass.out"
rc=0
(
  cd "$WORK"
  CLAUDE_PROJECT_ROOT="$WORK" \
  LEADV2_PROJECT_ROOT="$WORK" \
  LEADV2_STATE_ROOT="$STATE_ROOT" \
    bash "${SCRIPTS_DIR}/leadv2-phase8-assert.sh" "$TASK_ID"
) > "$PA_OUT3" 2>&1 || rc=$?

COMPLETION_RECEIPT="${STATE_ROOT}/completions/${TASK_ID}.json"
if [[ "$rc" -eq 0 && -f "$SENTINEL" && -f "$COMPLETION_RECEIPT" ]]; then
  pass "S1: Phase 8 PASS writes local sentinel and shared completion receipt"
else
  fail "S1: Phase 8 PASS did not write both completion proofs (rc=${rc}); output:"
  cat "$PA_OUT3" >&2
fi

if python3 - "$COMPLETION_RECEIPT" "$TASK_ID" <<'PYEOF'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
raise SystemExit(0 if data.get("task_id") == sys.argv[2]
                 and data.get("status") == "phase8_passed"
                 and data.get("assertions") == "7/7" else 1)
PYEOF
then
  pass "S1: shared completion receipt has the fail-closed schema"
else
  fail "S1: shared completion receipt content invalid"
fi

if python3 - "$STATE_ROOT/bus.jsonl" "$TASK_ID" <<'PYEOF'
import json, sys
events = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8") if line.strip()]
raise SystemExit(0 if any(e.get("task_id") == sys.argv[2] and e.get("type") == "closed" for e in events) else 1)
PYEOF
then
  pass "S1: Phase 8 PASS publishes a shared closed event"
else
  fail "S1: Phase 8 PASS did not publish a shared closed event"
fi

# =============================================================================
# Scenario 2 — literal `git merge --ff-only` failure (competing push injected
# right at `git pull --ff-only`, via a `git` PATH shim — deterministic, no
# real timing race).
# =============================================================================
TASK_ID2="TEST-MERGE-RACE-FF-01"

ORIGIN2="${TMP_DIR}/origin2.git"
git init -q --bare "$ORIGIN2"

WORKFF="${TMP_DIR}/workff"
git clone -q "$ORIGIN2" "$WORKFF"
(
  cd "$WORKFF"
  git config user.email t@t.com
  git config user.name t
  echo "base2" > file2.txt
  git add file2.txt
  git commit -q -m init2
  git branch -M main
  git push -q origin main
)
BASE2_SHA="$(git -C "$WORKFF" rev-parse HEAD)"

# Task branch: one clean, non-conflicting commit (does NOT touch file2.txt) —
# ancestor-check against origin/main passes cleanly, no Step-0/auto-rebase
# conflict. Local main stays at BASE2_SHA (BEHIND=0 at Step-0).
git -C "$WORKFF" checkout -qb "task/${TASK_ID2}" "$BASE2_SHA"
(
  cd "$WORKFF"
  echo "task-only" > file3.txt
  git add file3.txt
  git commit -qm "task branch work"
)
git -C "$WORKFF" checkout -q main

# A second clone, used by the git-shim to push a competing commit to
# origin/main exactly when deploy-merge.sh calls `git pull --ff-only`.
WORKFF2="${TMP_DIR}/workff2"
git clone -q "$ORIGIN2" "$WORKFF2"
(
  cd "$WORKFF2"
  git config user.email t2@t.com
  git config user.name t2
)

REAL_GIT="$(command -v git)"
BIN_DIR_FF="${TMP_DIR}/bin-ff"
mkdir -p "$BIN_DIR_FF"
RACE_MARKER="${TMP_DIR}/.ff-race-injected"
cat > "${BIN_DIR_FF}/git" <<SHIM
#!/usr/bin/env bash
if [[ "\$1" == "pull" && "\$2" == "--ff-only" && ! -f "${RACE_MARKER}" ]]; then
  touch "${RACE_MARKER}"
  (
    cd "${WORKFF2}"
    echo "origin-change-2" > file2.txt
    "${REAL_GIT}" commit -aqm "competing push landing mid-deploy" >/dev/null 2>&1
    "${REAL_GIT}" push -q origin main >/dev/null 2>&1
  ) || true
fi
exec "${REAL_GIT}" "\$@"
SHIM
chmod +x "${BIN_DIR_FF}/git"

STATE_ROOT_FF="${TMP_DIR}/state-ff"
mkdir -p "$STATE_ROOT_FF"

DM_FF_OUT="${TMP_DIR}/deploy-merge-ff.out"
rc=0
(
  cd "$WORKFF"
  PATH="${BIN_DIR_FF}:${PATH}" \
  LEADV2_TASK_ID="$TASK_ID2" \
  CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
  LEADV2_STATE_ROOT="$STATE_ROOT_FF" \
    bash "${SCRIPTS_DIR}/leadv2-deploy-merge.sh"
) > "$DM_FF_OUT" 2>&1 || rc=$?

if [[ "$rc" -ne 0 ]]; then
  pass "S2: deploy-merge.sh exits nonzero on ff-only merge race (rc=$rc)"
else
  fail "S2: deploy-merge.sh exited 0 — expected nonzero; output:"
  cat "$DM_FF_OUT" >&2
fi

if [[ -f "$RACE_MARKER" ]]; then
  pass "S2: competing push was injected at git-pull-ff-only time"
else
  fail "S2: race-injection shim never fired — output:"
  cat "$DM_FF_OUT" >&2
fi

BLOCKER_FF="${WORKFF}/docs/handoff/${TASK_ID2}/merge-blocker.flag"
if [[ -f "$BLOCKER_FF" ]] && grep -q "^reason: ff-only merge failed" "$BLOCKER_FF"; then
  pass "S2: merge-blocker.flag written with the literal ff-only-merge reason"
else
  fail "S2: expected ff-only-merge blocker not found/wrong reason; deploy-merge output:"
  cat "$DM_FF_OUT" >&2
  [[ -f "$BLOCKER_FF" ]] && cat "$BLOCKER_FF" >&2
fi

# =============================================================================
# Scenario 3 — merge-queue lock serialization (the point of change (a))
# =============================================================================
STATE_ROOT_LOCK="${TMP_DIR}/state-lock"
mkdir -p "$STATE_ROOT_LOCK"
MQ_SH="${SCRIPTS_DIR}/leadv2-merge-queue.sh"

A_ACQUIRED="${TMP_DIR}/lockA.acquired"
A_RELEASE_NOW="${TMP_DIR}/lockA.release-now"
A_DONE="${TMP_DIR}/lockA.done"

(
  LEADV2_STATE_ROOT="$STATE_ROOT_LOCK" LEADV2_MERGE_POLL_SEC=0.1 LEADV2_MERGE_TIMEOUT_SEC=10 \
    bash "$MQ_SH" acquire LOCKTEST-A && touch "$A_ACQUIRED"
  while [[ ! -f "$A_RELEASE_NOW" ]]; do sleep 0.1; done
  LEADV2_STATE_ROOT="$STATE_ROOT_LOCK" bash "$MQ_SH" release LOCKTEST-A
  touch "$A_DONE"
) &
A_PID=$!

for _i in $(seq 1 50); do [[ -f "$A_ACQUIRED" ]] && break; sleep 0.1; done
if [[ -f "$A_ACQUIRED" ]]; then
  pass "S3: LOCKTEST-A acquires the merge-queue lock"
else
  fail "S3: LOCKTEST-A never acquired the lock"
fi

B_ACQUIRED="${TMP_DIR}/lockB.acquired"
(
  LEADV2_STATE_ROOT="$STATE_ROOT_LOCK" LEADV2_MERGE_POLL_SEC=0.1 LEADV2_MERGE_TIMEOUT_SEC=10 \
    bash "$MQ_SH" acquire LOCKTEST-B && touch "$B_ACQUIRED"
) &
B_PID=$!

sleep 0.6
if [[ ! -f "$B_ACQUIRED" ]]; then
  pass "S3: LOCKTEST-B blocks while LOCKTEST-A still holds the lock"
else
  fail "S3: LOCKTEST-B acquired despite LOCKTEST-A still holding"
fi

STATUS_WHILE_HELD="$(LEADV2_STATE_ROOT="$STATE_ROOT_LOCK" bash "$MQ_SH" status)"
if echo "$STATUS_WHILE_HELD" | grep -q '"holder": "LOCKTEST-A"' \
   && echo "$STATUS_WHILE_HELD" | grep -q "LOCKTEST-B"; then
  pass "S3: status shows LOCKTEST-A holding, LOCKTEST-B queued"
else
  fail "S3: unexpected status output: ${STATUS_WHILE_HELD}"
fi

touch "$A_RELEASE_NOW"
wait "$A_PID" 2>/dev/null || true

for _i in $(seq 1 50); do [[ -f "$B_ACQUIRED" ]] && break; sleep 0.1; done
wait "$B_PID" 2>/dev/null || true
if [[ -f "$B_ACQUIRED" ]]; then
  pass "S3: LOCKTEST-B acquires promptly once LOCKTEST-A releases"
else
  fail "S3: LOCKTEST-B never acquired after LOCKTEST-A released"
fi

# =============================================================================
# Scenario 4 — release-before-deploy ordering: a clean successful merge whose
# deploy-override step observes the lock is ALREADY free (proves the early
# release right after COMMIT capture — not held through migration/deploy).
# =============================================================================
TASK_ID4="TEST-MERGE-RACE-DEPLOY-01"

ORIGIN4="${TMP_DIR}/origin4.git"
git init -q --bare "$ORIGIN4"

WORK4="${TMP_DIR}/work4"
git clone -q "$ORIGIN4" "$WORK4"
(
  cd "$WORK4"
  git config user.email t@t.com
  git config user.name t
  echo "base4" > file4.txt
  git add file4.txt
  git commit -q -m init4
  git branch -M main
  git push -q origin main
)
BASE4_SHA="$(git -C "$WORK4" rev-parse HEAD)"

# Clean task branch: strictly ahead of main, no divergence anywhere — merge
# succeeds all the way through to migration-apply + deploy override.
git -C "$WORK4" checkout -qb "task/${TASK_ID4}" "$BASE4_SHA"
(
  cd "$WORK4"
  echo "task4-change" > file4b.txt
  git add file4b.txt
  git commit -qm "clean task branch commit"
)
git -C "$WORK4" checkout -q main

STATE_ROOT4="${TMP_DIR}/state4"
mkdir -p "$STATE_ROOT4"

# Deploy override observes merge-queue status from INSIDE the "deploy" step.
mkdir -p "${WORK4}/.claude/leadv2-overrides"
EVIDENCE_FILE="${TMP_DIR}/release-before-deploy-evidence.json"
cat > "${WORK4}/.claude/leadv2-overrides/deploy.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
LEADV2_STATE_ROOT="${STATE_ROOT4}" bash "${SCRIPTS_DIR}/leadv2-merge-queue.sh" status > "${EVIDENCE_FILE}"
exit 0
EOF
chmod +x "${WORK4}/.claude/leadv2-overrides/deploy.sh"

DM4_OUT="${TMP_DIR}/deploy-merge4.out"
rc=0
(
  cd "$WORK4"
  LEADV2_TASK_ID="$TASK_ID4" \
  CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
  CLAUDE_PROJECT_ROOT="$WORK4" \
  LEADV2_STATE_ROOT="$STATE_ROOT4" \
    bash "${SCRIPTS_DIR}/leadv2-deploy-merge.sh"
) > "$DM4_OUT" 2>&1 || rc=$?

if [[ "$rc" -eq 0 ]]; then
  pass "S4: clean deploy-merge.sh run succeeds end-to-end (rc=0)"
else
  fail "S4: clean deploy-merge.sh run exited $rc — expected 0; output:"
  cat "$DM4_OUT" >&2
fi

if [[ -f "$EVIDENCE_FILE" ]] && grep -q '"holder": null' "$EVIDENCE_FILE"; then
  pass "S4: merge-queue lock is already free during the deploy step (released before, not through, deploy)"
else
  fail "S4: expected the lock to be free during deploy; evidence:"
  [[ -f "$EVIDENCE_FILE" ]] && cat "$EVIDENCE_FILE" >&2 || echo "(evidence file not written — deploy override never ran)" >&2
fi

# ── result ───────────────────────────────────────────────────────────────
echo ""
echo "=== ${PASS} passed, ${FAIL} failed ==="
[[ "$FAIL" -eq 0 ]]
