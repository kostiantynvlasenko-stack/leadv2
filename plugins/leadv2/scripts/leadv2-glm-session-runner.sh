#!/usr/bin/env bash
# leadv2-glm-session-runner.sh — daemon/resume loop for a complete GLM-led
# /leadv2 child session. Mirrors leadv2-codex-session-runner.sh's contract
# (sentinel, guards, active.yaml provider_receipts) but drives GLM through
# glm-coder.sh's `bg`/`status` workbench instead of a resumable codex thread —
# GLM has no --resume equivalent, so each attempt is a FRESH bg launch; the
# resume-loop semantics live in re-deriving state (crash-recovery / phase8
# sentinel / stall streaks) between attempts, not in a conversation resume.
#
# PROVIDER-LEAD-PARITY (3f8a2c61d904): do NOT touch
# leadv2-codex-session-runner.sh's own logic — read only, pattern-mirrored here.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
if ! declare -p PROJECT_ROOT 2>/dev/null | grep -q -- '-r'; then
  PROJECT_ROOT="${LEADV2_PROJECT_ROOT:-${CLAUDE_PROJECT_DIR:-${PROJECT_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}}}"
  readonly PROJECT_ROOT
fi

log() { printf -- '[leadv2-glm-session-runner] %s\n' "$*" >&2; }
log_error() { printf -- '[leadv2-glm-session-runner] ERROR: %s\n' "$*" >&2; }

TASK_ID="${LEADV2_TASK_ID:-}"
if [[ -z "$TASK_ID" ]]; then
  log_error "LEADV2_TASK_ID is required"
  exit 1
fi

GLM_CODER_BIN="${LEADV2_GLM_CODER_BIN:-$SCRIPT_DIR/glm-coder.sh}"
MODEL="${LEADV2_LEAD_MODEL:-glm-5.2}"
EFFORT="${LEADV2_LEAD_EFFORT:-medium}"
MAX_ATTEMPTS="${LEADV2_RUNNER_MAX_ATTEMPTS:-6}"
RETRY_SLEEP_S="${LEADV2_RUNNER_RETRY_SLEEP_S:-5}"
NOOP_MAX="${LEADV2_RUNNER_NOOP_MAX:-3}"
STALL_MAX="${LEADV2_RUNNER_STALL_MAX:-6}"
GLM_MAX_TURNS="${LEADV2_GLM_MAX_TURNS:-40}"
GLM_TIMEOUT="${LEADV2_GLM_TIMEOUT:-900}"
GLM_RUNS_DIR="${GLM_RUNS_DIR:-$HOME/.claude/cache/glm-runs}"
GLM_FALLBACK_EXIT_CODE="${GLM_FALLBACK_EXIT_CODE:-76}"
GLM_POLL_INTERVAL_S="${LEADV2_GLM_POLL_INTERVAL_S:-5}"
GLM_POLL_BUDGET_S="${LEADV2_GLM_POLL_BUDGET_S:-$(( GLM_TIMEOUT * 2 + 700 ))}"

export LEADV2_DAEMON="${LEADV2_DAEMON:-1}"
export LEADV2_ASYNC_QUESTIONS="${LEADV2_ASYNC_QUESTIONS:-1}"
export LEADV2_FANOUT="${LEADV2_FANOUT:-1}"
export LEADV2_SESSION_PROVIDER="glm"
export LEADV2_TASK_ID="$TASK_ID"

TASK_DIR="$PROJECT_ROOT/docs/handoff/$TASK_ID"
mkdir -p "$TASK_DIR"
SENTINEL="${LEADV2_COMPLETION_SENTINEL:-$TASK_DIR/phase8-passed.flag}"
COMPLETION_RECEIPT="${LEADV2_COMPLETION_RECEIPT:-$(
  env PROJECT_ROOT="$PROJECT_ROOT" \
    "$SCRIPT_DIR/leadv2-state-path.sh" --no-link "completions/${TASK_ID}.json"
)}"
LOCK_FILE="$TASK_DIR/.glm-session-runner.lock"
PID_FILE="$TASK_DIR/.glm-session-runner.pid"
RUN_ID_FILE="$TASK_DIR/.glm-session-runner.run-id"
LOGF="$TASK_DIR/glm-session-runner.log"
WORKTREE_DIR="$PROJECT_ROOT/.claude/worktrees/$TASK_ID"
WORKTREE_SENTINEL="$WORKTREE_DIR/docs/handoff/$TASK_ID/phase8-passed.flag"
PROGRESS_TOOL="${LEADV2_PROGRESS_FINGERPRINT:-$SCRIPT_DIR/leadv2-progress-fingerprint.sh}"

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  log_error "another live session runner already owns task $TASK_ID"
  exit 2
fi
printf -- '%s\n' "$$" > "$PID_FILE"

sentinel_present() {
  [[ -f "$SENTINEL" ]] && return 0
  [[ -n "${WORKTREE_SENTINEL:-}" && -f "$WORKTREE_SENTINEL" ]] && return 0
  [[ -f "$COMPLETION_RECEIPT" ]] || return 1
  python3 - "$COMPLETION_RECEIPT" "$TASK_ID" <<'PYEOF' >/dev/null 2>&1
import json, sys
path, task_id = sys.argv[1:]
with open(path, encoding="utf-8") as fh:
    receipt = json.load(fh)
valid = (
    receipt.get("schema_version") == 1
    and receipt.get("task_id") == task_id
    and receipt.get("status") == "phase8_passed"
    and receipt.get("assertions") == "7/7"
)
raise SystemExit(0 if valid else 1)
PYEOF
}

if sentinel_present; then
  log "Phase-8 completion proof already present for $TASK_ID — nothing to do"
  exit 0
fi

if [[ ! -f "$GLM_CODER_BIN" ]]; then
  log_error "glm-coder.sh unavailable: $GLM_CODER_BIN"
  exit 1
fi
GLM_SECRETS_FILE="${GLM_SECRETS_FILE:-$HOME/.claude/secrets/zai.env}"
if [[ ! -f "$GLM_SECRETS_FILE" ]]; then
  log_error "GLM secrets file unavailable: $GLM_SECRETS_FILE (run glm-coder.sh test to verify credentials)"
  exit 1
fi

_append_receipt() {
  local status="$1" rc="$2" attempt="$3" run_id="$4"
  local registry="$SCRIPT_DIR/leadv2-active-registry.sh"
  [[ -f "$registry" ]] || return 0
  # shellcheck source=/dev/null
  source "$registry"
  type leadv2_active_append_provider_receipt >/dev/null 2>&1 || return 0
  local receipt
  receipt="$(python3 - "$TASK_ID" "$MODEL" "$EFFORT" "$run_id" "$status" "$rc" "$attempt" <<'PYEOF'
import datetime, json, sys
task_id, model, effort, run_id, status, rc, attempt = sys.argv[1:]
print(json.dumps({
    "provider": "glm",
    "task_id": task_id,
    "model": model,
    "effort": effort,
    "run_id": run_id or None,
    "status": status,
    "exit_code": int(rc),
    "attempt": int(attempt),
    "recorded_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
}, separators=(",", ":")))
PYEOF
  )"
  leadv2_active_append_provider_receipt "$TASK_ID" "$receipt" >/dev/null 2>&1 || true
}

_launcher_spawn_detected() {
  local journal_path="$1"
  [[ -f "$journal_path" ]] || return 1
  python3 - "$journal_path" <<'PYEOF'
import json, os, re, shlex, sys

path = sys.argv[1]

LAUNCHER_RE = re.compile(
    r"^(?:[^\s/]*/)*(?:LEADV2_)?leadv2-(?:codex-|glm-)?session-runner(?:\.sh)?$"
    r"|^(?:[^\s/]*/)*(?:LEADV2_)?leadv2-(?:fanout|supervise)(?:\.sh)?$"
    r"|^(?:[^\s/]*/)*(?:LEADV2_)?leadv2-[^\s/]*?(?:launcher|dispatcher)(?:\.sh)?$",
    re.I,
)
INTERPRETERS = {"bash", "sh", "zsh", "dash", "ksh", "source", "."}

def is_launcher(tok):
    return bool(tok) and not any(c.isspace() for c in tok) and bool(LAUNCHER_RE.match(tok))

def split_unquoted(text):
    subs, cur, quote = [], [], None
    for c in text:
        if quote:
            cur.append(c)
            if c == quote:
                quote = None
        elif c in ("'", '"'):
            quote = c
            cur.append(c)
        elif c in ";&|\n()":
            subs.append("".join(cur))
            cur = []
        else:
            cur.append(c)
    subs.append("".join(cur))
    return subs

def shell_tokens(s):
    try:
        return shlex.split(s, posix=True)
    except ValueError:
        return s.split()

TIMEOUT_ARG_OPTS = {"-k", "--kill-after", "-s", "--signal"}
XARGS_ARG_OPTS = {
    "-I", "--replace", "-n", "--max-args", "-P", "--max-procs",
    "-d", "--delimiter", "-E", "-s", "--max-chars", "-L", "--max-lines",
}

def _next_operand(toks, i, arg_opts):
    n = len(toks)
    while i < n:
        t = toks[i]
        if t == "-" or not t.startswith("-"):
            break
        if t == "--":
            i += 1
            break
        if t.startswith("--"):
            name, attached = t.split("=", 1)[0], "=" in t
        else:
            name, attached = "-" + t[1:2], len(t) > 2
        i += 1
        if name in arg_opts and not attached:
            i += 1
    return i

def eval_tokens(toks, depth):
    if not toks:
        return False
    i = 0
    while i < len(toks):
        t = toks[i]
        if t in ("sudo", "env", "command", "nohup", "setsid") or re.match(r"^[A-Za-z_]\w*=", t):
            i += 1
            continue
        if t == "timeout":
            j = _next_operand(toks, i + 1, TIMEOUT_ARG_OPTS)
            if j < len(toks):
                j += 1
            i = j
            continue
        if t == "xargs":
            i = _next_operand(toks, i + 1, XARGS_ARG_OPTS)
            continue
        break
    if i >= len(toks):
        return False
    prog = toks[i]
    if is_launcher(prog):
        return True
    if prog == "eval":
        rest = toks[i + 1:]
        if rest and scan_command(" ".join(rest), depth + 1):
            return True
    if os.path.basename(prog) in INTERPRETERS:
        rest = toks[i + 1:]
        k, has_c = 0, False
        while k < len(rest) and rest[k].startswith("-") and rest[k] != "-":
            if rest[k] in ("-c", "-lc", "-cl"):
                has_c = True
            k += 1
        for j, tok in enumerate(rest):
            if tok == "<<<" and j + 1 < len(rest):
                body = rest[j + 1]
                if is_launcher(body) or scan_command(body, depth + 1):
                    return True
        if k < len(rest):
            operand = rest[k]
            if is_launcher(operand):
                return True
            if has_c and scan_command(operand, depth + 1):
                return True
    return False

def scan_command(text, depth=0):
    if depth > 4:
        return False
    for body in re.findall(r"\$\(([^)]*)\)|`([^`]*)`", text):
        for b in body:
            if b and scan_command(b, depth + 1):
                return True
    for sub in split_unquoted(text):
        if eval_tokens(shell_tokens(sub), depth):
            return True
    return False

try:
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except ValueError:
                continue
            if not isinstance(obj, dict) or obj.get("type") != "assistant":
                continue
            message = obj.get("message") or {}
            for block in (message.get("content") or []):
                if not isinstance(block, dict) or block.get("type") != "tool_use":
                    continue
                if str(block.get("name", "")).lower() not in ("bash",):
                    continue
                cmd = (block.get("input") or {}).get("command", "")
                if isinstance(cmd, str) and scan_command(cmd):
                    raise SystemExit(0)
except FileNotFoundError:
    raise SystemExit(1)
raise SystemExit(1)
PYEOF
}

_glm_status() {
  local run_id="$1"
  "$GLM_CODER_BIN" status "$run_id" 2>/dev/null | grep '^status:' | head -1 | cut -d: -f2- | sed 's/^ //'
}

_glm_exit_code() {
  local run_id="$1"
  "$GLM_CODER_BIN" status "$run_id" 2>/dev/null | grep '^exit_code:' | head -1 | cut -d: -f2- | sed 's/^ //'
}

log "task=$TASK_ID provider=glm model=$MODEL effort=$EFFORT log=$LOGF"

attempt=0
noop_streak=0
stall_streak=0
force_close_only=0
saw_any_completion=0
while (( attempt < MAX_ATTEMPTS )); do
  if (( attempt > 0 )); then
    if ! type _leadv2_derive_real_state >/dev/null 2>&1; then
      # shellcheck source=leadv2-helpers.sh
      source "$SCRIPT_DIR/leadv2-helpers.sh"
    fi
    _real_state="$(_leadv2_derive_real_state "$TASK_ID" "$PROJECT_ROOT" "$WORKTREE_DIR")"
    case "$_real_state" in
      done)
        log "crash-recovery: phase8-passed.flag already present for $TASK_ID — task complete, skipping further attempts"
        exit 0
        ;;
      close-only)
        force_close_only=1
        ;;
    esac
  fi

  _close_only_sentence=""
  if [[ "$force_close_only" -eq 1 ]]; then
    _close_only_sentence=" Your previous turn already landed commits but the Phase-8 sentinel is missing -- do NOT redo any build/review/deploy work; run ONLY leadv2-phase8-close.sh (and its prerequisite leadv2-phase8-assert.sh / leadv2-phase8-e2e-gate.sh) to completion now."
    force_close_only=0
  fi

  prompt="You ARE ALREADY the leadv2 headless child session for task ${TASK_ID}; execute its Phase 0..8 lifecycle yourself (plan, build, adversarial review, deploy gate, live verification, close). NEVER invoke leadv2-glm-session-runner.sh, leadv2-codex-session-runner.sh, leadv2-session-runner.sh, leadv2-fanout.sh, leadv2-supervise.sh, or any launcher/dispatcher: that is self-recursion and will fail on this session's flock. Reuse only per-phase helper scripts and guards (such as leadv2-gate1-prompt.sh and leadv2-phase8-{assert,e2e-gate,close}.sh), never a session launcher. Never bypass a safety, merge, deploy, or phase gate. All founder questions must use .claude/scripts/leadv2-ask.sh because LEADV2_ASYNC_QUESTIONS=1. Stop only after docs/handoff/${TASK_ID}/phase8-passed.flag or its validated shared completion receipt exists, or a circuit breaker requires the supervising founder. An active.yaml unregister failure is explicitly non-blocking (see leadv2-phase8-close.sh comment '(non-blocking)') -- log it and continue Phase 8 close; do NOT raise a question or stall on it.${_close_only_sentence} This is a FRESH turn (GLM has no cross-turn resume) -- re-derive current progress from git log/handoff files/the phase-8 sentinel before acting; never redo already-committed work."

  log "attempt $attempt/$MAX_ATTEMPTS: glm bg (fresh turn)"
  progress_before="$("$PROGRESS_TOOL" "$TASK_ID" 2>/dev/null || printf -- 'unknown-before')"

  set +e
  run_id="$("$GLM_CODER_BIN" bg "$prompt" --cwd "$PROJECT_ROOT" --max-turns "$GLM_MAX_TURNS" --timeout "$GLM_TIMEOUT" 2>>"$LOGF")"
  launch_rc=$?
  set -e
  if [[ "$launch_rc" -ne 0 || -z "$run_id" ]]; then
    log_error "glm-coder.sh bg failed to launch (rc=$launch_rc)"
    _append_receipt "launch_failed" "$launch_rc" "$attempt" ""
    attempt=$((attempt + 1))
    noop_streak=$((noop_streak + 1))
    if (( noop_streak >= NOOP_MAX )); then
      log_error "$noop_streak consecutive attempts failed to launch — stopping"
      break
    fi
    (( attempt < MAX_ATTEMPTS )) && sleep "$RETRY_SLEEP_S"
    continue
  fi
  printf -- '%s\n' "$run_id" > "$RUN_ID_FILE"
  log "attempt $attempt: glm run_id=$run_id"

  run_dir="$GLM_RUNS_DIR/$run_id"
  waited=0
  glm_status="running"
  while (( waited < GLM_POLL_BUDGET_S )); do
    glm_status="$(_glm_status "$run_id")"
    [[ "$glm_status" == "running" || -z "$glm_status" ]] || break
    sleep "$GLM_POLL_INTERVAL_S"
    waited=$((waited + GLM_POLL_INTERVAL_S))
  done
  if [[ "$glm_status" == "running" || -z "$glm_status" ]]; then
    log_error "attempt $attempt: glm run $run_id did not finish within poll budget (${GLM_POLL_BUDGET_S}s) — treating as stalled"
  fi

  rc="$(_glm_exit_code "$run_id")"
  [[ "$rc" =~ ^[0-9]+$ ]] || rc=1

  if _launcher_spawn_detected "$run_dir/journal.jsonl"; then
    _append_receipt "recursion_detected" "$rc" "$attempt" "$run_id"
    log_error "GLM-LEAD RECURSION: GLM tried to spawn a leadv2 launcher/dispatcher from its already-running child session; stopping immediately"
    exit 5
  fi

  progress_after="$("$PROGRESS_TOOL" "$TASK_ID" 2>/dev/null || printf -- 'unknown-after')"
  if [[ "$progress_before" == "$progress_after" ]]; then
    stall_streak=$((stall_streak + 1))
    log "attempt $attempt changed no phase/git/handoff evidence (stall_streak=${stall_streak}/${STALL_MAX})"
  else
    stall_streak=0
  fi

  _status="failed"
  [[ "$rc" -eq 0 ]] && _status="turn_completed"
  _append_receipt "$_status" "$rc" "$attempt" "$run_id"
  log "attempt $attempt exited rc=$rc glm_status=$glm_status run_id=$run_id"

  if sentinel_present; then
    _append_receipt "complete" "0" "$attempt" "$run_id"
    log "Phase-8 completion proof observed for $TASK_ID"
    exit 0
  fi

  if [[ -f "$run_dir/progress.log" ]] && grep -q 'GLM_FALLBACK_TO_SONNET' "$run_dir/progress.log" 2>/dev/null; then
    _append_receipt "fallback_to_sonnet" "$GLM_FALLBACK_EXIT_CODE" "$attempt" "$run_id"
    log_error "GLM_FALLBACK_TO_SONNET observed for run $run_id — hard-failing to caller (no further GLM attempts) for sonnet fallback"
    exit "$GLM_FALLBACK_EXIT_CODE"
  fi

  if [[ -f "$run_dir/progress.log" ]] && grep -q 'RUN_COMPLETE\|GLM_PERMANENT_FAILURE' "$run_dir/progress.log" 2>/dev/null; then
    saw_any_completion=1
  fi

  attempt=$((attempt + 1))
  if [[ "$rc" -eq 0 ]]; then
    noop_streak=0
  else
    noop_streak=$((noop_streak + 1))
  fi
  if (( noop_streak >= NOOP_MAX )); then
    log_error "$noop_streak consecutive attempts produced no output — stopping"
    break
  fi
  if (( stall_streak >= STALL_MAX )); then
    log_error "GLM-LEAD RECURSION suspected: $stall_streak consecutive turns changed no phase/git/handoff evidence while this runner owns the flock — stopping early to prevent token-burning resumes"
    break
  fi
  if (( attempt < MAX_ATTEMPTS )); then
    sleep "$RETRY_SLEEP_S"
  fi
done

if [[ "$saw_any_completion" -eq 1 ]]; then
  _append_receipt "incomplete" "4" "$attempt" "$(cat "$RUN_ID_FILE" 2>/dev/null || true)"
  log "INCOMPLETE: GLM completed at least one turn but phase-8 sentinel is absent"
  exit 4
fi

_append_receipt "exhausted" "3" "$attempt" "$(cat "$RUN_ID_FILE" 2>/dev/null || true)"
log_error "attempt budget exhausted without Phase-8 completion proof"
exit 3
