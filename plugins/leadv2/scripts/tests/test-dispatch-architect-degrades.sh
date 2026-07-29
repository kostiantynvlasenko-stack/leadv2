#!/usr/bin/env bash
# Architect failure and timeout are advisory: a product dispatch must still launch.
set -uo pipefail

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
REPO="$ROOT/repo"; mkdir -p "$REPO/.claude/ref" "$REPO/docs/leadv2/.bus-offsets"
(cd "$REPO" && git init -q && git config user.email test@example.com && git config user.name test && : > seed && git add seed && git commit -qm seed)
printf 'router:\n  glm_policy:\n    sonnet_exceptions: [safety_gate_publish_payments]\n    opus_only_mission_kinds: []\n    codex_fitting_mission_kinds: []\n' > "$REPO/.claude/ref/leadv2-routing.yaml"
WORKER="$ROOT/worker"; ARCH="$ROOT/architect"
printf '#!/usr/bin/env bash\nnohup sleep 60 >/dev/null 2>&1 &\nprintf "PID=%%s LABEL=test SESSION_ID=test\\n" "$!"\n' > "$WORKER"
printf '#!/usr/bin/env bash\ncase "${PREPASS_MODE:-fail}" in timeout) sleep 60;; *) exit 9;; esac\n' > "$ARCH"
chmod +x "$WORKER" "$ARCH"
DISPATCH="$(cd "$(dirname "$0")/.." && pwd)/leadv2-dispatch-code.sh"
run() {
  CLAUDE_PROJECT_ROOT="$REPO" LEADV2_PROJECT_ROOT="$REPO" LEADV2_DISPATCH_CACHE_DIR="$ROOT/cache" \
  LEADV2_DISPATCH_SUBSESSION_BIN="$WORKER" LEADV2_DISPATCH_ARCHITECT_BIN="$ARCH" \
  LEADV2_DISPATCH_ARCHITECT_TIMEOUT_SEC=1 LEADV2_DISPATCH_E2E_GATE=0 LEADV2_DISPATCH_REVIEW_GATE=0 \
  LEADV2_ROUTER_V2=0 LEADV2_EXCLUDED_ARMS=__none__ LEADV2_LANE_SHAPE=off bash "$DISPATCH" "$1" --kind product --protected
}
out="$(run 'product failure must dispatch')"; rc=$?
[[ $rc -eq 0 && "$out" == *worker_spawned* ]] || { echo "FAIL failure did not dispatch: $out"; exit 1; }
journal="$(find "$REPO/docs/leadv2/tasks" -name journal.md -print -quit)"
grep -q 'status=degraded reason=failed_rc_9' "$journal" || { echo 'FAIL missing failure degradation journal'; exit 1; }
start=$(date +%s); out="$(PREPASS_MODE=timeout run 'product timeout must dispatch')"; rc=$?; elapsed=$(( $(date +%s) - start ))
[[ $rc -eq 0 && $elapsed -lt 8 && "$out" == *worker_spawned* ]] || { echo "FAIL timeout blocked dispatch rc=$rc elapsed=$elapsed out=$out"; exit 1; }
grep -R -q 'status=degraded reason=timeout' "$REPO/docs/leadv2/tasks" || { echo 'FAIL missing timeout degradation journal'; exit 1; }
echo 'PASS: architect failure/timeout degrade to raw worker dispatch promptly'
