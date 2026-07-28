#!/usr/bin/env bash
# leadv2-provider-canary.sh — real-provider Phase 0..8 canary for BOTH the
# Claude and Codex session runners, fully sandboxed. Exercises the actual
# leadv2-session-runner.sh / leadv2-codex-session-runner.sh code paths
# end-to-end with REAL, cheap-tier Claude Sonnet + Codex Luna-tier API calls —
# this is intentional (LEADV2-PLUGIN-AUDIT-2026-07-22 P0 "real provider
# canary" + Milestone 4 item 5). No mocks, no stubbed provider binaries.
#
# Design docs (persona-engine repo, authoritative order):
#   docs/handoff/4b3c1dbf205f/final-plan.md      — REQUIRED fixes (supersedes design)
#   docs/handoff/4b3c1dbf205f/canary-design.md   — data flow / script outline / env table
#   docs/handoff/4b3c1dbf205f/canary-critique.md — raw adversarial findings
#
# Grounded in direct reads of: leadv2-session-runner.sh,
# leadv2-codex-session-runner.sh, leadv2-deploy-merge.sh,
# leadv2-active-registry.sh, leadv2-verify/SKILL.md, leadv2-migration-apply.sh,
# leadv2-phase8-assert.sh, leadv2-state-path.sh, codex-task.sh,
# commands/leadv2.md.
#
# ── COST BOUNDING (final-plan fix 2, documented not silently unbounded) ─────
# The OUTER runner loop is hard-capped: LEADV2_RUNNER_MAX_ATTEMPTS=3 per leg,
# --max-turns 30 (Claude) / codex default (Codex). Phase 5 REVIEW inside each
# attempt ALSO fires `codex-task.sh adversarial-review` (primary) +
# Agent(critic) + Agent(security-auditor), independent of the outer loop
# (commands/leadv2.md:110) — up to 3 review rounds. There is NO env/flag in
# codex-task.sh that lets an OUTER caller force a --tier on an INNER call the
# LLM-under-test issues itself (verified: codex-task.sh has no
# CODEX_TASK_DEFAULT_TIER-style override). The task-brief below therefore
# instructs the session in plain text: "ALWAYS pass --tier volume to any
# codex-task.sh adversarial-review call" — a soft (prompt-level) cap, NOT a
# hard gate; it is honored on a best-effort basis by an obedient LLM, same as
# every other imperative in a /leadv2 prompt.
# Documented worst case if that instruction is ignored, per leg:
#   3 outer attempts x 3 Phase-5 rounds x (1 codex-task.sh default-tier review
#   + 1 Agent(critic, sonnet) + 1 Agent(security-auditor, sonnet)) = bounded,
#   non-trivial, but NOT unbounded. The canary task is deliberately classified
#   Trivial in the task-brief (single README line, no runtime/schema/auth
#   touch) so Phase 1 CLASSIFY skips Phase 1.5/2/3 (diverge/plan/gate1)
#   entirely and the security-auditor's auth/RLS/secrets/webhook trigger
#   (commands/leadv2.md:31) should never fire.
#
# ── PHASE 7 NEUTRALIZATION (final-plan fix 1) ───────────────────────────────
# leadv2-verify/SKILL.md:96-99 lists http-check/supabase-check as valid probe
# types and falls through to a generic/founder-escalation probe whenever
# .claude/leadv2-overrides/verify.sh is absent. This canary scaffolds a stub
# verify.sh (mirrors the deploy.sh stub: log + exit 0 + counter file) AND
# seeds context.yaml with an explicit `verification.probe.type: signal-file`
# so no live-network probe path can be chosen either way.
#
# ── PROCESS-GROUP REAPING (final-plan fix 3) ────────────────────────────────
# macOS has no `setsid`(1) (util-linux only) — verified absent on this host.
# Instead: capture this script's own process-group id at startup (a
# non-interactive `bash script.sh` invocation is already the leader of a new
# foreground process group under job control, so descendants — including any
# `run_in_background=true` Agent/codex-task.sh child the plugin's own
# convention mandates — inherit the same pgid unless they explicitly detach).
# `cleanup` sends SIGTERM then SIGKILL to `-$SCRIPT_PGID` before `rm -rf
# $SANDBOX`, so an early-exit (die/MAX_ATTEMPTS/noop-stall) cannot leave an
# orphaned real-API-calling process running against a deleted cwd.
#
# ── USAGE ASSERTION ANCHOR (final-plan fix 4) ───────────────────────────────
# Codex: anchored to `"type":"turn.completed"` events (matches
# leadv2-codex-session-runner.sh's own `turn.completed` grep at line ~323).
# Claude: anchored to the terminal `"type":"result"` event (stream-json
# terminal event carrying cumulative usage/total_cost_usd) — confirmed
# against a real captured log line the first time this canary ran; if the
# Claude CLI's stream-json schema ever renames this event, assert_usage_nonnull
# fails loudly (never silently degrades to a loose scan).
#
# ── CLAUDE_PROJECT_ROOT (final-plan fix 5) ──────────────────────────────────
# Exported alongside CLAUDE_PLUGIN_ROOT — distinct var, zero fallback, load-
# bearing in verify.sh (SKILL.md:144 `$CLAUDE_PROJECT_ROOT/.claude/leadv2-
# overrides/verify.sh`), leadv2-deploy-merge.sh:136, leadv2-migration-
# apply.sh:16,29, leadv2-phase8-close.sh:32, leadv2-render-close.sh:24,
# leadv2-journal.sh:14.
#
# ── IDEMPOTENT-RESUME LIMITATION (final-plan fix 6) ─────────────────────────
# assert_idempotent_resume additionally greps for the runner's own sentinel-
# precheck log line ("Phase-8 completion proof already present ... nothing to
# do") on the SECOND invocation. This proves the resume path was actually
# taken (not just inferred from an unchanged deploy-stub counter) — a second
# run that never re-entered Phase 6 at all is indistinguishable from a
# correctly-no-op'd Phase 6 without this log-line check.
#
# CORRECTED (4b3c1dbf205f bug 2): the sentinel-precheck line is printed by the
# runner's own `log()` (stderr of the runner PROCESS) BEFORE the runner has
# opened its `>>"$LOGF"` redirect for a `claude`/`codex` attempt — the fast
# no-op path returns before the attempt loop ever runs, so the line never
# lands in session-runner.log/codex-session-runner.log. The fix captures each
# leg invocation's own stdout+stderr into a dedicated per-task capture file
# (see run_claude_leg/run_codex_leg) and greps THAT for the precheck line
# instead of the stream-json log.
#
# ── RECEIPT-FIELDS TIMING (4b3c1dbf205f bug 1, root cause corrected) ────────
# The mission brief hypothesized a state-root/active.yaml path mismatch
# between how this canary seeds/reads active.yaml and how the real runner
# writes it. Verified FALSE by direct read of leadv2-phase8-close.sh:506-519 —
# both sides resolve the identical control-plane active.yaml (same
# LEADV2_PROJECT_ROOT + LEADV2_STATE_BASE). The REAL root cause: Phase 8
# close calls `leadv2_active_unregister "$TASK_ID"` as its very last step,
# which EMPTIES the task's row (including provider_receipts) out of
# active.yaml by design (C-1 R4 — active.yaml only tracks in-flight
# sessions). assert_receipt_fields ran AFTER the leg's `/leadv2` session had
# already completed Phase 8 close, so the row it looked for was already gone
# — "no session row" was true, not a lookup bug. Fix: a background poller
# (_watch_receipts) snapshots the session row to a sidecar JSON file the
# moment provider_receipts becomes non-empty, running for the duration of
# each leg invocation; assert_receipt_fields reads that durable snapshot
# instead of racing the live (and eventually deleted) active.yaml row.
#
# ── KNOWN HARMLESS WARNING (final-plan fix 7) ───────────────────────────────
# seed_active_registry calls leadv2_active_register from the raw canary bash
# process (no live claude/codex process in the PPID chain yet) — expect
# `[lv2_durable_pid] WARNING: no claude process found in PPID chain; using
# fallback pid=...` on stderr. This is expected/harmless in this context, not
# a bug.
#
# Usage: bash leadv2-provider-canary.sh [--keep]
#   --keep          same as LEADV2_CANARY_KEEP=1 — copy sandbox aside instead
#                    of deleting it on exit (post-mortem).
# Env:
#   LEADV2_CANARY_KEEP=1   keep sandbox on exit (copied to /tmp/leadv2-canary-kept-<ts>)

set -uo pipefail
# NOTE: deliberately NOT `set -e` at top level — main() drives explicit rc
# checks for each leg so one leg's failure doesn't short-circuit the other's
# assertions or skip cleanup. Individual helper functions still run under
# `set -e` internally where safe (see run_claude_leg/run_codex_leg bodies).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
CHECKOUT_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
readonly CHECKOUT_ROOT
PLUGIN_ROOT="${CHECKOUT_ROOT}/plugins/leadv2"
readonly PLUGIN_ROOT

log()       { printf -- '[leadv2-provider-canary] %s\n' "$*" >&2; }
log_error() { printf -- '[leadv2-provider-canary] ERROR: %s\n' "$*" >&2; }
die()       { log_error "$*"; exit 1; }

KEEP="${LEADV2_CANARY_KEEP:-0}"
[[ "${1:-}" == "--keep" ]] && KEEP=1

# ── process-group capture (fix 3) ───────────────────────────────────────────
SCRIPT_PGID="$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ')"
[[ -z "$SCRIPT_PGID" ]] && SCRIPT_PGID="$$"
readonly SCRIPT_PGID

SANDBOX=""
CLEANED=0

cleanup() {
  [[ "$CLEANED" -eq 1 ]] && return 0
  CLEANED=1
  # IMPORTANT: file cleanup (cp/rm) must happen BEFORE the process-group kill
  # below — sending SIGTERM/SIGKILL to our OWN pgid (which we are a member
  # of) can terminate this very cleanup function mid-flight, leaving the
  # sandbox undeleted. Reap the group LAST, once nothing else remains to do.
  if [[ -n "$SANDBOX" && -d "$SANDBOX" ]]; then
    if [[ "$KEEP" == "1" ]]; then
      local kept="/tmp/leadv2-canary-kept-$(date +%s)"
      cp -R "$SANDBOX" "$kept" 2>/dev/null && log "LEADV2_CANARY_KEEP=1 — sandbox copied to ${kept}"
    fi
    rm -rf "$SANDBOX"
    log "cleanup: removed sandbox ${SANDBOX}"
  fi
  log "cleanup: reaping process group ${SCRIPT_PGID} (best-effort, catches any lingering run_in_background=true child)"
  kill -TERM -- "-${SCRIPT_PGID}" 2>/dev/null || true
  sleep 1
  kill -KILL -- "-${SCRIPT_PGID}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

make_sandbox() {
  SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/leadv2-canary.XXXXXX")"
  log "sandbox: ${SANDBOX}"
}

init_sandbox_repo() {
  local repo="${SANDBOX}/repo" origin="${SANDBOX}/origin.git"
  git init -q "$repo"
  git -C "$repo" config user.email "canary@leadv2.local"
  git -C "$repo" config user.name "leadv2-canary"
  git -C "$repo" checkout -q -b main 2>/dev/null || git -C "$repo" branch -m main
  printf -- '# leadv2 provider canary sandbox\n' > "${repo}/README.md"
  mkdir -p "${repo}/docs"
  git -C "$repo" add -A
  git -C "$repo" commit -q -m "seed"

  git init -q --bare "$origin"
  git -C "$repo" remote add origin "$origin"
  git -C "$repo" push -q -u origin main
}

scaffold_plugin_wiring() {
  local repo="${SANDBOX}/repo"
  mkdir -p "${repo}/.claude/leadv2-overrides"

  # deploy.sh stub — Phase 6 required-or-BLOCK gate (leadv2-deploy-merge.sh:135-143)
  cat > "${repo}/.claude/leadv2-overrides/deploy.sh" <<'DEPLOY_EOF'
#!/usr/bin/env bash
set -euo pipefail
COUNTER_FILE="$(dirname "${BASH_SOURCE[0]}")/.deploy-invocations"
n=0
[[ -f "$COUNTER_FILE" ]] && n="$(cat "$COUNTER_FILE")"
n=$((n + 1))
printf -- '%s\n' "$n" > "$COUNTER_FILE"
echo "[canary-deploy-stub] invocation #${n} task=${LEAD_V2_TASK_ID:-?} commit=${LEAD_V2_COMMIT:-?}"
exit 0
DEPLOY_EOF
  chmod +x "${repo}/.claude/leadv2-overrides/deploy.sh"

  # verify.sh stub — Phase 7 neutralization (final-plan fix 1)
  cat > "${repo}/.claude/leadv2-overrides/verify.sh" <<'VERIFY_EOF'
#!/usr/bin/env bash
set -euo pipefail
COUNTER_FILE="$(dirname "${BASH_SOURCE[0]}")/.verify-invocations"
n=0
[[ -f "$COUNTER_FILE" ]] && n="$(cat "$COUNTER_FILE")"
n=$((n + 1))
printf -- '%s\n' "$n" > "$COUNTER_FILE"
echo "[canary-verify-stub] invocation #${n} task=${LEAD_V2_TASK_ID:-?}"
exit 0
VERIFY_EOF
  chmod +x "${repo}/.claude/leadv2-overrides/verify.sh"

  # .claude/scripts symlink — Codex leg has no slash-command resolution,
  # locates sibling scripts itself from -C "$PROJECT_ROOT" (design item 9).
  ln -sfn "${PLUGIN_ROOT}/scripts" "${repo}/.claude/scripts"

  # DEVIATION FROM canary-design.md's `--settings <marketplace-json>` plan
  # (see build-report.md "Deviations"): a live smoke test proved the CLI's
  # marketplace/plugin merge in headless `-p` mode does NOT expose /leadv2 —
  # `claude -p --settings <tmp>.json "/leadv2 <id>"` returned "Unknown
  # command: /leadv2" (rc=0, subtype=success) on all 3 resume attempts,
  # exactly the design's own flagged Risk #1. Fix (matches how persona-engine
  # itself already vendors the command — .claude/commands/leadv2.md is a
  # PLAIN FILE there, not plugin-loaded): symlink commands/skills/agents
  # directly from THIS checkout into the sandbox's `.claude/`, so /leadv2
  # resolves as a project-local custom command with zero dependency on
  # marketplace trust semantics, and Skill()/Agent() lookups still resolve to
  # THIS checkout's plugin content (not the possibly-stale
  # ~/.claude/plugins/local/leadv2 global copy — confirmed a DIFFERENT,
  # non-symlinked directory on this machine).
  ln -sfn "${PLUGIN_ROOT}/commands" "${repo}/.claude/commands"
  ln -sfn "${PLUGIN_ROOT}/skills" "${repo}/.claude/skills"
  mkdir -p "${repo}/.claude/agents"
  for f in architect.md critic.md security-auditor.md; do
    ln -sfn "${PLUGIN_ROOT}/agents/${f}" "${repo}/.claude/agents/${f}"
  done

  # DEVIATION (found via live run, see build-report.md "Deviations"):
  # leadv2-active-registry.sh's `_leadv2_state_path_sh()` hardcodes the
  # resolver path as `${LEADV2_PROJECT_ROOT}/scripts/leadv2-state-path.sh` —
  # a TOP-LEVEL `scripts/` dir (matching how persona-engine itself vendors
  # the plugin: `scripts/leadv2-*.sh` at repo root, not under `.claude/`),
  # NOT `.claude/scripts/`. Without this symlink, `_leadv2_yaml_file()`
  # silently falls back to a repo-relative `docs/leadv2/active.yaml` that
  # `assert_receipt_fields` (which reads via the control-plane
  # LEADV2_STATE_BASE resolution) never sees — a real path-mismatch bug
  # caught only by running this canary for real, not by code-reading.
  ln -sfn "${PLUGIN_ROOT}/scripts" "${repo}/scripts"

  git -C "$repo" add -A
  git -C "$repo" commit -q -m "scaffold canary overrides"
  git -C "$repo" push -q origin main
}

seed_active_registry() {
  local task_claude="$1" task_codex="$2"
  # shellcheck source=leadv2-active-registry.sh
  source "${PLUGIN_ROOT}/scripts/leadv2-active-registry.sh"
  leadv2_active_register "$task_claude" "Trivial" "${SANDBOX}/repo" "main" "true" >/dev/null
  leadv2_active_register "$task_codex" "Trivial" "${SANDBOX}/repo" "main" "true" >/dev/null
}

write_canary_taskbrief() {
  local task_id="$1"
  local dir="${SANDBOX}/repo/docs/handoff/${task_id}"
  mkdir -p "$dir"

  cat > "${dir}/task-brief.md" <<TASKBRIEF_EOF
# ${task_id} — provider canary (Trivial)

Create a file \`docs/canary-${task_id}.md\` containing exactly one line:
\`canary probe ${task_id}\`. Commit it. Then drive the task to Phase 8 Close.

This is a Trivial task (single doc file, zero runtime/schema/auth touch) —
classify it Trivial in Phase 1 so Phase 1.5/2/3 (diverge/plan/gate1) are
skipped per the routing table.

Cost constraint (canary, non-negotiable): if Phase 5 REVIEW invokes
\`codex-task.sh adversarial-review\`, ALWAYS append \`--tier volume\` to that
call to keep review cost minimal. This is a hard requirement for this task,
not a suggestion.

Recursion-guard note (Codex leg only, non-negotiable): you are ALREADY the
running leadv2 child session for this task. Do NOT reference, name, quote,
or discuss any leadv2 session launcher/dispatcher script by filename in your
output at any point (not even to say you will not call it) — simply proceed
with the phase work silently and never type those filenames.
TASKBRIEF_EOF

  cat > "${dir}/context.yaml" <<CONTEXT_EOF
task_id: ${task_id}
decisions:
  - "D1: canary task — Trivial class, single doc-file diff, no runtime/schema/auth touch"
off_limits: []
plan:
  steps:
    - reads: []
      writes: ["docs/canary-${task_id}.md"]
verification:
  live_signal: "canary doc file exists in sandbox repo"
  probe:
    type: signal-file
    args:
      path: "docs/canary-${task_id}.md"
  timeout: 60
CONTEXT_EOF
}

# _watch_receipts <task_id> <snapshot_file>
#
# Bug-1 fix (4b3c1dbf205f): active.yaml's session row (and its
# provider_receipts) is deleted by leadv2_active_unregister at the very end
# of Phase 8 close (leadv2-phase8-close.sh:506-519) — by the time a leg
# invocation returns, the row assert_receipt_fields wants to inspect is
# already gone by design. Poll the live active.yaml for the duration of the
# invocation and persist the row to a durable sidecar file the moment
# provider_receipts is non-empty, so the assertion can read evidence that
# outlives the unregister. Backgrounded by run_claude_leg/run_codex_leg and
# killed (caught by the existing process-group reap in cleanup() if missed)
# once the invocation returns.
_watch_receipts() {
  local task_id="$1" snapshot="$2"
  local yaml_file
  while :; do
    yaml_file="$(
      env LEADV2_STATE_BASE="${SANDBOX}/.state-base" PROJECT_ROOT="${SANDBOX}/repo" \
        "${PLUGIN_ROOT}/scripts/leadv2-state-path.sh" --no-link active.yaml 2>/dev/null
    )"
    if [[ -n "$yaml_file" && -f "$yaml_file" ]]; then
      python3 - "$yaml_file" "$task_id" "$snapshot" <<'PYEOF' 2>/dev/null || true
import json, sys
try:
    import yaml
except ImportError:
    sys.exit(0)
yaml_path, task_id, snap_path = sys.argv[1:]
try:
    data = yaml.safe_load(open(yaml_path, encoding="utf-8")) or {}
except Exception:
    sys.exit(0)
sessions = data.get("sessions") or []
row = next((s for s in sessions if s.get("task_id") == task_id), None)
if row and row.get("provider_receipts"):
    with open(snap_path, "w", encoding="utf-8") as fh:
        json.dump(row, fh)
PYEOF
    fi
    sleep 0.3
  done
}

run_claude_leg() {
  local task_id="$1"
  local snapshot="${SANDBOX}/repo/docs/handoff/${task_id}/.receipt-snapshot.json"
  # (bug 2) per-task capture of this invocation's own stdout+stderr — the
  # runner's fast-path "nothing to do" log line is emitted before its
  # >>"$LOGF" redirect exists, so it never lands in session-runner.log.
  local capture="${SANDBOX}/repo/docs/handoff/${task_id}/.runner-invocation.log"
  local cap_before=0
  [[ -f "$capture" ]] && cap_before="$(wc -c < "$capture")"
  log "running Claude leg: ${task_id}"
  _watch_receipts "$task_id" "$snapshot" &
  local watch_pid=$!
  env \
    LEADV2_TASK_ID="$task_id" \
    LEADV2_PROJECT_ROOT="${SANDBOX}/repo" \
    CLAUDE_PROJECT_ROOT="${SANDBOX}/repo" \
    CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
    LEADV2_STATE_BASE="${SANDBOX}/.state-base" \
    LEADV2_SESSION_PROVIDER=claude \
    LEADV2_LEAD_MODEL=sonnet \
    LEADV2_LEAD_EFFORT=medium \
    LEADV2_ASYNC_QUESTIONS=1 \
    LEADV2_RUNNER_MAX_ATTEMPTS=3 \
    LEADV2_CLAUDE_MAX_TURNS=30 \
    LEADV2_UNSAFE_AUTOPILOT=0 \
    bash "${PLUGIN_ROOT}/scripts/leadv2-session-runner.sh" >>"$capture" 2>&1
  local rc=$?
  tail -c +"$((cap_before + 1))" "$capture" >&2 2>/dev/null || true
  kill "$watch_pid" 2>/dev/null || true
  wait "$watch_pid" 2>/dev/null || true
  return $rc
}

run_codex_leg() {
  local task_id="$1"
  local snapshot="${SANDBOX}/repo/docs/handoff/${task_id}/.receipt-snapshot.json"
  local capture="${SANDBOX}/repo/docs/handoff/${task_id}/.runner-invocation.log"
  local cap_before=0
  [[ -f "$capture" ]] && cap_before="$(wc -c < "$capture")"
  log "running Codex leg: ${task_id}"
  _watch_receipts "$task_id" "$snapshot" &
  local watch_pid=$!
  env \
    LEADV2_TASK_ID="$task_id" \
    LEADV2_PROJECT_ROOT="${SANDBOX}/repo" \
    CLAUDE_PROJECT_ROOT="${SANDBOX}/repo" \
    CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
    LEADV2_STATE_BASE="${SANDBOX}/.state-base" \
    LEADV2_SESSION_PROVIDER=codex \
    LEADV2_LEAD_MODEL=gpt-5.6-luna \
    LEADV2_LEAD_EFFORT=low \
    LEADV2_ASYNC_QUESTIONS=1 \
    LEADV2_RUNNER_MAX_ATTEMPTS=3 \
    LEADV2_UNSAFE_AUTOPILOT=0 \
    LEADV2_CODEX_SKIP_LOGIN_CHECK=0 \
    bash "${PLUGIN_ROOT}/scripts/leadv2-session-runner.sh" >>"$capture" 2>&1
  local rc=$?
  tail -c +"$((cap_before + 1))" "$capture" >&2 2>/dev/null || true
  kill "$watch_pid" 2>/dev/null || true
  wait "$watch_pid" 2>/dev/null || true
  return $rc
}

# ── assertions ───────────────────────────────────────────────────────────────

assert_phase8() {
  local task_id="$1"
  local sentinel="${SANDBOX}/repo/docs/handoff/${task_id}/phase8-passed.flag"
  local receipt
  receipt="$(
    env LEADV2_STATE_BASE="${SANDBOX}/.state-base" PROJECT_ROOT="${SANDBOX}/repo" \
      "${PLUGIN_ROOT}/scripts/leadv2-state-path.sh" --no-link "completions/${task_id}.json" 2>/dev/null
  )"
  if [[ -f "$sentinel" ]]; then
    log "assert_phase8[${task_id}]: PASS (sentinel flag present)"
    return 0
  fi
  if [[ -n "$receipt" && -f "$receipt" ]]; then
    if python3 - "$receipt" "$task_id" <<'PYEOF'
import json, sys
path, task_id = sys.argv[1:]
with open(path, encoding="utf-8") as fh:
    d = json.load(fh)
ok = (
    d.get("schema_version") == 1
    and d.get("task_id") == task_id
    and d.get("status") == "phase8_passed"
    and d.get("assertions") == "7/7"
)
raise SystemExit(0 if ok else 1)
PYEOF
    then
      log "assert_phase8[${task_id}]: PASS (completion receipt valid)"
      return 0
    fi
  fi
  log_error "assert_phase8[${task_id}]: FAIL — no sentinel and no valid completion receipt"
  return 1
}

# assert_usage_nonnull <log_file> <provider>
# Anchored to the terminal event per provider (final-plan fix 4).
assert_usage_nonnull() {
  local logf="$1" provider="$2"
  [[ -f "$logf" ]] || { log_error "assert_usage_nonnull[${provider}]: log missing: ${logf}"; return 1; }
  python3 - "$logf" "$provider" <<'PYEOF'
import json, sys
path, provider = sys.argv[1:]
target_type = "turn.completed" if provider == "codex" else "result"

def has_nonnull_numeric_usage(obj):
    usage = obj.get("usage")
    if not isinstance(usage, dict):
        return False
    return any(isinstance(v, (int, float)) and v is not None for v in usage.values())

found = False
with open(path, encoding="utf-8", errors="replace") as fh:
    for line in fh:
        line = line.strip()
        if not line or not line.startswith("{"):
            continue
        try:
            evt = json.loads(line)
        except ValueError:
            continue
        if evt.get("type") != target_type:
            continue
        if has_nonnull_numeric_usage(evt):
            found = True
            break
        # Claude's terminal "result" event may carry cumulative cost at the
        # top level (total_cost_usd) instead of/alongside a usage sub-object.
        if provider != "codex" and isinstance(evt.get("total_cost_usd"), (int, float)):
            found = True
            break
raise SystemExit(0 if found else 1)
PYEOF
  local rc=$? target_type_display="result"
  [[ "$provider" == "codex" ]] && target_type_display="turn.completed"
  if [[ $rc -eq 0 ]]; then
    log "assert_usage_nonnull[${provider}]: PASS (terminal event '${target_type_display}' carries non-null usage)"
  else
    log_error "assert_usage_nonnull[${provider}]: FAIL — no terminal event with non-null numeric usage found in ${logf}"
  fi
  return $rc
}

assert_receipt_fields() {
  local task_id="$1"
  # (bug 1) do NOT re-read live active.yaml here — leadv2_active_unregister
  # (called by leadv2-phase8-close.sh as the last Phase-8 step) has already
  # deleted this task's session row by the time the leg invocation returns.
  # Read the durable snapshot _watch_receipts captured mid-run instead.
  local snapshot="${SANDBOX}/repo/docs/handoff/${task_id}/.receipt-snapshot.json"
  [[ -f "$snapshot" ]] || {
    log_error "assert_receipt_fields[${task_id}]: FAIL — no receipt snapshot captured during the run (active.yaml row is expected to be unregistered by Phase-8 close after completion)"
    return 1
  }
  python3 - "$snapshot" "$task_id" <<'PYEOF'
import json, sys
path, task_id = sys.argv[1:]
with open(path, encoding="utf-8") as fh:
    row = json.load(fh)
receipts = row.get("provider_receipts") or []
if not receipts:
    print(f"no provider_receipts in snapshot for {task_id}", file=sys.stderr)
    raise SystemExit(1)
required = {"provider", "task_id", "model", "effort", "run_id", "status", "exit_code", "attempt", "recorded_at"}
last = receipts[-1]
missing = required - set(last.keys())
if missing:
    print(f"receipt missing fields: {missing}", file=sys.stderr)
    raise SystemExit(1)
raise SystemExit(0)
PYEOF
  local rc=$?
  [[ $rc -eq 0 ]] && log "assert_receipt_fields[${task_id}]: PASS" || log_error "assert_receipt_fields[${task_id}]: FAIL"
  return $rc
}

# assert_idempotent_resume <task_id> <log_file> <sentinel_precheck_regex>
#
# (bug 2) <log_file> is kept for call-site compatibility but no longer used
# for the precheck grep — see run_claude_leg/run_codex_leg's <task_id>
# .runner-invocation.log capture, which is where the fast-path "nothing to
# do" line actually lands (it is the runner PROCESS's own stderr, printed
# before that process ever opens its >>"$LOGF" redirect for a claude/codex
# attempt, so the stream-json LOGF never sees it).
assert_idempotent_resume() {
  local task_id="$1" _unused_logf="$2" precheck_pattern="$3"
  local deploy_counter="${SANDBOX}/repo/.claude/leadv2-overrides/.deploy-invocations"
  local capture="${SANDBOX}/repo/docs/handoff/${task_id}/.runner-invocation.log"
  local before=0 after=0
  [[ -f "$deploy_counter" ]] && before="$(cat "$deploy_counter")"

  local cap_size_before cap_size_after rc
  cap_size_before="$(wc -c < "$capture" 2>/dev/null || echo 0)"
  # Re-invoke the SAME runner call — sentinel already present, must fast-path exit 0.
  if [[ "$task_id" == *-claude ]]; then
    run_claude_leg "$task_id"
    rc=$?
  else
    run_codex_leg "$task_id"
    rc=$?
  fi
  cap_size_after="$(wc -c < "$capture" 2>/dev/null || echo 0)"
  [[ -f "$deploy_counter" ]] && after="$(cat "$deploy_counter")"

  if [[ "$rc" -ne 0 ]]; then
    log_error "assert_idempotent_resume[${task_id}]: FAIL — second invocation exited rc=${rc}, expected 0"
    return 1
  fi
  if [[ "$before" != "$after" ]]; then
    log_error "assert_idempotent_resume[${task_id}]: FAIL — deploy-stub counter changed (${before} -> ${after}); Phase 6 re-entered"
    return 1
  fi
  # (final-plan fix 6) also require the sentinel-precheck log line proving the
  # resume path was actually taken, not just inferred from an unchanged
  # counter. Grep the runner's own captured stdout+stderr for this
  # invocation, not the stream-json log (see comment above).
  local new_bytes
  new_bytes="$(tail -c +"$((cap_size_before + 1))" "$capture" 2>/dev/null || true)"
  if ! grep -Eq "$precheck_pattern" <<< "$new_bytes"; then
    log_error "assert_idempotent_resume[${task_id}]: FAIL — sentinel-precheck log line not found on second invocation (pattern: ${precheck_pattern})"
    return 1
  fi
  log "assert_idempotent_resume[${task_id}]: PASS (rc=0, deploy-stub counter unchanged ${before}=${after}, precheck log line present)"
  return 0
}

# ── main ─────────────────────────────────────────────────────────────────────

main() {
  make_sandbox
  init_sandbox_repo
  scaffold_plugin_wiring

  local ts task_claude task_codex
  ts="$(date +%s)-$$"
  task_claude="canary-${ts}-claude"
  task_codex="canary-${ts}-codex"

  export LEADV2_STATE_BASE="${SANDBOX}/.state-base"
  export LEADV2_PROJECT_ROOT="${SANDBOX}/repo"
  export CLAUDE_PROJECT_ROOT="${SANDBOX}/repo"
  export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"

  seed_active_registry "$task_claude" "$task_codex"
  write_canary_taskbrief "$task_claude"
  write_canary_taskbrief "$task_codex"

  local claude_rc=0 codex_rc=0
  run_claude_leg "$task_claude" || claude_rc=$?
  run_codex_leg "$task_codex" || codex_rc=$?

  log "leg 1 (first invocation) exit codes: claude=${claude_rc} codex=${codex_rc}"

  local overall=0
  local claude_log="${SANDBOX}/repo/docs/handoff/${task_claude}/session-runner.log"
  local codex_log="${SANDBOX}/repo/docs/handoff/${task_codex}/codex-session-runner.log"

  assert_phase8 "$task_claude" || overall=1
  assert_phase8 "$task_codex" || overall=1

  assert_usage_nonnull "$claude_log" claude || overall=1
  assert_usage_nonnull "$codex_log" codex || overall=1

  assert_receipt_fields "$task_claude" || overall=1
  assert_receipt_fields "$task_codex" || overall=1

  assert_idempotent_resume "$task_claude" "$claude_log" \
    'Phase-8 completion proof already present.*nothing to do' || overall=1
  assert_idempotent_resume "$task_codex" "$codex_log" \
    'Phase-8 completion proof already present.*nothing to do' || overall=1

  if [[ "$overall" -eq 0 ]]; then
    log "ALL ASSERTIONS PASSED (both legs)"
  else
    log_error "one or more assertions FAILED — see above"
  fi
  return "$overall"
}

main "$@"
exit $?
