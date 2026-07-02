#!/usr/bin/env bash
# tests/test-compact-hooks.sh — smoke tests for leadv2-pre-compact-checkpoint.sh and
# leadv2-postcompact-goal-reinject.sh (multi-task / journal-aware rewrite, LONG-SESSION-01).
# Usage: bash tests/test-compact-hooks.sh
# Exit 0 = all pass; non-zero = failure count
set -euo pipefail

HOOKS_DIR="${BASH_SOURCE[0]%/*}/../hooks"
PRE_HOOK="${HOOKS_DIR}/leadv2-pre-compact-checkpoint.sh"
POST_HOOK="${HOOKS_DIR}/leadv2-postcompact-goal-reinject.sh"
ACTIVE_CACHE_SRC="${HOOKS_DIR}/leadv2-active-cache.sh"

PASS=0
FAIL=0
pass() { printf -- 'PASS: %s\n' "$1"; PASS=$(( PASS + 1 )); }
fail() { printf -- 'FAIL: %s\n' "$1"; FAIL=$(( FAIL + 1 )); }

# Some machines install PyYAML into the real $HOME's user site-packages (not the
# interpreter's global site-packages). Overriding $HOME for sandbox isolation would
# otherwise silently break `import yaml` in the sourced hooks. Preserve access to it.
REAL_USER_SITE="$(python3 -c 'import site; print(site.getusersitepackages())' 2>/dev/null || true)"

TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# ---------------------------------------------------------------------------
# Sandbox project: leadv2_dir=docs/leadv2, 2 sessions (T-ALPHA build, T-BETA review),
# journal.md for both, STATE.md with goal for T-ALPHA, open-threads.md with 3 lines.
# ---------------------------------------------------------------------------
setup_sandbox() {
  local proj="$1"
  mkdir -p "${proj}/.claude/leadv2-overrides"
  mkdir -p "${proj}/docs/leadv2/tasks/T-ALPHA"
  mkdir -p "${proj}/docs/leadv2/tasks/T-BETA"
  # HOME override so leadv2-active-cache.sh resolves at ~/.claude/hooks/... in tests
  mkdir -p "${proj}/home/.claude/hooks" "${proj}/home/.claude/state/leadv2"
  cp "$ACTIVE_CACHE_SRC" "${proj}/home/.claude/hooks/leadv2-active-cache.sh"

  cat > "${proj}/docs/leadv2/active.yaml" <<'YAML'
sessions:
  - task_id: T-ALPHA
    phase: build
  - task_id: T-BETA
    phase: review
YAML

  cat > "${proj}/docs/leadv2/tasks/T-ALPHA/STATE.md" <<'MD'
phase: build
goal: ship the compact hooks rewrite
MD
  printf -- '- 2026-07-02T10:00:00Z [progress] scaffolded pre-compact loop\n- 2026-07-02T10:05:00Z [progress] added composed resume path\n' \
    > "${proj}/docs/leadv2/tasks/T-ALPHA/journal.md"

  printf -- '- 2026-07-02T09:00:00Z [progress] review pass 1 started\n- 2026-07-02T09:30:00Z [progress] review pass 1 done\n' \
    > "${proj}/docs/leadv2/tasks/T-BETA/journal.md"

  printf -- '- thread: confirm dedupe order\n- thread: confirm 60-line cap\n- thread: no-active-task case\n' \
    > "${proj}/docs/leadv2/open-threads.md"
}

PROJ="${TMPDIR_BASE}/proj"
mkdir -p "$PROJ"
setup_sandbox "$PROJ"

# ---------------------------------------------------------------------------
# (1) pre-compact hook writes BOTH tasks/T-ALPHA and tasks/T-BETA pre-compact-resume.md
#     (no checkpoint.md present -> composed path for both)
# ---------------------------------------------------------------------------
INPUT_JSON=$(printf '{"cwd":"%s"}' "$PROJ")
PRE_RC=0
set +e; printf '%s' "$INPUT_JSON" | bash "$PRE_HOOK" >/dev/null 2>&1; PRE_RC=$?; set -e
if [[ $PRE_RC -eq 0 ]]; then
  pass "(0a) pre-compact hook exits 0"
else
  fail "(0a) pre-compact hook must exit 0 (got rc=$PRE_RC)"
fi

ALPHA_RESUME="${PROJ}/docs/leadv2/tasks/T-ALPHA/pre-compact-resume.md"
BETA_RESUME="${PROJ}/docs/leadv2/tasks/T-BETA/pre-compact-resume.md"

if [[ -f "$ALPHA_RESUME" && -f "$BETA_RESUME" ]]; then
  pass "(1) pre-compact hook writes resume.md for BOTH T-ALPHA and T-BETA"
else
  fail "(1) expected both resume files (alpha=$([[ -f "$ALPHA_RESUME" ]] && echo yes || echo no) beta=$([[ -f "$BETA_RESUME" ]] && echo yes || echo no))"
fi

# ---------------------------------------------------------------------------
# (2) T-ALPHA resume contains the goal line and a journal line
# ---------------------------------------------------------------------------
if [[ -f "$ALPHA_RESUME" ]] \
  && grep -q "ship the compact hooks rewrite" "$ALPHA_RESUME" \
  && grep -q "scaffolded pre-compact loop" "$ALPHA_RESUME"; then
  pass "(2) T-ALPHA resume contains goal line and journal line"
else
  fail "(2) T-ALPHA resume missing goal and/or journal line"
fi

# ---------------------------------------------------------------------------
# (3) postcompact stdout contains T-ALPHA block, journal tail, T-BETA line,
#     open-threads line, and total lines <= 60
# ---------------------------------------------------------------------------
POST_RC=0
set +e; POST_OUT=$(HOME="${PROJ}/home" PYTHONPATH="$REAL_USER_SITE" CLAUDE_PROJECT_DIR="$PROJ" bash "$POST_HOOK" 2>/dev/null); POST_RC=$?; set -e
if [[ $POST_RC -eq 0 ]]; then
  pass "(0b) postcompact hook exits 0"
else
  fail "(0b) postcompact hook must exit 0 (got rc=$POST_RC)"
fi
POST_LINES=$(printf '%s\n' "$POST_OUT" | wc -l | tr -d ' ')

if printf '%s' "$POST_OUT" | grep -q "active task: T-ALPHA" \
  && printf '%s' "$POST_OUT" | grep -q "scaffolded pre-compact loop" \
  && printf '%s' "$POST_OUT" | grep -q "T-BETA (phase: review)" \
  && printf '%s' "$POST_OUT" | grep -q "confirm dedupe order" \
  && [[ "$POST_LINES" -le 60 ]]; then
  pass "(3) postcompact stdout has T-ALPHA block + journal tail + T-BETA line + threads line, <=60 lines"
else
  fail "(3) postcompact stdout missing expected content or exceeds 60 lines (lines=$POST_LINES)"
fi

# ---------------------------------------------------------------------------
# (4) No-active-task case: empty sessions + non-empty open-threads.md -> stdout
#     contains threads block only
# ---------------------------------------------------------------------------
PROJ2="${TMPDIR_BASE}/proj2"
mkdir -p "${PROJ2}/.claude/leadv2-overrides" "${PROJ2}/docs/leadv2"
mkdir -p "${PROJ2}/home/.claude/hooks" "${PROJ2}/home/.claude/state/leadv2"
cp "$ACTIVE_CACHE_SRC" "${PROJ2}/home/.claude/hooks/leadv2-active-cache.sh"
cat > "${PROJ2}/docs/leadv2/active.yaml" <<'YAML'
sessions: []
YAML
printf -- '- thread: lone open thread\n' > "${PROJ2}/docs/leadv2/open-threads.md"

POST_RC2=0
set +e; POST_OUT2=$(HOME="${PROJ2}/home" PYTHONPATH="$REAL_USER_SITE" CLAUDE_PROJECT_DIR="$PROJ2" bash "$POST_HOOK" 2>/dev/null); POST_RC2=$?; set -e
if [[ $POST_RC2 -eq 0 ]]; then
  pass "(0c) postcompact hook (no-active-task) exits 0"
else
  fail "(0c) postcompact hook must exit 0 (got rc=$POST_RC2)"
fi

if printf '%s' "$POST_OUT2" | grep -q "Open threads:" \
  && printf '%s' "$POST_OUT2" | grep -q "lone open thread" \
  && ! printf '%s' "$POST_OUT2" | grep -q "POSTCOMPACT CONTEXT RESTORE"; then
  pass "(4) no-active-task + open threads -> stdout contains threads block only"
else
  fail "(4) expected threads-only stdout (got: ${POST_OUT2:0:200})"
fi

# ---------------------------------------------------------------------------
# (5) Active task with journal.md but NO STATE.md -> postcompact still emits
#     the task id and a journal line (regression test for Codex finding 1)
# ---------------------------------------------------------------------------
PROJ3="${TMPDIR_BASE}/proj3"
mkdir -p "${PROJ3}/.claude/leadv2-overrides" "${PROJ3}/docs/leadv2/tasks/T-GAMMA"
mkdir -p "${PROJ3}/home/.claude/hooks" "${PROJ3}/home/.claude/state/leadv2"
cp "$ACTIVE_CACHE_SRC" "${PROJ3}/home/.claude/hooks/leadv2-active-cache.sh"
cat > "${PROJ3}/docs/leadv2/active.yaml" <<'YAML'
sessions:
  - task_id: T-GAMMA
    phase: ship
YAML
# journal.md present, STATE.md intentionally absent
printf -- '- 2026-07-02T11:00:00Z [progress] gamma work in progress\n' \
  > "${PROJ3}/docs/leadv2/tasks/T-GAMMA/journal.md"

POST_RC3=0
set +e; POST_OUT3=$(HOME="${PROJ3}/home" PYTHONPATH="$REAL_USER_SITE" CLAUDE_PROJECT_DIR="$PROJ3" bash "$POST_HOOK" 2>/dev/null); POST_RC3=$?; set -e
if [[ $POST_RC3 -eq 0 ]]; then
  pass "(0d) postcompact hook (no-STATE.md) exits 0"
else
  fail "(0d) postcompact hook must exit 0 with no STATE.md (got rc=$POST_RC3)"
fi

if printf '%s' "$POST_OUT3" | grep -q "T-GAMMA" \
  && printf '%s' "$POST_OUT3" | grep -q "gamma work in progress"; then
  pass "(5) active task with journal but no STATE.md -> stdout contains task id and journal line"
else
  fail "(5) postcompact with no STATE.md missing task id or journal line (got: ${POST_OUT3:0:300})"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[[ $FAIL -eq 0 ]]
