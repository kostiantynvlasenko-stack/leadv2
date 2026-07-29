#!/usr/bin/env bash
# tests/test-open-threads-prune.sh — OPEN-THREADS-HYGIENE-01 smoke tests.
#
# Covers:
#   (1) leadv2-thread-prune.sh list / resolve / prune against a sandbox
#       open-threads.md — resolve removes the matching entry and leaves
#       everything else untouched; prune strips stray "- [x] " lines.
#   (2) leadv2-task-anchor.sh's capture_ask() self-strips "- [x] " lines on
#       every write (belt-and-braces pruning, independent of #1's resolve
#       path).
#   (3) pre-compact-task-freeze.sh, run against a small (already-pruned)
#       open-threads.md, emits a bounded OPEN THREADS section that points at
#       supervisor-role.md instead of embedding a stale role/status block.
#
# Usage: bash tests/test-open-threads-prune.sh
# Exit 0 = all pass; non-zero = failure count.
set -euo pipefail

HOOKS_DIR="${BASH_SOURCE[0]%/*}/../hooks"
SCRIPTS_DIR="${BASH_SOURCE[0]%/*}/../scripts"
PRUNE_SCRIPT="${SCRIPTS_DIR}/leadv2-thread-prune.sh"
TASK_ANCHOR="${HOOKS_DIR}/leadv2-task-anchor.sh"
FREEZE_HOOK="${HOOKS_DIR}/pre-compact-task-freeze.sh"

PASS=0
FAIL=0
pass() { printf -- 'PASS: %s\n' "$1"; PASS=$(( PASS + 1 )); }
fail() { printf -- 'FAIL: %s\n' "$1"; FAIL=$(( FAIL + 1 )); }

TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# ---------------------------------------------------------------------------
# Sandbox project: leadv2_dir=docs/leadv2, a small open-threads.md with 3
# open entries plus one already-resolved "- [x] " line (simulating a
# hand-checked box).
# ---------------------------------------------------------------------------
PROJ="${TMPDIR_BASE}/proj"
mkdir -p "${PROJ}/docs/leadv2" "${PROJ}/.claude/leadv2-overrides"
git -C "$PROJ" init -q
git -C "$PROJ" config user.email test@test.local
git -C "$PROJ" config user.name test

cat > "${PROJ}/docs/leadv2/open-threads.md" <<'MD'
# Open threads — sandbox

## Captured asks (auto)
- [ ] 2026-07-28T10:00:00Z — question one still awaiting an answer
- [x] 2026-07-28T10:05:00Z — already resolved, should never linger
- [ ] 2026-07-28T10:10:00Z — question two also still open
MD

# ---------------------------------------------------------------------------
# (1) list shows only the two unresolved entries
# ---------------------------------------------------------------------------
LIST_OUT="$(cd "$PROJ" && bash "$PRUNE_SCRIPT" list)"
if printf '%s\n' "$LIST_OUT" | grep -q "question one" \
  && printf '%s\n' "$LIST_OUT" | grep -q "question two" \
  && ! printf '%s\n' "$LIST_OUT" | grep -q "already resolved"; then
  pass "(1) list shows only unresolved '- [ ] ' entries"
else
  fail "(1) list output wrong: ${LIST_OUT}"
fi

# ---------------------------------------------------------------------------
# (2) resolve removes the matching entry and leaves the other open entry
# ---------------------------------------------------------------------------
RESOLVE_OUT="$(cd "$PROJ" && bash "$PRUNE_SCRIPT" resolve "question one" 2>&1)"
AFTER_RESOLVE="$(cat "${PROJ}/docs/leadv2/open-threads.md")"
if printf '%s\n' "$RESOLVE_OUT" | grep -q "removed 1 entry" \
  && ! printf '%s\n' "$AFTER_RESOLVE" | grep -q "question one" \
  && printf '%s\n' "$AFTER_RESOLVE" | grep -q "question two"; then
  pass "(2) resolve removes the matched entry, keeps the other open entry"
else
  fail "(2) resolve did not prune correctly (out=${RESOLVE_OUT})"
fi

# ---------------------------------------------------------------------------
# (3) resolving a non-matching substring exits non-zero and changes nothing
# ---------------------------------------------------------------------------
BEFORE_NOMATCH="$(cat "${PROJ}/docs/leadv2/open-threads.md")"
set +e
(cd "$PROJ" && bash "$PRUNE_SCRIPT" resolve "no such text anywhere" >/dev/null 2>&1)
NOMATCH_RC=$?
set -e
AFTER_NOMATCH="$(cat "${PROJ}/docs/leadv2/open-threads.md")"
if [[ "$NOMATCH_RC" -ne 0 && "$BEFORE_NOMATCH" == "$AFTER_NOMATCH" ]]; then
  pass "(3) resolve on a non-matching substring exits non-zero, file unchanged"
else
  fail "(3) expected non-zero exit and no file change (rc=$NOMATCH_RC)"
fi

# ---------------------------------------------------------------------------
# (4) prune strips every residual "- [x] " line defensively — the fixture
#     already carries the original "already resolved" box (never touched by
#     `resolve`, which only ever matches unresolved "- [ ] " lines) plus a
#     freshly reintroduced one, so a correct prune removes BOTH.
# ---------------------------------------------------------------------------
printf -- '- [x] 2026-07-28T11:00:00Z — stray checked box from a hand edit\n' >> "${PROJ}/docs/leadv2/open-threads.md"
PRUNE_OUT="$(cd "$PROJ" && bash "$PRUNE_SCRIPT" prune)"
AFTER_PRUNE="$(cat "${PROJ}/docs/leadv2/open-threads.md")"
if printf '%s\n' "$PRUNE_OUT" | grep -q "pruned 2 resolved" \
  && ! printf '%s\n' "$AFTER_PRUNE" | grep -q "stray checked box" \
  && ! printf '%s\n' "$AFTER_PRUNE" | grep -q "already resolved"; then
  pass "(4) prune strips every stray '- [x] ' line"
else
  fail "(4) prune did not strip stray resolved lines (out=${PRUNE_OUT})"
fi

# ---------------------------------------------------------------------------
# (5) capture_ask (leadv2-task-anchor.sh, invoked via UserPromptSubmit
#     payload) self-strips any "- [x] " line on every write, independent of
#     the prune script above.
# ---------------------------------------------------------------------------
printf -- '- [x] 2026-07-28T12:00:00Z — another stray checked box\n' >> "${PROJ}/docs/leadv2/open-threads.md"
LONG_PROMPT="this is a brand new founder ask that is long enough to be captured by the hook heuristic"
PAYLOAD_JSON=$(python3 -c "import json,sys; print(json.dumps({'cwd': sys.argv[1], 'prompt': sys.argv[2], 'session_id': 'test-session'}))" "$PROJ" "$LONG_PROMPT")
printf '%s' "$PAYLOAD_JSON" | bash "$TASK_ANCHOR" >/dev/null 2>&1 || true
AFTER_CAPTURE="$(cat "${PROJ}/docs/leadv2/open-threads.md")"
if printf '%s\n' "$AFTER_CAPTURE" | grep -q "brand new founder ask" \
  && ! printf '%s\n' "$AFTER_CAPTURE" | grep -q "another stray checked box"; then
  pass "(5) capture_ask appends the new ask AND self-strips the stray '- [x] ' line"
else
  fail "(5) capture_ask did not behave as expected:"$'\n'"${AFTER_CAPTURE}"
fi

# ---------------------------------------------------------------------------
# (6) pre-compact-task-freeze.sh dry-run: against the now-small, clean
#     open-threads.md, stdout carries the OPEN THREADS section pointing at
#     supervisor-role.md, NOT a giant embedded role/status block.
# ---------------------------------------------------------------------------
INPUT_JSON=$(python3 -c "import json,sys; print(json.dumps({'cwd': sys.argv[1]}))" "$PROJ")
FREEZE_OUT="$(CLAUDE_PLUGIN_ROOT="/fake/plugin/root" bash -c "printf '%s' '$INPUT_JSON' | bash '$FREEZE_HOOK'")"
if printf '%s\n' "$FREEZE_OUT" | grep -q "OPEN THREADS" \
  && printf '%s\n' "$FREEZE_OUT" | grep -q "supervisor-role.md" \
  && printf '%s\n' "$FREEZE_OUT" | grep -q "question two"; then
  pass "(6) pre-compact freeze dry-run points at supervisor-role.md and carries the open item"
else
  fail "(6) freeze dry-run missing expected content:"$'\n'"${FREEZE_OUT}"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[[ $FAIL -eq 0 ]]
