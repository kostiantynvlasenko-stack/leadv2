#!/usr/bin/env bash
# FIX-LANE-LIVENESS-AUTHORITATIVE-01: provider status outranks sidecars/ps.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/leadv2-temp.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
HELPER="${PLUGIN_DIR}/scripts/leadv2-lane-liveness.sh"
SUPERVISE="${PLUGIN_DIR}/scripts/leadv2-supervise.sh"
STATE_PATH="${PLUGIN_DIR}/scripts/leadv2-state-path.sh"
tmp="$(lv2_mktemp_dir lane-liveness)"; trap 'rm -rf "$tmp"' EXIT
repo="$tmp/repo"; state="$tmp/state"; mkdir -p "$repo/docs/leadv2" "$repo/docs/handoff" "$tmp/bin" "$state"
(cd "$repo" && git init -q)
active="$(LEADV2_PROJECT_ROOT="$repo" LEADV2_STATE_ROOT="$state" PROJECT_ROOT="$repo" bash "$STATE_PATH" active.yaml)"
mkdir -p "$(dirname "$active")"; printf 'sessions: []\n' > "$active"
cat > "$tmp/bin/codex-task.sh" <<'SH'
#!/usr/bin/env bash
if [[ "$*" == *"cancelled-job"* ]]; then
  printf '%s\n' '{"workspaceRoot":"x","job":{"id":"cancelled-job","status":"cancelled","phase":"cancelled","createdAt":"2026-07-28T00:00:00Z"}}'
else
  printf '%s\n' '{"workspaceRoot":"x","running":[{"id":"running-job","status":"running","phase":"verifying","createdAt":"2026-07-28T00:00:00Z"}],"recent":[]}'
fi
SH
chmod +x "$tmp/bin/codex-task.sh"
pass=0
check() { grep -q "$2" <<<"$1" && { printf '[TEST] PASS: %s\n' "$3"; pass=$((pass+1)); } || { printf '[TEST] FAIL: %s\n%s\n' "$3" "$1"; exit 1; }; }

# No codex-guard process is created: running must remain running.
running="$(CODEX_TASK_SH="$tmp/bin/codex-task.sh" bash "$HELPER" --project-root "$repo" --json)"
check "$running" '"verdict": "running"' 'running job is not classified dead without codex-guard'
cancelled="$(CODEX_TASK_SH="$tmp/bin/codex-task.sh" bash "$HELPER" --project-root "$repo" --job cancelled-job --json)"
check "$cancelled" '"verdict": "cancelled"' 'cancelled job is reported as cancelled, not dead'
supervised="$(LEADV2_PROJECT_ROOT="$repo" LEADV2_STATE_ROOT="$state" CODEX_TASK_SH="$tmp/bin/codex-task.sh" bash "$SUPERVISE" --json)"
check "$supervised" 'codex:running-job' 'supervise enumerates Codex app-server job'
check "$supervised" '"phase": "verifying"' 'supervise preserves authoritative Phase'
printf '[TEST] %d authoritative-liveness assertions passed\n' "$pass"
