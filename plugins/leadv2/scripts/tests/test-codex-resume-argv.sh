#!/usr/bin/env bash
# Regression coverage: `codex exec resume` accepts sandbox posture only via -c.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="$(cd "$SCRIPT_DIR/.." && pwd)/leadv2-codex-session-runner.sh"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/leadv2-codex-resume-argv.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT

PROJECT="$ROOT/project"
TASK_ID="CODEX-RESUME-ARGV"
TRACE="$ROOT/codex.args"
mkdir -p "$PROJECT/docs/handoff/$TASK_ID"

cat > "$ROOT/codex" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$STUB_TRACE"
if [[ "${1:-}" == login ]]; then exit 0; fi
if [[ "${2:-}" == resume ]]; then
  mkdir -p "$STUB_PROJECT/docs/handoff/$STUB_TASK_ID"
  : > "$STUB_PROJECT/docs/handoff/$STUB_TASK_ID/phase8-passed.flag"
else
  printf '%s\n' '{"type":"thread.started","thread_id":"resume-argv-thread"}'
fi
printf '%s\n' '{"type":"turn.completed"}'
STUB
chmod +x "$ROOT/codex"

STUB_TRACE="$TRACE" STUB_PROJECT="$PROJECT" STUB_TASK_ID="$TASK_ID" \
LEADV2_PROJECT_ROOT="$PROJECT" LEADV2_TASK_ID="$TASK_ID" \
LEADV2_CODEX_BIN="$ROOT/codex" LEADV2_CODEX_SKIP_LOGIN_CHECK=1 \
LEADV2_RUNNER_MAX_ATTEMPTS=2 LEADV2_RUNNER_RETRY_SLEEP_S=0 \
"$RUNNER" >/dev/null

fresh="$(grep '^exec ' "$TRACE" | head -n 1)"
resume="$(grep '^exec resume ' "$TRACE")"
if [[ "$fresh" == *'--sandbox workspace-write'* \
   && "$resume" != *'--sandbox'* \
   && "$resume" != *'--dangerously-bypass-approvals-and-sandbox'* \
   && "$resume" == *'sandbox_mode="workspace-write"'* ]]; then
  printf '[TEST] PASS: fresh --sandbox is retained; resume uses config without unsupported flags\n'
else
  printf '[TEST] FAIL: fresh=%s resume=%s\n' "$fresh" "$resume" >&2
  exit 1
fi
