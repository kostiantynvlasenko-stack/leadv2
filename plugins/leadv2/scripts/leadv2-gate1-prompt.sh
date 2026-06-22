#!/usr/bin/env bash
# leadv2-gate1-prompt.sh — Gate 1 founder approval prompt.
#
# Usage: leadv2-gate1-prompt.sh <task_id> <class> <plan_summary>
#
# Exit codes:
#   0 — accepted
#   1 — declined
#   2 — timed_out_auto_accepted
#
# Logic:
#   Heavy/Strategic: never auto-accept; wait indefinitely (blocking read)
#   Standard/Light/Trivial:
#     LEADV2_DRY_RUN=1       → auto-accept immediately (no wait)
#     LEADV2_DAEMON=1        → use LEADV2_GATE1_AUTO_ACCEPT_SEC (default 5)
#     non-interactive stdin  → treat as daemon (5s timeout)
#     interactive            → 60s timeout

set -euo pipefail

task_id="${1:?Usage: leadv2-gate1-prompt.sh <task_id> <class> <plan_summary>}"
cls="${2:?class required}"
plan_summary="${3:?plan_summary required}"

log() { printf -- '[gate1] %s\n' "$*" >&2; }

# Register task into active.yaml so recovery hooks and pre-compact checkpoint can find it.
# Uses the active-registry source-able script; falls back to direct YAML write on error.
_gate1_register_active() {
  local _registry
  _registry="$(dirname "${BASH_SOURCE[0]}")/leadv2-active-registry.sh"
  local _yaml_dir="${LEADV2_PROJECT_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}/docs/leadv2"
  mkdir -p "$_yaml_dir"
  if [[ -f "$_registry" ]]; then
    LEADV2_PROJECT_ROOT="${LEADV2_PROJECT_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}" \
      source "$_registry" 2>/dev/null \
      && leadv2_active_register "$task_id" "${cls:-Standard}" "$(pwd)" "" "false" 2>/dev/null \
      && { log "registered task in active.yaml via registry"; return 0; } || true
  fi
  # Fallback: write minimal session row directly (schema per leadv2-pre-compact-checkpoint.sh L34-45)
  local _yaml="${_yaml_dir}/active.yaml"
  local _ts; _ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  python3 - "$_yaml" "$task_id" "${cls:-Standard}" "$_ts" <<'PYEOF' 2>/dev/null || true
import sys, os, fcntl, tempfile
try:
    import yaml
except ImportError:
    sys.exit(0)
yaml_path, task_id, cls, ts = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
lock_path = yaml_path + ".lock"
os.makedirs(os.path.dirname(yaml_path), exist_ok=True)
lock_fd = open(lock_path, "a+")
try:
    fcntl.flock(lock_fd, fcntl.LOCK_EX)
    data = {}
    if os.path.exists(yaml_path):
        with open(yaml_path, encoding="utf-8") as fh:
            data = yaml.safe_load(fh) or {}
    if "sessions" not in data or data["sessions"] is None:
        data["sessions"] = []
    existing = next((s for s in data["sessions"] if s.get("task_id") == task_id), None)
    if not existing:
        data["sessions"].append({
            "session_id": f"s-{ts.replace(':','').replace('-','')}-{os.getpid()}",
            "task_id": task_id,
            "phase": "build",
            "class": cls,
            "gate1_status": "approved",
            "started_at": ts,
            "stale": False,
        })
    d = os.path.dirname(yaml_path)
    fd, tmp = tempfile.mkstemp(dir=d, suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as tf:
            yaml.dump(data, tf, default_flow_style=False, sort_keys=False)
        os.replace(tmp, yaml_path)
    except Exception:
        try: os.unlink(tmp)
        except OSError: pass
        raise
finally:
    fcntl.flock(lock_fd, fcntl.LOCK_UN)
    lock_fd.close()
PYEOF
  log "registered task in active.yaml (fallback direct write)"
}

# On accept: capture context.yaml SHA and write Gate 1 sentinel for C2 guard.
_gate1_accept() {
  local _ctx="docs/handoff/${task_id}/context.yaml"
  if [[ -f "$_ctx" ]]; then
    local _sha; _sha=$(sha256sum "$_ctx" 2>/dev/null | awk '{print $1}' || true)
    local _state="docs/leadv2/tasks/${task_id}/STATE.md"
    if [[ -f "$_state" ]]; then
      grep -q "^gate1_context_sha:" "$_state" 2>/dev/null \
        || printf -- '\ngate1_context_sha: %s\n' "$_sha" >> "$_state"
    fi
  fi
  # Write Gate 1 sentinel — required by leadv2-gate-artifact-guard.sh (C2)
  touch "docs/handoff/${task_id}/.gate1-passed" 2>/dev/null || true
  # Register task in active.yaml — root fix for post-/compact amnesia (C-1 R4)
  _gate1_register_active
}

# ── DRY_RUN: immediate auto-accept ────────────────────────────────────────
if [[ "${LEADV2_DRY_RUN:-0}" == "1" ]]; then
  log "DRY_RUN mode — auto-accepted immediately"
  printf -- 'план: %s. [DRY-RUN — авто-принятие]\n' "$plan_summary"
  _gate1_accept
  exit 2
fi

# ── BOT_MODE: immediate auto-accept (Telegram bot, headless claude -p) ────
if [[ "${LEADV2_BOT_MODE:-0}" == "1" ]]; then
  log "BOT_MODE — auto-accepted immediately"
  printf -- 'Gate 1: auto-accepted (bot mode). plan: %s\n' "$plan_summary"
  _gate1_accept
  exit 2
fi

# ── Heavy / Strategic: block forever, require explicit да/go ──────────────
case "${cls,,}" in
  heavy|strategic)
    printf -- '\n> Gate 1 — HEAVY task. Explicit да/go required.\n'
    printf -- 'задача: %s\nплан: %s\n\n' "$task_id" "$plan_summary"
    printf -- 'принять? [да/go/n]: '
    read -r answer
    case "${answer,,}" in
      да|go|y|yes|d)
        log "accepted by founder (heavy)"
        _gate1_accept
        exit 0
        ;;
      *)
        log "declined by founder"
        exit 1
        ;;
    esac
    ;;
esac

# ── Standard / Light / Trivial: determine timeout ─────────────────────────
# Determine if daemon or non-interactive
is_daemon=false
if [[ "${LEADV2_DAEMON:-0}" == "1" ]]; then
  is_daemon=true
elif [[ ! -t 0 ]]; then
  is_daemon=true  # non-interactive stdin → treat as daemon
fi

if [[ "$is_daemon" == "true" ]]; then
  timeout_sec="${LEADV2_GATE1_AUTO_ACCEPT_SEC:-5}"
else
  timeout_sec=60
fi

# ── Print prompt ───────────────────────────────────────────────────────────
printf -- '\nплан: %s. авто-принятие через %ss. давай? [да/go/n] ' \
  "$plan_summary" "$timeout_sec"

# ── Read with timeout ──────────────────────────────────────────────────────
answer=""
if read -r -t "$timeout_sec" answer 2>/dev/null; then
  # Got a response within timeout
  case "${answer,,}" in
    да|go|y|yes|d)
      log "accepted by founder"
      _gate1_accept
      exit 0
      ;;
    n|no|нет)
      log "declined by founder"
      exit 1
      ;;
    *)
      log "unrecognized input '$answer' — treating as declined"
      exit 1
      ;;
  esac
else
  # Timeout
  printf -- '\n'
  log "Gate 1 auto-accepted (timeout ${timeout_sec}s)"
  _gate1_accept
  exit 2
fi
