#!/usr/bin/env bash
# ST-8: a question timeout either proceeds visibly on its reversible default
# or parks human-needed and returns capacity to the backlog pump.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ASK_SH="${SCRIPT_DIR}/../leadv2-ask.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

new_fixture() {
  local root="$1"
  mkdir -p "$root/docs/leadv2" "$root/docs/handoff"
  cat >"$root/docs/tasks.yaml" <<'YAML'
tasks:
  - id: ST8-SIM
    title: Simulated timeout
    lane: action
    status: in_progress
    claim: {by: lane-st8, lease_expires: null}
YAML
}

ROOT_DEFAULT="$TMP_DIR/default"; STATE_DEFAULT="$TMP_DIR/state-default"; new_fixture "$ROOT_DEFAULT"
out="$(LEADV2_STATE_ROOT="$STATE_DEFAULT" PROJECT_ROOT="$ROOT_DEFAULT" LEADV2_ASK_POLL_INTERVAL=0.05 \
  bash "$ASK_SH" ST8-SIM 'Use reversible route?' --option 'safe|Leave unchanged' --option 'risky|Publish now' \
  --default-option safe --timeout 1 2>"$TMP_DIR/default.err")"
qfile="$(find "$STATE_DEFAULT/questions" -name 'q-*.yaml' -print -quit)"
grep -q '^default_option: safe$' "$qfile"
grep -q '^status: timed_out$' "$qfile"
grep -q 'default_option=safe' "$STATE_DEFAULT/open-threads.md"
grep -q 'default_option=safe' "$ROOT_DEFAULT/docs/leadv2/tasks/ST8-SIM/journal.md"
[[ "$out" == safe ]]

ROOT_PARK="$TMP_DIR/park"; STATE_PARK="$TMP_DIR/state-park"; new_fixture "$ROOT_PARK"
set +e
LEADV2_STATE_ROOT="$STATE_PARK" PROJECT_ROOT="$ROOT_PARK" LEADV2_ASK_POLL_INTERVAL=0.05 \
  bash "$ASK_SH" ST8-SIM 'No reversible route?' --option 'publish|Publish now' --timeout 1 \
  >"$TMP_DIR/park.out" 2>"$TMP_DIR/park.err"
rc=$?
set -e
qfile="$(find "$STATE_PARK/questions" -name 'q-*.yaml' -print -quit)"
grep -q '^status: timed_out_human_needed$' "$qfile"
grep -A7 -F 'id: ST8-SIM' "$ROOT_PARK/docs/tasks.yaml" | grep -q 'lane: human-needed'
grep -A7 -F 'id: ST8-SIM' "$ROOT_PARK/docs/tasks.yaml" | grep -q 'status: pending'
grep -A9 -F 'id: ST8-SIM' "$ROOT_PARK/docs/tasks.yaml" | grep -q 'by: null'
grep -q 'no default_option' "$STATE_PARK/open-threads.md"
[[ "$rc" -eq 2 ]]

printf 'PASS: timeout default proceeds visibly; no-default parks human-needed and frees the slot\n'
