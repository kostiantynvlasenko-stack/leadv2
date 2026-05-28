#!/usr/bin/env bash
# leadv2-self-spawn.sh — Phase 8 daemon self-spawn. Extracted verbatim from commands/leadv2.md
# Phase 8 bash block (src lines 341-360). Guard: only runs when LEADV2_DAEMON=1.
# Caller pattern: [[ "${LEADV2_DAEMON:-0}" == "1" ]] && bash "${CLAUDE_PLUGIN_ROOT}/scripts/leadv2-self-spawn.sh" || true
set -euo pipefail

: "${LEADV2_TASK_ID:?LEADV2_TASK_ID must be set}"
: "${CLAUDE_PLUGIN_ROOT:?CLAUDE_PLUGIN_ROOT must be set}"

if [[ "${LEADV2_DAEMON:-0}" == "1" ]]; then
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
