#!/usr/bin/env bash
# leadv2-plan-integrity-check.sh — verify context.yaml hasn't changed since Gate 1
# Usage: leadv2-plan-integrity-check.sh <task_id>
# Exit: 0 = OK, 1 = SHA mismatch (plan mutated post-gate), 2 = no SHA recorded (skip)

set -euo pipefail

task_id="${1:?Usage: leadv2-plan-integrity-check.sh <task_id>}"

_state="docs/leadv2/tasks/${task_id}/STATE.md"
_ctx="docs/handoff/${task_id}/context.yaml"

if [[ ! -f "$_state" ]]; then
  echo "[integrity] STATE.md not found for ${task_id} — skipping check" >&2
  exit 2
fi

recorded_sha=$(grep "^gate1_context_sha:" "$_state" 2>/dev/null | awk '{print $2}' || true)
if [[ -z "$recorded_sha" ]]; then
  echo "[integrity] no gate1_context_sha in STATE.md — old task, skipping" >&2
  exit 2
fi

if [[ ! -f "$_ctx" ]]; then
  echo "[integrity] context.yaml not found for ${task_id} — skipping check" >&2
  exit 2
fi

current_sha=$(sha256sum "$_ctx" | awk '{print $1}')
if [[ "$current_sha" != "$recorded_sha" ]]; then
  echo "[integrity] WARN: context.yaml changed since Gate 1 approval" >&2
  echo "[integrity] recorded=${recorded_sha} current=${current_sha}" >&2
  exit 1
fi

echo "[integrity] context.yaml SHA matches Gate 1 snapshot — OK" >&2
exit 0
