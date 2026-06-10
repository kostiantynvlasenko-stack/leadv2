#!/usr/bin/env bash
# leadv2-self-spawn.sh — Phase 8 daemon self-spawn. Extracted verbatim from commands/leadv2.md
# Phase 8 bash block (src lines 341-360). Guard: only runs when LEADV2_DAEMON=1.
# Caller pattern: [[ "${LEADV2_DAEMON:-0}" == "1" ]] && bash "${CLAUDE_PLUGIN_ROOT}/scripts/leadv2-self-spawn.sh" || true
#
# C1.3: When LEADV2_PARALLEL_DISPATCH=1, fills all free Standard slots sequentially
# (one spawner call, hard-limit recheck, 100ms sleep, next). Heavy tasks stay single-session.
# Flag absent = byte-identical to pre-patch single-claim path.
set -euo pipefail

: "${LEADV2_TASK_ID:?LEADV2_TASK_ID must be set}"
: "${CLAUDE_PLUGIN_ROOT:?CLAUDE_PLUGIN_ROOT must be set}"

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Helper: get budget by class (D17) ───────────────────────────────────────
_budget_for_class() {
  case "${1:-Standard}" in
    Light)    printf -- '3' ;;
    Heavy)    printf -- '12' ;;
    *)        printf -- '5' ;;   # Standard default
  esac
}

# ── Helper: get task class from tasks.yaml ────────────────────────────────────
_task_class() {
  local task_id="$1"
  python3 - "$task_id" "${PROJECT_ROOT:-$(git -C "$_SCRIPT_DIR" rev-parse --show-toplevel)}/docs/tasks.yaml" 2>/dev/null <<'TASK_CLASS_PY' || printf -- 'Standard'
import sys, yaml
tid, tasks_file = sys.argv[1], sys.argv[2]
try:
    items = yaml.safe_load(open(tasks_file)) or []
except Exception:
    items = []
for it in items:
    if str(it.get("id","")) == tid:
        cls = (it.get("context") or {}).get("class") or it.get("class") or "Standard"
        print(cls, end="")
        sys.exit(0)
print("Standard", end="")
TASK_CLASS_PY
}

if [[ "${LEADV2_DAEMON:-0}" == "1" ]]; then

  # ── C1.3: Parallel dispatch fill-all-free-slots path ─────────────────────
  if [[ "${LEADV2_PARALLEL_DISPATCH:-0}" == "1" ]]; then
    SPAWNS=$(cat docs/leadv2/spawns-today.txt 2>/dev/null || echo 0)
    MAX="${LEADV2_MAX_SELF_SPAWNS_PER_DAY:-4}"

    # Load active.yaml to determine free standard slots
    _active_yaml="${PROJECT_ROOT:-$(git -C "$_SCRIPT_DIR" rev-parse --show-toplevel)}/docs/leadv2/active.yaml"
    _free_slots=$(python3 - "$_active_yaml" 2>/dev/null <<'FREE_SLOTS_PY' || echo 0
import sys, yaml
try:
    d = yaml.safe_load(open(sys.argv[1])) or {}
except Exception:
    d = {}
meta = d.get("meta") or {}
standard_max = int(meta.get("standard_max", 2))
sessions = d.get("sessions") or []
active_standard = sum(
    1 for s in sessions
    if s.get("status") not in ("closed", "done", "failed")
    and s.get("class","Standard") in ("Standard","Light")
)
free = max(0, standard_max - active_standard)
print(free, end="")
FREE_SLOTS_PY
)

    _remaining=$(( MAX - SPAWNS ))
    _to_fill=$(python3 -c "print(min(${_free_slots}, ${_remaining}))" 2>/dev/null || echo 0)

    if [[ "$_to_fill" -le 0 ]]; then
      printf -- '[self-spawn] parallel dispatch: no free slots (free=%s remaining_daily=%s)
'         "$_free_slots" "$_remaining" >&2
      exit 0
    fi

    printf -- '[self-spawn] parallel dispatch: filling %d slot(s)
' "$_to_fill" >&2
    _filled=0
    _seen_tasks=()

    while [[ $_filled -lt $_to_fill ]]; do
      # Hard-limit recheck before each claim
      _free_now=$(python3 - "$_active_yaml" 2>/dev/null <<'FREE_SLOTS_PY' || echo 0
import sys, yaml
try:
    d = yaml.safe_load(open(sys.argv[1])) or {}
except Exception:
    d = {}
meta = d.get("meta") or {}
standard_max = int(meta.get("standard_max", 2))
sessions = d.get("sessions") or []
active_standard = sum(
    1 for s in sessions
    if s.get("status") not in ("closed", "done", "failed")
    and s.get("class","Standard") in ("Standard","Light")
)
free = max(0, standard_max - active_standard)
print(free, end="")
FREE_SLOTS_PY
)
      if [[ "$_free_now" -le 0 ]]; then
        printf -- '[self-spawn] hard-limit reached after %d fills
' "$_filled" >&2
        break
      fi

      # Claim next dep-free, non-Heavy task
      NEXT=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/leadv2-queue-claim.sh" --by "$LEADV2_TASK_ID" 2>/dev/null) && _claim_rc=0 || _claim_rc=$?
      if [[ "$_claim_rc" -eq 2 || -z "$NEXT" ]]; then
        printf -- '[self-spawn] no more claimable tasks
' >&2
        break
      elif [[ "$_claim_rc" -ne 0 ]]; then
        printf -- '[self-spawn] claim error (rc=%s), stopping fill
' "$_claim_rc" >&2
        break
      fi

      _next_id="${NEXT#*:}"

      # D17: Heavy tasks stay single-session — unclaim and stop if Heavy claimed
      _cls=$(_task_class "$_next_id")
      if [[ "$_cls" == "Heavy" ]]; then
        printf -- '[self-spawn] claimed Heavy task %s — unclaiming, stopping fill
' "$_next_id" >&2
        bash "${_SCRIPT_DIR}/leadv2-tasks-lib.sh" 2>/dev/null || true
        source "${_SCRIPT_DIR}/leadv2-tasks-lib.sh" 2>/dev/null || true
        leadv2_tasks_unclaim "$_next_id" 2>/dev/null || true
        break
      fi

      # Dedup: skip if already seen this cycle
      for _seen in "${_seen_tasks[@]:-}"; do
        if [[ "$_seen" == "$_next_id" ]]; then
          printf -- '[self-spawn] duplicate claim %s — breaking
' "$_next_id" >&2
          break 2
        fi
      done
      _seen_tasks+=("$_next_id")

      # Collision check: compare against all previously claimed tasks this cycle
      _collision=false
      for _prev_id in "${_seen_tasks[@]:-}"; do
        if [[ "$_prev_id" == "$_next_id" ]]; then continue; fi
        _coll_out=$(bash "${_SCRIPT_DIR}/leadv2-collision-check.sh" --compare-tasks "$_prev_id" "$_next_id" 2>&1) && _coll_rc=0 || _coll_rc=$?
        if [[ "$_coll_rc" -eq 2 ]]; then
          printf -- '[self-spawn] footprint collision %s vs %s — unclaiming %s
'             "$_prev_id" "$_next_id" "$_next_id" >&2
          source "${_SCRIPT_DIR}/leadv2-tasks-lib.sh" 2>/dev/null || true
          leadv2_tasks_unclaim "$_next_id" 2>/dev/null || true
          _collision=true
          break
        fi
      done
      if [[ "$_collision" == "true" ]]; then
        # Remove last entry from _seen_tasks
        unset '_seen_tasks[-1]'
        # 100ms sleep between spawner calls (D11)
        sleep 0.1
        continue
      fi

      # Scale budget by class (D17)
      _budget=$(_budget_for_class "$_cls")
      LEADV2_SPAWN_BUDGET="$_budget" bash "${CLAUDE_PLUGIN_ROOT}/scripts/leadv2-session-spawner.sh" "$_next_id"
      SPAWNS=$(( SPAWNS + 1 ))
      printf -- '%d
' "$SPAWNS" > docs/leadv2/spawns-today.txt
      _filled=$(( _filled + 1 ))

      # 100ms sleep between spawner calls (D11)
      sleep 0.1
    done

    exit 0
  fi

  # ── Original single-claim path (flag absent = byte-identical) ─────────────
  SPAWNS=$(cat docs/leadv2/spawns-today.txt 2>/dev/null || echo 0)
  MAX="${LEADV2_MAX_SELF_SPAWNS_PER_DAY:-4}"
  if [[ $SPAWNS -lt $MAX ]]; then
    NEXT=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/leadv2-queue-claim.sh" --by "$LEADV2_TASK_ID" 2>/dev/null) && _claim_rc=0 || _claim_rc=$?
    if [[ "$_claim_rc" -eq 2 || -z "$NEXT" ]]; then
      # exit 2 = no work across all lanes — nothing to spawn
      true
    elif [[ "$_claim_rc" -ne 0 ]]; then
      # real error — skip self-spawn this cycle
      true
    else
      # NEXT = "lane:id" — pass the id portion to spawner
      _next_id="${NEXT#*:}"
      bash "${CLAUDE_PLUGIN_ROOT}/scripts/leadv2-session-spawner.sh" "$_next_id"         && echo $(($SPAWNS+1)) > docs/leadv2/spawns-today.txt
    fi
  fi
fi
