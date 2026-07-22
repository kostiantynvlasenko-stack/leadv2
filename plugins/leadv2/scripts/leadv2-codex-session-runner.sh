#!/usr/bin/env bash
# leadv2-codex-session-runner.sh — daemon/resume loop for a complete Codex-led
# /leadv2 child session. The parent Claude/Opus lead remains the supervisor;
# this runner owns one isolated task until the common phase-8 sentinel exists.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
PROJECT_ROOT="${LEADV2_PROJECT_ROOT:-${CLAUDE_PROJECT_DIR:-${PROJECT_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}}}"
readonly PROJECT_ROOT

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
STALL_MAX="${LEADV2_RUNNER_STALL_MAX:-2}"
FORCE_FRESH="${LEADV2_RUNNER_FORCE_FRESH:-false}"

export LEADV2_DAEMON="${LEADV2_DAEMON:-1}"
export LEADV2_ASYNC_QUESTIONS="${LEADV2_ASYNC_QUESTIONS:-1}"
export LEADV2_FANOUT="${LEADV2_FANOUT:-1}"
export LEADV2_SESSION_PROVIDER="codex"
export LEADV2_TASK_ID="$TASK_ID"

phase67_active() {
  local active phase
  [[ "${LEADV2_PHASE:-}" == "deploy" || "${LEADV2_PHASE:-}" == "verify" ]] && return 0
  active="$(PROJECT_ROOT="$PROJECT_ROOT" "$SCRIPT_DIR/leadv2-state-path.sh" --no-link active.yaml 2>/dev/null)" || return 1
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

log "task=$TASK_ID provider=codex model=$MODEL effort=$EFFORT log=$LOGF resume=${THREAD_ID:-fresh}"

attempt=0
noop_streak=0
stall_streak=0
while (( attempt < MAX_ATTEMPTS )); do
  if [[ -z "$THREAD_ID" ]]; then
    prompt="Use the available leadv2 skill (source-command-leadv2 or plugin leadv2) and run task ${TASK_ID} as a headless child. Drive the full lifecycle through plan, build, adversarial review, deploy gate, live verification, and close. Reuse the existing leadv2 scripts and guards; never bypass a safety, merge, deploy, or phase gate. All founder questions must use .claude/scripts/leadv2-ask.sh because LEADV2_ASYNC_QUESTIONS=1. Stop only after docs/handoff/${TASK_ID}/phase8-passed.flag or its validated shared completion receipt exists, or a circuit breaker requires the supervising founder."
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
    prompt="Continue leadv2 task ${TASK_ID} from its current phase. Re-check every sentinel and provider receipt before repeating any side effect. Drive it to canonical Phase-8 completion proof; route any founder decision through leadv2-ask.sh."
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
    log_error "$stall_streak consecutive turns changed no phase/git/handoff evidence — stopping to prevent token-burning resumes"
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
