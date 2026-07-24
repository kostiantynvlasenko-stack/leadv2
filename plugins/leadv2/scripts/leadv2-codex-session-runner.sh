#!/usr/bin/env bash
# leadv2-codex-session-runner.sh — daemon/resume loop for a complete Codex-led
# /leadv2 child session. The parent Claude/Opus lead remains the supervisor;
# this runner owns one isolated task until the common phase-8 sentinel exists.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
# FIX-HEADLESS-RUNNER-01: guard so a second entry into this script body (same
# process) never hits "readonly variable"; also fixed fallback depth — one
# level up from scripts/, not two (this repo's scripts/ sits directly under
# repo root; `../..` overshot into the parent-of-repo directory).
if ! declare -p PROJECT_ROOT 2>/dev/null | grep -q -- '-r'; then
  PROJECT_ROOT="${LEADV2_PROJECT_ROOT:-${CLAUDE_PROJECT_DIR:-${PROJECT_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}}}"
  readonly PROJECT_ROOT
fi

log() { printf -- '[leadv2-codex-session-runner] %s\n' "$*" >&2; }
log_error() { printf -- '[leadv2-codex-session-runner] ERROR: %s\n' "$*" >&2; }

TASK_ID="${LEADV2_TASK_ID:-}"
if [[ -z "$TASK_ID" ]]; then
  log_error "LEADV2_TASK_ID is required"
  exit 1
fi

CODEX_BIN="${LEADV2_CODEX_BIN:-codex}"
MODEL="${LEADV2_LEAD_MODEL:-gpt-5.6-terra}"
EFFORT="${LEADV2_LEAD_EFFORT:-medium}"
MAX_ATTEMPTS="${LEADV2_RUNNER_MAX_ATTEMPTS:-6}"
RETRY_SLEEP_S="${LEADV2_RUNNER_RETRY_SLEEP_S:-5}"
NOOP_MAX="${LEADV2_RUNNER_NOOP_MAX:-3}"
STALL_MAX="${LEADV2_RUNNER_STALL_MAX:-6}"
FORCE_FRESH="${LEADV2_RUNNER_FORCE_FRESH:-false}"

export LEADV2_DAEMON="${LEADV2_DAEMON:-1}"
export LEADV2_ASYNC_QUESTIONS="${LEADV2_ASYNC_QUESTIONS:-1}"
export LEADV2_FANOUT="${LEADV2_FANOUT:-1}"
export LEADV2_SESSION_PROVIDER="codex"
export LEADV2_TASK_ID="$TASK_ID"

phase67_active() {
  local active phase
  [[ "${LEADV2_PHASE:-}" == "deploy" || "${LEADV2_PHASE:-}" == "verify" ]] && return 0
  active="$(env PROJECT_ROOT="$PROJECT_ROOT" "$SCRIPT_DIR/leadv2-state-path.sh" --no-link active.yaml 2>/dev/null)" || return 1
  phase="$(python3 - "$active" "$TASK_ID" <<'PYEOF' 2>/dev/null
import sys
try:
    import yaml
    data = yaml.safe_load(open(sys.argv[1], encoding='utf-8')) or {}
    for row in data.get('sessions', []):
        if row.get('task_id') == sys.argv[2]:
            print(row.get('phase', ''))
            break
except Exception:
    pass
PYEOF
)"
  [[ "$phase" == "deploy" || "$phase" == "verify" ]]
}

TASK_DIR="$PROJECT_ROOT/docs/handoff/$TASK_ID"
mkdir -p "$TASK_DIR"
SENTINEL="${LEADV2_COMPLETION_SENTINEL:-$TASK_DIR/phase8-passed.flag}"
COMPLETION_RECEIPT="${LEADV2_COMPLETION_RECEIPT:-$(
  env PROJECT_ROOT="$PROJECT_ROOT" \
    "$SCRIPT_DIR/leadv2-state-path.sh" --no-link "completions/${TASK_ID}.json"
)}"
LOCK_FILE="$TASK_DIR/.session-runner.lock"
PID_FILE="$TASK_DIR/.session-runner.pid"
THREAD_ID_FILE="$TASK_DIR/.session-runner.codex-thread-id"
LOGF="$TASK_DIR/codex-session-runner.log"
PROGRESS_TOOL="${LEADV2_PROGRESS_FINGERPRINT:-$SCRIPT_DIR/leadv2-progress-fingerprint.sh}"

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  log_error "another live session runner already owns task $TASK_ID"
  exit 2
fi
printf -- '%s\n' "$$" > "$PID_FILE"

sentinel_present() {
  [[ -f "$SENTINEL" ]] && return 0
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

# Completion proof is checked before touching provider auth. A closed task
# must be a zero-provider-call no-op even when Codex is logged out or absent.
if ! command -v "$CODEX_BIN" >/dev/null 2>&1; then
  log_error "Codex binary unavailable: $CODEX_BIN"
  exit 1
fi
if [[ "${LEADV2_CODEX_SKIP_LOGIN_CHECK:-0}" != "1" ]] && ! "$CODEX_BIN" login status >/dev/null 2>&1; then
  log_error "Codex login unavailable; run 'codex login' before provider=codex"
  exit 1
fi

THREAD_ID=""
if [[ "$FORCE_FRESH" != "true" && "$FORCE_FRESH" != "1" && -f "$THREAD_ID_FILE" ]]; then
  THREAD_ID="$(tr -d '[:space:]' < "$THREAD_ID_FILE")"
fi

_extract_thread_id() {
  python3 - "$LOGF" <<'PYEOF'
import json, sys
path = sys.argv[1]
found = ""
try:
    with open(path, encoding="utf-8", errors="replace") as fh:
        for raw in fh:
            try:
                event = json.loads(raw)
            except Exception:
                continue
            value = event.get("thread_id")
            if event.get("type") == "thread.started" and isinstance(value, str):
                found = value
except FileNotFoundError:
    pass
print(found, end="")
PYEOF
}

_append_receipt() {
  local status="$1" rc="$2" attempt="$3"
  local registry="$SCRIPT_DIR/leadv2-active-registry.sh"
  [[ -f "$registry" ]] || return 0
  # shellcheck source=/dev/null
  source "$registry"
  type leadv2_active_append_provider_receipt >/dev/null 2>&1 || return 0
  local receipt
  receipt="$(python3 - "$TASK_ID" "$MODEL" "$EFFORT" "$THREAD_ID" "$status" "$rc" "$attempt" <<'PYEOF'
import datetime, json, sys
task_id, model, effort, run_id, status, rc, attempt = sys.argv[1:]
print(json.dumps({
    "provider": "codex",
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

# A Codex turn is already inside this runner's flock.  Only an actual
# EXECUTION of a session launcher/dispatcher (session-runner, fanout,
# supervise, *launcher, *dispatcher) is the Codex-lead recursion footgun —
# never a per-phase helper (leadv2-phase8-*, leadv2-gate1-prompt.sh,
# leadv2-verify*).  CODEX-LEAD-RECURSION-FALSEKILL-01: the prior guard matched
# the launcher NAME anywhere in any JSON string value, so a child that merely
# read/listed/grepped a launcher (or echoed the briefing that names one) was
# falsely killed.  Now scan ONLY command_execution.command fields, and within
# each, flag the launcher only at EXECUTION position (invoked directly, or as
# the operand of an interpreter such as bash/sh/source) — never a bare mention
# or an operand to grep/git-ls-files/sed/cat.  Inspect only this turn's
# appended bytes (offset) so previous diagnostic output cannot trip it.
_launcher_spawn_detected() {
  local offset="$1"
  python3 - "$LOGF" "$offset" <<'PYEOF'
import json, os, re, shlex, sys

path, offset = sys.argv[1], int(sys.argv[2])

# A launcher invocation is a single filesystem-path token (no whitespace) whose
# basename is a session launcher/dispatcher.  The path prefix may not span
# spaces, so a multi-word operand that merely ends in a launcher name cannot
# match (e.g. "sed -n 1,5p .../leadv2-codex-session-runner.sh").
LAUNCHER_RE = re.compile(
    r"^(?:[^\s/]*/)*(?:LEADV2_)?leadv2-(?:codex-)?session-runner(?:\.sh)?$"
    r"|^(?:[^\s/]*/)*(?:LEADV2_)?leadv2-(?:fanout|supervise)(?:\.sh)?$"
    r"|^(?:[^\s/]*/)*(?:LEADV2_)?leadv2-[^\s/]*?(?:launcher|dispatcher)(?:\.sh)?$",
    re.I,
)
INTERPRETERS = {"bash", "sh", "zsh", "dash", "ksh", "source", "."}

try:
    with open(path, "rb") as fh:
        fh.seek(offset)
        raw = fh.read().decode("utf-8", "replace")
except FileNotFoundError:
    raise SystemExit(1)

def is_launcher(tok):
    return bool(tok) and not any(c.isspace() for c in tok) and bool(LAUNCHER_RE.match(tok))

def split_unquoted(text):
    # Split on shell command separators (; & | newline parens) OUTSIDE quotes,
    # so a launcher inside a quoted -lc/-c body is still reachable.
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

# GNU `timeout` options that take an argument (consume the NEXT token before
# the DURATION): -k/--kill-after, -s/--signal.
TIMEOUT_ARG_OPTS = {"-k", "--kill-after", "-s", "--signal"}
# GNU `xargs` options that take an argument (consume the NEXT token before the
# PROGRAM): -I/--replace, -n/--max-args, -P/--max-procs, -d/--delimiter, -E,
# -s/--max-chars, -L/--max-lines. Best-effort (covers the arg-taking set).
XARGS_ARG_OPTS = {
    "-I", "--replace", "-n", "--max-args", "-P", "--max-procs",
    "-d", "--delimiter", "-E", "-s", "--max-chars", "-L", "--max-lines",
}

def _next_operand(toks, i, arg_opts):
    # From index i (the token AFTER a `timeout`/`xargs` wrapper), advance past
    # option flags AND their option-args, returning the index of the first
    # operand token (the DURATION for timeout, the PROGRAM for xargs). Handles
    # attached forms (-k5s, --signal=TERM) and the "--" end-of-options sentinel.
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
            i += 1  # consume the separate option-arg token
    return i

def eval_tokens(toks, depth):
    # Return True iff the token stream EXECUTES a launcher as its program
    # (directly, or as the operand of an interpreter / eval / here-string).
    if not toks:
        return False
    i = 0
    while i < len(toks):  # strip leading wrappers so the real program is checked
        t = toks[i]
        if t in ("sudo", "env", "command", "nohup", "setsid") or re.match(r"^[A-Za-z_]\w*=", t):
            i += 1
            continue
        if t == "timeout":  # skip options (and their args), then the DURATION, then the program
            j = _next_operand(toks, i + 1, TIMEOUT_ARG_OPTS)
            if j < len(toks):
                j += 1  # the DURATION operand
            i = j
            continue
        if t == "xargs":  # skip options (and their args), then the program
            i = _next_operand(toks, i + 1, XARGS_ARG_OPTS)
            continue
        break
    if i >= len(toks):
        return False
    prog = toks[i]
    if is_launcher(prog):
        return True
    if prog == "eval":  # eval <rest> — remaining tokens form a command string
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
        # here-string: bash <<< '<cmd>' — token after <<< is fed to the shell
        for j, tok in enumerate(rest):
            if tok == "<<<" and j + 1 < len(rest):
                body = rest[j + 1]
                if is_launcher(body) or scan_command(body, depth + 1):
                    return True
        if k < len(rest):
            operand = rest[k]
            if is_launcher(operand):
                return True
            if has_c and scan_command(operand, depth + 1):  # bash -lc "<body>"
                return True
    return False

def scan_command(text, depth=0):
    if depth > 4:
        return False
    # Command-substitution bodies ($(…) and `…`) are executed by the shell;
    # scan each like a normal command before tokenizing the surface text.
    for body in re.findall(r"\$\(([^)]*)\)|`([^`]*)`", text):
        for b in body:
            if b and scan_command(b, depth + 1):
                return True
    for sub in split_unquoted(text):
        if eval_tokens(shell_tokens(sub), depth):
            return True
    return False

for line in raw.splitlines():
    try:
        obj = json.loads(line)
    except ValueError:
        continue
    item = obj.get("item", obj) if isinstance(obj, dict) else {}
    if not isinstance(item, dict) or item.get("type") != "command_execution":
        continue
    cmd = item.get("command", "")
    if isinstance(cmd, str) and scan_command(cmd):
        raise SystemExit(0)
raise SystemExit(1)
PYEOF
}

log "task=$TASK_ID provider=codex model=$MODEL effort=$EFFORT log=$LOGF resume=${THREAD_ID:-fresh}"

attempt=0
noop_streak=0
stall_streak=0
while (( attempt < MAX_ATTEMPTS )); do
  if [[ -z "$THREAD_ID" ]]; then
    prompt="You ARE ALREADY the leadv2 headless child session for task ${TASK_ID}; execute its Phase 0..8 lifecycle yourself (plan, build, adversarial review, deploy gate, live verification, close). NEVER invoke leadv2-codex-session-runner.sh, leadv2-session-runner.sh, leadv2-fanout.sh, leadv2-supervise.sh, or any launcher/dispatcher: that is self-recursion and will fail on this session's flock. Reuse only per-phase helper scripts and guards (such as leadv2-gate1-prompt.sh and leadv2-phase8-{assert,e2e-gate,close}.sh), never a session launcher. Never bypass a safety, merge, deploy, or phase gate. All founder questions must use .claude/scripts/leadv2-ask.sh because LEADV2_ASYNC_QUESTIONS=1. Stop only after docs/handoff/${TASK_ID}/phase8-passed.flag or its validated shared completion receipt exists, or a circuit breaker requires the supervising founder."
    cmd=("$CODEX_BIN" exec --json --model "$MODEL" -c "model_reasoning_effort=\"$EFFORT\"" -C "$PROJECT_ROOT")
    if [[ "${LEADV2_UNSAFE_AUTOPILOT:-0}" == "1" ]]; then
      log "UNSAFE_AUTOPILOT receipt: full Codex approval and sandbox bypass enabled"
      cmd+=(--dangerously-bypass-approvals-and-sandbox)
    else
      cmd+=(--sandbox workspace-write)
      # Phase 6/7 is the sole escalation point. It keeps workspace-write (no
      # sandbox bypass) while allowing the fixed deploy/verify script calls to
      # use their required network operations without an unattended prompt.
      if phase67_active; then
        cmd+=( -c 'approval_policy="never"' -c 'sandbox_workspace_write.network_access=true' )
      fi
    fi
    [[ "${LEADV2_CODEX_BYPASS_HOOK_TRUST:-0}" == "1" ]] && cmd+=(--dangerously-bypass-hook-trust)
    cmd+=("$prompt")
    _mode="fresh"
  else
    prompt="Continue task ${TASK_ID} as the ALREADY-RUNNING leadv2 child session: execute the current Phase 0..8 work yourself. NEVER invoke leadv2-codex-session-runner.sh, leadv2-session-runner.sh, leadv2-fanout.sh, leadv2-supervise.sh, or any launcher/dispatcher; doing so is self-recursion under your own flock. Use only per-phase helper scripts, never session launchers. Re-check every sentinel and provider receipt before repeating any side effect. Drive it to canonical Phase-8 completion proof; route any founder decision through leadv2-ask.sh."
    cmd=("$CODEX_BIN" exec resume --json --model "$MODEL" -c "model_reasoning_effort=\"$EFFORT\"")
    if [[ "${LEADV2_UNSAFE_AUTOPILOT:-0}" == "1" ]]; then
      log "UNSAFE_AUTOPILOT receipt: full Codex approval and sandbox bypass enabled"
      cmd+=(--dangerously-bypass-approvals-and-sandbox)
    else
      cmd+=(--sandbox workspace-write)
      if phase67_active; then
        cmd+=( -c 'approval_policy="never"' -c 'sandbox_workspace_write.network_access=true' )
      fi
    fi
    [[ "${LEADV2_CODEX_BYPASS_HOOK_TRUST:-0}" == "1" ]] && cmd+=(--dangerously-bypass-hook-trust)
    cmd+=("$THREAD_ID" "$prompt")
    _mode="resume"
  fi

  log "attempt $attempt/$MAX_ATTEMPTS: codex $_mode"
  progress_before="$("$PROGRESS_TOOL" "$TASK_ID" 2>/dev/null || printf -- 'unknown-before')"
  log_size_before="$(wc -c < "$LOGF" 2>/dev/null || printf -- '0')"
  set +e
  (cd "$PROJECT_ROOT" && "${cmd[@]}") >> "$LOGF" 2>&1
  rc=$?
  set -e

  if [[ -z "$THREAD_ID" ]]; then
    THREAD_ID="$(_extract_thread_id)"
    if [[ -n "$THREAD_ID" ]]; then
      printf -- '%s\n' "$THREAD_ID" > "$THREAD_ID_FILE"
      log "captured Codex thread_id=$THREAD_ID"
    fi
  fi

  progress_after="$("$PROGRESS_TOOL" "$TASK_ID" 2>/dev/null || printf -- 'unknown-after')"
  if _launcher_spawn_detected "$log_size_before"; then
    _append_receipt "recursion_detected" "$rc" "$attempt"
    log_error "CODEX-LEAD RECURSION: Codex tried to spawn a leadv2 launcher/dispatcher from its already-running child session; stopping immediately"
    exit 5
  fi
  if [[ "$progress_before" == "$progress_after" ]]; then
    stall_streak=$((stall_streak + 1))
    log "attempt $attempt changed no phase/git/handoff evidence (stall_streak=${stall_streak}/${STALL_MAX})"
  else
    stall_streak=0
  fi

  _status="failed"
  [[ "$rc" -eq 0 ]] && _status="turn_completed"
  _append_receipt "$_status" "$rc" "$attempt"
  log "attempt $attempt exited rc=$rc thread_id=${THREAD_ID:-missing}"

  if sentinel_present; then
    _append_receipt "complete" "0" "$attempt"
    log "Phase-8 completion proof observed for $TASK_ID"
    exit 0
  fi

  if [[ -z "$THREAD_ID" ]]; then
    log_error "Codex emitted no thread.started receipt; refusing a blind fresh restart"
    exit 3
  fi

  log_size_after="$(wc -c < "$LOGF" 2>/dev/null || printf -- '0')"
  if (( log_size_after <= log_size_before )); then
    noop_streak=$((noop_streak + 1))
  else
    noop_streak=0
  fi

  attempt=$((attempt + 1))
  if (( noop_streak >= NOOP_MAX )); then
    log_error "$noop_streak consecutive attempts produced no output — stopping"
    break
  fi
  if (( stall_streak >= STALL_MAX )); then
    log_error "CODEX-LEAD RECURSION suspected: $stall_streak consecutive turns changed no phase/git/handoff evidence while this runner owns the flock — stopping early to prevent token-burning resumes"
    break
  fi
  if (( attempt < MAX_ATTEMPTS )); then
    sleep "$RETRY_SLEEP_S"
  fi
done

if grep -Eq '"type"[[:space:]]*:[[:space:]]*"turn.completed"' "$LOGF" 2>/dev/null; then
  _append_receipt "incomplete" "4" "$attempt"
  log "INCOMPLETE: Codex completed at least one turn but phase-8 sentinel is absent"
  exit 4
fi

_append_receipt "exhausted" "3" "$attempt"
log_error "attempt budget exhausted without Phase-8 completion proof"
exit 3
