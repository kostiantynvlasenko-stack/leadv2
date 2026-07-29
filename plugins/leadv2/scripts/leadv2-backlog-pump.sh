#!/usr/bin/env bash
# leadv2-backlog-pump.sh — BACKLOG-PUMP-01. Observes "capacity is free AND the
# queue is non-empty" and starts work — the mechanism that did not exist
# before this: every dispatch used to be lead-initiated, so throughput tracked
# whatever the lead's attention happened to be on.
#
# QUEUE SOURCE: docs/tasks.yaml via leadv2-tasks-lib.sh — NOT a second
# backlog. leadv2_tasks_top_n already (a) excludes lane=human-needed (the
# judgment-class tasks — paid/irreversible/architecture triage), (b) excludes
# claimed/blocked-by-deps rows, (c) sorts by lane-rank/priority/created_at.
# This script adds exactly the missing piece: the refill trigger + bounds.
#
# COMPOSITION (never bypassed, never re-implemented here):
#   - duplicate-signature refusal: leadv2-dispatch-code.sh owns the
#     task-signature ledger. This script calls it for every dispatch and
#     treats rc=2 (duplicate) as "skip, not a slot" — never re-derives sig
#     dedup itself.
#   - quota-driven arm selection (150c42f): leadv2-dispatch-code.sh's router
#     picks glm/sonnet/codex internally. This script's own quota-floor check
#     (below) is a DIFFERENT question — "should the pump start ANYTHING right
#     now" — not "which provider".
#   - lane-shape close requirements (87dac6a): `reap` reuses the identical
#     `git diff --name-only <base>...HEAD` emptiness check
#     leadv2-lane-shape.sh cmd_retro_check already uses, so "produced
#     nothing" is derived the same way in both places.
#   - outcome ledger (lane 0cf52efc, in flight, not yet merged at the time
#     this was written): if a sibling script LEADV2_OUTCOME_LEDGER_BIN (or
#     ${SCRIPT_DIR}/leadv2-outcome-ledger.sh) exists, `reap` prefers its
#     verdict over the git-diff heuristic below — forward-compatible, never
#     assumes its schema.
#
# BOUNDS (mission requirement — state every bound + what happens when it trips):
#   1. Master off switch: LEADV2_BACKLOG_PUMP=1 required to do ANYTHING beyond
#      `status`/`dry-run`. Default 0 = today's behaviour, unchanged. One flag
#      flip is the entire rollback.
#   2. Concurrency cap: LEADV2_BACKLOG_PUMP_MAX (default: active.yaml
#      meta.hard_limit, else 3). At/over cap -> `check` exits 0, no dispatch,
#      logged "at_capacity".
#   3. Quota floor: LEADV2_BACKLOG_PUMP_QUOTA_FLOOR (default 10, percent). No
#      provider bucket has usable_now or remaining_pct >= floor -> `check`
#      refuses everything, logged "quota_floor".
#   4. Judgment-class exclusion: lane=human-needed is never even a candidate
#      (tasks-lib). A candidate that IS dispatched but resolves to arm=opus
#      (leadv2-dispatch-code.sh rc=3) is unclaimed and surfaced via
#      open-threads.md instead of retried — opus arm is lead/founder
#      judgment, never auto-dispatched (matches leadv2-dispatch-code.sh's own
#      documented contract).
#   5. Empty-outcome bound: `reap` requeues a task that closed with zero diff
#      ONCE (leadv2_tasks_unclaim keeps its attempt counter, so normal
#      max_attempts still applies); a SECOND consecutive empty close flips
#      lane to human-needed instead of requeuing again — a task can never
#      spin the pump forever.
#   6. Bounded scan: LEADV2_BACKLOG_PUMP_MAX_CANDIDATES (default 8) per
#      `check` invocation — a pathological queue can't turn one call into an
#      unbounded loop; the next poll cycle continues where this one stopped.
#
# Usage:
#   leadv2-backlog-pump.sh check              # refill up to capacity; safe,
#                                                idempotent, called by
#                                                leadv2-supervise-loop.sh
#   leadv2-backlog-pump.sh dry-run [N]        # print next N candidates +
#                                                reason, priority order, NO
#                                                side effects (default 3)
#   leadv2-backlog-pump.sh status             # enabled/max/active/capacity
#   leadv2-backlog-pump.sh reap <task_id> [--base <ref>]
#                                              # call at lane close: detect
#                                                empty-outcome, requeue/park
#
# Env overrides (test sandboxing): LEADV2_PROJECT_ROOT / CLAUDE_PROJECT_DIR /
# PROJECT_ROOT — repo root. LEADV2_BACKLOG_PUMP_DISPATCH_BIN overrides the
# dispatch entry point (tests). LEADV2_BACKLOG_PUMP_QUOTA_BIN overrides the
# quota reader (tests — avoids coupling to this machine's real live quota).
# LEADV2_JOURNAL_BIN overrides the journal.
# Per-repo override: .claude/leadv2-overrides/backlog-pump.yaml — optional
# keys `enabled`, `max_concurrent`, `quota_floor_pct` (env always wins).

set -uo pipefail   # no -e: refusals must journal and continue, never abort

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="leadv2-backlog-pump"

log()     { printf -- '[%s] %s\n' "$SCRIPT_NAME" "$*" >&2; }
log_err() { printf -- '[%s] ERROR: %s\n' "$SCRIPT_NAME" "$*" >&2; }

# ── fail-closed root resolution (same order as leadv2-supervise.sh) ────────
PROJECT_ROOT=""
if [[ -n "${LEADV2_PROJECT_ROOT:-}" ]]; then
  PROJECT_ROOT="$LEADV2_PROJECT_ROOT"
elif [[ -n "${CLAUDE_PROJECT_DIR:-}" ]]; then
  PROJECT_ROOT="$CLAUDE_PROJECT_DIR"
elif _lv2bp_top="$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null)"; then
  PROJECT_ROOT="$_lv2bp_top"
fi
if [[ -z "$PROJECT_ROOT" ]]; then
  log_err "root_error: could not resolve project root — set LEADV2_PROJECT_ROOT or CLAUDE_PROJECT_DIR"
  exit 1
fi
export LEADV2_PROJECT_ROOT="$PROJECT_ROOT"
export PROJECT_ROOT

# shellcheck source=leadv2-tasks-lib.sh
source "${SCRIPT_DIR}/leadv2-tasks-lib.sh"

JOURNAL_BIN="${LEADV2_JOURNAL_BIN:-${SCRIPT_DIR}/leadv2-journal.sh}"
DISPATCH_BIN="${LEADV2_BACKLOG_PUMP_DISPATCH_BIN:-${SCRIPT_DIR}/leadv2-dispatch-code.sh}"
JOURNAL_TASK="backlog-pump"

jemit() {  # $1=type $2..=text — never fails the caller
  local jtype="$1"; shift
  local line="$*"
  if [[ -f "${JOURNAL_BIN}" ]]; then
    bash "${JOURNAL_BIN}" append "${JOURNAL_TASK}" "${jtype}" "${line}" >/dev/null 2>&1 || true
  fi
  log "${line}"
}

OVERRIDE_YAML="${PROJECT_ROOT}/.claude/leadv2-overrides/backlog-pump.yaml"

_override() {  # $1=key $2=default -> value
  local key="$1" default="$2"
  [[ -f "$OVERRIDE_YAML" ]] || { printf '%s' "$default"; return; }
  local v
  v="$(grep -E "^[[:space:]]*${key}[[:space:]]*:" "$OVERRIDE_YAML" 2>/dev/null | head -1 \
       | sed -E "s/^[[:space:]]*${key}[[:space:]]*:[[:space:]]*//" \
       | sed -E "s/^['\"]//; s/['\"][[:space:]]*\$//" | tr -d '\r')"
  [[ -n "$v" && "$v" != "null" ]] && printf '%s' "$v" || printf '%s' "$default"
}

# ── config resolution: env > per-repo override > default ───────────────────
PUMP_ENABLED="${LEADV2_BACKLOG_PUMP:-$(_override enabled 0)}"

ACTIVE_YAML="$(PROJECT_ROOT="$PROJECT_ROOT" "${SCRIPT_DIR}/leadv2-state-path.sh" active.yaml 2>/dev/null)"

_active_hard_limit() {
  [[ -n "$ACTIVE_YAML" && -f "$ACTIVE_YAML" ]] || { printf '3'; return; }
  python3 -c "
import yaml, sys
try:
    d = yaml.safe_load(open(sys.argv[1])) or {}
except Exception:
    print(3); sys.exit(0)
print((d.get('meta') or {}).get('hard_limit', 3))
" "$ACTIVE_YAML" 2>/dev/null || printf '3'
}

MAX_CONCURRENT="${LEADV2_BACKLOG_PUMP_MAX:-$(_override max_concurrent "$(_active_hard_limit)")}"
QUOTA_FLOOR="${LEADV2_BACKLOG_PUMP_QUOTA_FLOOR:-$(_override quota_floor_pct 10)}"
MAX_CANDIDATES="${LEADV2_BACKLOG_PUMP_MAX_CANDIDATES:-8}"

_active_count() {
  [[ -n "$ACTIVE_YAML" && -f "$ACTIVE_YAML" ]] || { printf '0'; return; }
  python3 -c "
import yaml, sys
try:
    d = yaml.safe_load(open(sys.argv[1])) or {}
except Exception:
    print(0); sys.exit(0)
print(len(d.get('sessions') or []))
" "$ACTIVE_YAML" 2>/dev/null || printf '0'
}

_active_task_ids() {
  [[ -n "$ACTIVE_YAML" && -f "$ACTIVE_YAML" ]] || return 0
  python3 -c "
import yaml, sys
try:
    d = yaml.safe_load(open(sys.argv[1])) or {}
except Exception:
    sys.exit(0)
for s in (d.get('sessions') or []):
    tid = s.get('task_id')
    if tid: print(tid)
" "$ACTIVE_YAML" 2>/dev/null
}

# ── quota headroom: at least one provider bucket must clear the floor ───────
_quota_ok() {
  local qbin="${LEADV2_BACKLOG_PUMP_QUOTA_BIN:-${SCRIPT_DIR}/leadv2-quota-live.sh}"
  [[ -x "$qbin" ]] || return 0   # quota reader absent (test env) -> fail-open, not fail-blank
  local json
  json="$(bash "$qbin" json 2>/dev/null)" || return 0
  python3 -c "
import json, sys
floor = float(sys.argv[2])
try:
    d = json.loads(sys.argv[1])
except Exception:
    sys.exit(0)   # unparseable -> fail-open (never invent a 0%)
for bucket in ('glm', 'codex', 'anthropic'):
    b = d.get(bucket) or {}
    if b.get('status') != 'ok':
        continue
    if b.get('usable_now') is True:
        sys.exit(0)
    pct = b.get('remaining_pct')
    if isinstance(pct, (int, float)) and pct >= floor:
        sys.exit(0)
sys.exit(1)
" "$json" "$QUOTA_FLOOR"
}

_mission_for_task() {  # $1=task_id -> mission text (title + note), empty if not found
  local tid="$1" row
  row="$(leadv2_tasks_by_id "$tid" 2>/dev/null)" || { printf ''; return; }
  python3 -c "
import yaml, sys
items = yaml.safe_load(sys.argv[1]) or []
it = items[0] if items else {}
title = it.get('title', '')
note = it.get('note', '')
origin = it.get('origin', '')
parts = [p for p in (title, note) if p]
if origin:
    parts.append(f'(origin: {origin})')
print(' — '.join(parts) if parts else title)
" "$row" 2>/dev/null
}

cmd_status() {
  local active cap
  active="$(_active_count)"
  cap=$(( MAX_CONCURRENT - active ))
  (( cap < 0 )) && cap=0
  printf 'enabled=%s max_concurrent=%s active=%s capacity=%s quota_floor=%s%%\n' \
    "$PUMP_ENABLED" "$MAX_CONCURRENT" "$active" "$cap" "$QUOTA_FLOOR"
}

cmd_dry_run() {
  local n="${1:-3}"
  local active cap
  active="$(_active_count)"
  cap=$(( MAX_CONCURRENT - active ))
  (( cap < 0 )) && cap=0
  local raw
  raw="$(leadv2_tasks_top_n "$MAX_CANDIDATES" 2>/dev/null || true)"
  if [[ -z "$raw" ]]; then
    printf 'queue empty — nothing would start\n'
    return 0
  fi
  local i=0
  while IFS=$'\t' read -r lane priority iid title; do
    [[ -z "$iid" ]] && continue
    i=$((i + 1))
    (( i > n )) && break
    if (( i <= cap )); then
      printf '%d. %s [%s/%s] %s — would dispatch: next in priority order, capacity available (%d/%d slots free)\n' \
        "$i" "$iid" "$lane" "$priority" "$title" "$cap" "$MAX_CONCURRENT"
    else
      printf '%d. %s [%s/%s] %s — would NOT dispatch yet: no free capacity (%d/%d in use)\n' \
        "$i" "$iid" "$lane" "$priority" "$title" "$active" "$MAX_CONCURRENT"
    fi
  done <<<"$raw"
}

cmd_check() {
  if [[ "$PUMP_ENABLED" != "1" ]]; then
    log "disabled (LEADV2_BACKLOG_PUMP=0) — no-op"
    return 0
  fi

  local active cap
  active="$(_active_count)"
  cap=$(( MAX_CONCURRENT - active ))
  if (( cap <= 0 )); then
    jemit decision "pump_refused reason=at_capacity active=${active} max=${MAX_CONCURRENT}"
    return 0
  fi

  if ! _quota_ok; then
    jemit decision "pump_refused reason=quota_floor floor=${QUOTA_FLOOR}pct"
    return 0
  fi

  local raw
  raw="$(leadv2_tasks_top_n "$MAX_CANDIDATES" 2>/dev/null || true)"
  if [[ -z "$raw" ]]; then
    log "queue empty — nothing to pump"
    return 0
  fi

  local running_ids; running_ids="$(_active_task_ids)"
  local examined=0 dispatched=0

  while IFS=$'\t' read -r lane priority iid title; do
    [[ -z "$iid" ]] && continue
    (( cap <= 0 )) && break
    examined=$((examined + 1))
    (( examined > MAX_CANDIDATES )) && break

    if grep -qxF "$iid" <<<"$running_ids" 2>/dev/null; then
      log "skip ${iid}: already running (race guard)"
      continue
    fi

    if ! leadv2_tasks_claim "$iid" --by "backlog-pump" >/dev/null 2>&1; then
      jemit decision "pump_skip task=${iid} reason=claim_race"
      continue
    fi

    local mission; mission="$(_mission_for_task "$iid")"
    if [[ -z "$mission" ]]; then
      mission="$title"
    fi

    local rc=0
    bash "$DISPATCH_BIN" "$mission" --kind "backlog-pump" >/dev/null 2>&1 || rc=$?

    case "$rc" in
      0)
        jemit decision "pump_dispatched task=${iid} lane=${lane} priority=${priority} reason=priority_order rank=${examined}"
        dispatched=$((dispatched + 1))
        cap=$((cap - 1))
        ;;
      2)
        jemit decision "pump_skip task=${iid} reason=duplicate_task_signature"
        leadv2_tasks_unclaim "$iid" >/dev/null 2>&1 || true
        ;;
      3)
        jemit decision "pump_deferred_to_founder task=${iid} reason=opus_arm_requires_judgment"
        leadv2_tasks_unclaim "$iid" >/dev/null 2>&1 || true
        _surface_to_founder "$iid" "requires judgment (opus arm) — pump will not auto-start this"
        ;;
      *)
        jemit decision "pump_skip task=${iid} reason=spawn_failed rc=${rc}"
        leadv2_tasks_unclaim "$iid" >/dev/null 2>&1 || true
        ;;
    esac
  done <<<"$raw"

  log "check complete: examined=${examined} dispatched=${dispatched} remaining_capacity=${cap}"
}

_surface_to_founder() {  # $1=task_id $2=reason -> append to open-threads.md
  local iid="$1" reason="$2"
  local threads; threads="$(PROJECT_ROOT="$PROJECT_ROOT" "${SCRIPT_DIR}/leadv2-state-path.sh" open-threads.md 2>/dev/null)"
  [[ -n "$threads" ]] || return 0
  printf -- '- [ ] %s — backlog-pump: task %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$iid" "$reason" >>"$threads" 2>/dev/null || true
}

# ── reap: detect empty-outcome close, bound the retry, never spin forever ──
EMPTY_STREAK_DIR="${PROJECT_ROOT}/.claude/cache/backlog-pump-empty-streak"

cmd_reap() {
  local tid="${1:?reap requires <task_id>}"; shift || true
  local base="main"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --base) base="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  # Forward-compat: prefer the outcome ledger's own verdict once it exists.
  local outcome_bin="${LEADV2_OUTCOME_LEDGER_BIN:-${SCRIPT_DIR}/leadv2-outcome-ledger.sh}"
  local is_empty=""
  if [[ -x "$outcome_bin" ]]; then
    local v
    v="$(bash "$outcome_bin" status "$tid" 2>/dev/null || true)"
    case "$v" in
      *empty*|*produced_nothing*) is_empty=1 ;;
      *) is_empty="" ;;
    esac
  fi

  if [[ -z "$is_empty" ]]; then
    local files
    files="$(git -C "$PROJECT_ROOT" diff --name-only "${base}...HEAD" 2>/dev/null || true)"
    [[ -z "$files" ]] && is_empty=1
  fi

  if [[ -z "$is_empty" ]]; then
    log "reap ${tid}: non-empty outcome — nothing to do"
    return 0
  fi

  mkdir -p "$EMPTY_STREAK_DIR" 2>/dev/null || true
  local streak_file="${EMPTY_STREAK_DIR}/${tid//\//_}"
  local streak=0
  [[ -f "$streak_file" ]] && streak="$(cat "$streak_file" 2>/dev/null || echo 0)"
  streak=$((streak + 1))

  if (( streak >= 2 )); then
    jemit decision "pump_reap task=${tid} outcome=empty streak=${streak} action=parked_human_needed"
    leadv2_tasks_update "$tid" --key lane --value human-needed >/dev/null 2>&1 || true
    _surface_to_founder "$tid" "closed empty ${streak}x in a row — parked, will not auto-retry"
    rm -f "$streak_file" 2>/dev/null || true
  else
    jemit decision "pump_reap task=${tid} outcome=empty streak=${streak} action=requeued"
    leadv2_tasks_unclaim "$tid" >/dev/null 2>&1 || true
    printf '%s' "$streak" >"$streak_file" 2>/dev/null || true
  fi
}

# ── dispatch ─────────────────────────────────────────────────────────────────
MODE="${1:-check}"
shift || true
case "$MODE" in
  check)    cmd_check "$@" ;;
  dry-run)  cmd_dry_run "$@" ;;
  status)   cmd_status "$@" ;;
  reap)     cmd_reap "$@" ;;
  -h|--help)
    printf 'Usage: %s check|dry-run [N]|status|reap <task_id> [--base <ref>]\n' "$SCRIPT_NAME" >&2
    ;;
  *)
    log_err "unknown mode: $MODE"
    exit 1
    ;;
esac
