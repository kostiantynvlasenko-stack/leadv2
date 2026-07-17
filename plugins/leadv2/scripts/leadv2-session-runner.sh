#!/usr/bin/env bash
# scripts/leadv2-session-runner.sh — daemon-mode completion loop for a fanned-out
# /leadv2 session (SUPERVISOR-RETRO-01 item 2).
#
# THE GAP this fixes: headless launch used `claude -p "/leadv2 $tid"` with no
# --model/--effort and no resume-on-exit — a session that exited mid-phase
# (rate limit, crash, `claude -p` returning without a completed task) just
# stopped; nobody restarted it toward close. tmux launch had the same gap
# plus registered `daemon=false` even though nothing else acted as a daemon.
#
# THIS SCRIPT is that daemon: it owns the plan->build->review->deploy-gate->
# verify->close retry loop for exactly one task, using the SAME
# --session-id across resumes so `claude` continues the prior conversation
# instead of restarting from a blank context.
#
# Required env:
#   LEADV2_TASK_ID     — the task id this runner drives to close.
#
# Optional env (fanout.sh sets these; safe defaults below for standalone runs):
#   LEADV2_LEAD_MODEL    (default: sonnet)
#   LEADV2_LEAD_EFFORT   (default: medium)
#   LEADV2_DAEMON        (default: 1) — informational; always daemon-mode here.
#   LEADV2_ASYNC_QUESTIONS (default: 1) — REQUIRED so the spawned /leadv2
#       session routes founder-facing questions through scripts/leadv2-ask.sh
#       instead of AskUserQuestion (nobody is watching this worktree's TTY).
#       Only a typed founder decision may reach leadv2-ask.sh; routine phase
#       boundaries must never block on an interactive prompt.
#   LEADV2_FANOUT          (default: 1) — informational marker for the child.
#   LEADV2_RUNNER_MAX_ATTEMPTS (default: 12) — resume attempts before giving up.
#   LEADV2_RUNNER_RETRY_SLEEP_S (default: 5) — backoff between resume attempts.
#   LEADV2_FANOUT_CLAUDE_BIN (default: claude) — override for tests (mirrors
#       scripts/leadv2-fanout.sh's CLAUDE_BIN convention).
#
# Idempotency: a per-task flock (docs/handoff/<task>/.session-runner.lock)
# refuses a second concurrent runner for the same task. The completion
# sentinel is docs/handoff/<task>/.leadv2-final-complete.flag, written by
# scripts/leadv2-finish.sh only after phase8-close completed its hard
# tasks-regen and unregister steps. Deploy/phase side-effect
# idempotency itself lives in the phase-advance/phase8/finish scripts (also
# out of scope here); this runner's contribution is the imperative resume
# prompt explicitly instructing the resumed session to re-check sentinels
# before repeating any side-effecting step — never re-running blind.
#
# Exit codes:
#   0 — final-complete sentinel observed, task closed
#   1 — bad usage / missing LEADV2_TASK_ID
#   2 — lock held by another live runner for this task
#   3 — max resume attempts exhausted without reaching the sentinel

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
readonly PROJECT_ROOT

log() { printf '[leadv2-session-runner] %s\n' "$*" >&2; }
log_error() { printf '[leadv2-session-runner] ERROR: %s\n' "$*" >&2; }

TASK_ID="${LEADV2_TASK_ID:-}"
if [[ -z "$TASK_ID" ]]; then
  log_error "LEADV2_TASK_ID is required"
  exit 1
fi

LEAD_MODEL="${LEADV2_LEAD_MODEL:-sonnet}"
LEAD_EFFORT="${LEADV2_LEAD_EFFORT:-medium}"
export LEADV2_DAEMON="${LEADV2_DAEMON:-1}"
export LEADV2_ASYNC_QUESTIONS="${LEADV2_ASYNC_QUESTIONS:-1}"
export LEADV2_FANOUT="${LEADV2_FANOUT:-1}"
export LEADV2_TASK_ID="$TASK_ID"
MAX_ATTEMPTS="${LEADV2_RUNNER_MAX_ATTEMPTS:-12}"
RETRY_SLEEP_S="${LEADV2_RUNNER_RETRY_SLEEP_S:-5}"
# NO-NEW-OUTPUT-STOP: consecutive resume attempts that append nothing new to
# LOGF (rc!=0, no fresh stream-json bytes) mean the resumed session is not
# making progress — stop early instead of burning the full MAX_ATTEMPTS.
NOOP_MAX="${LEADV2_RUNNER_NOOP_MAX:-3}"
CLAUDE_BIN="${LEADV2_FANOUT_CLAUDE_BIN:-claude}"

TASK_DIR="${PROJECT_ROOT}/docs/handoff/${TASK_ID}"
mkdir -p "$TASK_DIR"
SENTINEL="${TASK_DIR}/.leadv2-final-complete.flag"
LOCK_FILE="${TASK_DIR}/.session-runner.lock"
SESSION_ID_FILE="${TASK_DIR}/.session-runner.session-id"
LOGF="${TASK_DIR}/session-runner.log"

# ── Per-task lock — refuse a second concurrent runner for the same task ────
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  log_error "another live session-runner already holds the lock for ${TASK_ID} — refusing to start a second one"
  exit 2
fi
# lock fd 9 stays held for the lifetime of this process; released on exit
# (process death or normal return) automatically by the OS.

# ── Stable session id across resumes ────────────────────────────────────────
if [[ -f "$SESSION_ID_FILE" ]]; then
  SESSION_ID="$(cat "$SESSION_ID_FILE")"
else
  SESSION_ID="$(python3 -c 'import uuid; print(uuid.uuid4())')"
  printf '%s' "$SESSION_ID" > "$SESSION_ID_FILE"
fi

log "task=${TASK_ID} model=${LEAD_MODEL} effort=${LEAD_EFFORT} session_id=${SESSION_ID} log=${LOGF}"

sentinel_present() { [[ -f "$SENTINEL" ]]; }

if sentinel_present; then
  log "final-complete sentinel already present for ${TASK_ID} — nothing to do"
  exit 0
fi

attempt=0
noop_streak=0
while (( attempt < MAX_ATTEMPTS )); do
  if [[ "$attempt" -eq 0 ]]; then
    prompt="/leadv2 ${TASK_ID}"
  else
    # Imperative continue prompt — same --session-id, so this is a
    # resume of the prior conversation, not a fresh /leadv2 dispatch.
    prompt="/leadv2 ${TASK_ID} -- CONTINUE: this session exited before .leadv2-final-complete.flag was written (attempt ${attempt}/${MAX_ATTEMPTS}). Resume from the current phase. Re-check every sentinel/receipt already on disk before repeating ANY side-effecting step (spawn, merge, deploy, close) — do not blindly re-run prior actions. Drive the task through plan, build, review, deploy-gate, verify, close without stopping for confirmation; only a genuinely typed founder decision may call scripts/leadv2-ask.sh."
  fi

  # RESUME-FLAG-FIX: `--session-id` only WORKS to CREATE a fresh session
  # (attempt 0). On every later attempt the id already exists, and
  # `claude -p --session-id "$SESSION_ID" ...` fails INSTANTLY with
  # "Error: Session ID <id> is already in use." (rc=1) — verified live:
  # a second `--session-id` call on an existing id returns rc=1 in <1s,
  # while `claude -p --resume "$SESSION_ID" ...` on the same id returns
  # rc=0 and continues the prior conversation. Before this fix, attempts
  # 1..MAX_ATTEMPTS-1 always hit the rc=1 branch — the 12-attempt resume
  # loop never resumed a single session.
  if [[ "$attempt" -eq 0 ]]; then
    session_flag=(--session-id "$SESSION_ID")
  else
    session_flag=(--resume "$SESSION_ID")
  fi

  log "attempt ${attempt}/${MAX_ATTEMPTS}: launching claude -p (session-id=${SESSION_ID}, flag=${session_flag[0]})"
  log_size_before="$(wc -c <"$LOGF" 2>/dev/null || echo 0)"
  set +e
  ( cd "$PROJECT_ROOT" && \
    "$CLAUDE_BIN" -p \
      "${session_flag[@]}" \
      --model "$LEAD_MODEL" \
      --effort "$LEAD_EFFORT" \
      --permission-mode bypassPermissions \
      --output-format stream-json \
      --verbose \
      "$prompt" ) >>"$LOGF" 2>&1
  rc=$?
  set -e
  log "attempt ${attempt} exited rc=${rc}"

  if sentinel_present; then
    log "final-complete sentinel observed for ${TASK_ID} — session complete"
    exit 0
  fi

  # NO-NEW-OUTPUT-STOP: a resume that appended nothing new to LOGF made no
  # progress. N consecutive no-output resumes mean further resumes are
  # wasted cycles on a settled session — stop before MAX_ATTEMPTS.
  log_size_after="$(wc -c <"$LOGF" 2>/dev/null || echo 0)"
  if (( log_size_after <= log_size_before )); then
    noop_streak=$(( noop_streak + 1 ))
    log "attempt ${attempt} produced no new output (noop_streak=${noop_streak}/${NOOP_MAX})"
  else
    noop_streak=0
  fi

  attempt=$(( attempt + 1 ))

  if (( noop_streak >= NOOP_MAX )); then
    log_error "${noop_streak} consecutive resume attempts produced no new output — stopping early instead of burning all ${MAX_ATTEMPTS} attempts"
    break
  fi

  if (( attempt < MAX_ATTEMPTS )); then
    log "no sentinel yet — resuming in ${RETRY_SLEEP_S}s (attempt ${attempt}/${MAX_ATTEMPTS} next)"
    sleep "$RETRY_SLEEP_S"
  fi
done

# Loop ended (attempts exhausted OR noop-streak break) without the sentinel.
# A session that ever logged "subtype":"success" completed at least one turn
# cleanly — reporting a blanket ERROR there is a false verdict (the observed
# bug: lane 22ea0a392ace succeeded on attempt 1, then 11 more resumes were
# mis-reported as "max attempts exhausted"). Distinguish honestly:
#   - success ever seen, no sentinel  -> INCOMPLETE (not an error), rc=4
#   - success never seen              -> genuine ERROR, rc=3 (unchanged)
if grep -q '"subtype"[[:space:]]*:[[:space:]]*"success"' "$LOGF" 2>/dev/null; then
  log "INCOMPLETE (no sentinel): ${TASK_ID} logged \"subtype\":\"success\" at least once but .leadv2-final-complete.flag was never written — the close pipeline stalled after a successful turn, this is NOT an error. Leaving lock+log for inspection."
  exit 4
fi

log_error "max attempts (${MAX_ATTEMPTS}) exhausted without final-complete sentinel for ${TASK_ID} — giving up, leaving lock+log for inspection"
exit 3
