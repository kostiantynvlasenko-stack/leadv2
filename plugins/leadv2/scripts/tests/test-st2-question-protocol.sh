#!/usr/bin/env bash
# ST-2: every dispatch arm receives the blocking-question protocol, and the
# direct Codex wrapper supplies it when it is not launched through dispatch.
set -euo pipefail

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/leadv2-st2.XXXXXX")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DISPATCH="$SCRIPT_DIR/leadv2-dispatch-code.sh"
CODEX="$SCRIPT_DIR/codex-task.sh"
trap 'rm -rf "$ROOT"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }
mkdir -p "$ROOT/.claude/ref" "$ROOT/bin"
cat > "$ROOT/.claude/ref/leadv2-routing.yaml" <<'YAML'
  glm_policy:
    sonnet_exceptions:
      - id: safety_gate_publish_payments
    codex_fitting_mission_kinds: [codex-test]
    codex_default_tier: standard
YAML

cat > "$ROOT/bin/glm" <<'SH'
#!/usr/bin/env bash
case "$1" in bg) printf '%s' "$2" > "$CAPTURE"; echo glm-st2 ;; status) exit 0 ;; esac
SH
cat > "$ROOT/bin/sonnet" <<'SH'
#!/usr/bin/env bash
for ((i=1;i<=$#;i++)); do [[ "${!i}" == --mission-file ]] && { j=$((i+1)); cp "${!j}" "$CAPTURE"; }; done
echo "PID=$LIVE_PID SESSION_ID=st2"
SH
cat > "$ROOT/bin/codex" <<'SH'
#!/usr/bin/env bash
case "$1" in task) printf '%s' "$2" > "$CAPTURE"; echo 'task-st2-abc123' ;; status) exit 0 ;; esac
SH
chmod +x "$ROOT/bin/"*

run_arm() {
  local arm="$1" extra="$2" cap
  cap="$ROOT/$arm.mission"
  CAPTURE="$cap" LIVE_PID="$$" CLAUDE_PROJECT_ROOT="$ROOT" LEADV2_DISPATCH_CACHE_DIR="$ROOT/cache-$arm" \
    LEADV2_DISPATCH_GLM_BIN="$ROOT/bin/glm" LEADV2_DISPATCH_SUBSESSION_BIN="$ROOT/bin/sonnet" \
    LEADV2_DISPATCH_CODEX_BIN="$ROOT/bin/codex" LEADV2_JOURNAL_BIN=/bin/true \
    bash "$DISPATCH" "ST2 rendered $arm" $extra >/dev/null
  grep -q 'leadv2-ask.sh' "$cap" && grep -q 'clearly reversible option' "$cap" \
    && pass "$arm rendered mission carries reversible blocking-question protocol" \
    || fail "$arm mission missed protocol"
}
run_arm glm ''
run_arm sonnet '--protected'
run_arm codex '--kind codex-test'

# The direct Codex template is tested with a fake companion; the wrapper should
# append the protocol and use the task id supplied by its caller.
mkdir -p "$ROOT/.claude/plugins/cache/openai-codex/st2/scripts"
touch "$ROOT/.claude/plugins/cache/openai-codex/st2/scripts/codex-companion.mjs"
cat > "$ROOT/bin/node" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$CAPTURE"
SH
chmod +x "$ROOT/bin/node"
PATH="$ROOT/bin:$PATH" CAPTURE="$ROOT/direct-codex.mission" LEADV2_TASK_ID=ST2-DIRECT \
  HOME="$ROOT" bash "$CODEX" task 'direct task' --model gpt-5.5 >/dev/null 2>&1 || true
grep -q 'leadv2-ask.sh' "$ROOT/direct-codex.mission" && grep -q 'ST2-DIRECT' "$ROOT/direct-codex.mission" \
  && grep -q 'clearly reversible option' "$ROOT/direct-codex.mission" \
  && pass 'direct Codex template carries protocol' || fail 'direct Codex template missed protocol'
