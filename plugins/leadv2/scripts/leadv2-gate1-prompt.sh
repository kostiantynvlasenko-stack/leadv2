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

# ── DRY_RUN: immediate auto-accept ────────────────────────────────────────
if [[ "${LEADV2_DRY_RUN:-0}" == "1" ]]; then
  log "DRY_RUN mode — auto-accepted immediately"
  printf -- 'план: %s. [DRY-RUN — авто-принятие]\n' "$plan_summary"
  exit 2
fi

# ── BOT_MODE: immediate auto-accept (Telegram bot, headless claude -p) ────
if [[ "${LEADV2_BOT_MODE:-0}" == "1" ]]; then
  log "BOT_MODE — auto-accepted immediately"
  printf -- 'Gate 1: auto-accepted (bot mode). plan: %s\n' "$plan_summary"
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
  exit 2
fi
