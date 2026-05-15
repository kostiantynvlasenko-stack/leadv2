---
name: leadv2-recovery
description: "[internal] Phase 7 circuit-breaker: rollback or architect alt-approach, max 2 attempts, then escalates to…"
allowed-tools:
  - Read
  - Write
  - Edit
  - Bash
---

# Lead v2 Recovery — Circuit Breaker

## When: Phase 7 verify failed. When NOT: during Plan/Build/Review (use their own escalation).

## Protocol

### 0. Causal lookup — identify root cause before proposing fix

**Run before spawning architect.** This amplifies durable-fix bias: knowing the original bug source
allows architect to fix the root, not the symptom.

```bash
# Run causal analysis (non-blocking — fall through on failure)
CAUSED_BY=$(
  bash .claude/scripts/leadv2-causal-analyze.sh \
    --regression-task <task-id> 2>/tmp/causal-warn.log
) || {
  CAUSED_BY="caused_by:\n  task_id: null\n  cause_unknown: true\n  lesson: causal lookup failed"
  cat /tmp/causal-warn.log >&2
}
```

Inject the `caused_by:` block into the recovery brief (`/tmp/recovery-<task-id>-<N>.md`) so
architect sees it as context. Example addition to the brief:

```
Causal analysis:
  caused_by.task_id: NIK-42 (causality_score: 0.82)
  lesson: "NIK-42 modified publish_feed; null-ref was introduced there"
  → Root cause is in NIK-42 changes, not in the immediate failing code path
```

If `cause_unknown: true` — still include in brief as "causal lookup inconclusive" so architect
knows this was attempted.

**Rules:**
- Causal lookup must NOT block recovery — if `leadv2-causal-analyze.sh` times out or errors, continue without it.
- Never delay spawning architect by more than 60s waiting for causal lookup.
- Log the `caused_by` result to `docs/handoff/<task-id>/rollback.md` alongside other recovery actions.

### 0b. Validate probe result contract (PO-058)

Before classifying failure, validate the probe result file against the contract
(`docs/specs/leadv2-verify-contract.md`):

```bash
source .claude/scripts/leadv2-helpers.sh
PROBE_RESULT="docs/handoff/${TASK_ID}/verify-probe-result.yaml"
if [[ -f "$PROBE_RESULT" ]]; then
  _validate_probe_result "$PROBE_RESULT" || {
    printf '[recovery] WARN: probe result file invalid — treating outcome as probe_timeout\n' >&2
  }
  outcome=$(python3 -c "
import yaml, sys
d = yaml.safe_load(open(sys.argv[1])) or {}
print(d.get('outcome', 'probe_timeout'))
" "$PROBE_RESULT" 2>/dev/null || echo "probe_timeout")
else
  # Fallback: derive outcome from verify-probe exit code passed in context
  outcome="${PROBE_OUTCOME:-probe_timeout}"
fi
```

Use `outcome` (not the raw exit code) for all downstream classification logic.

### 1. Classify failure

| `outcome` field | Class | Default response |
|---|---|---|
| `probe_timeout` | expected behavior didn't happen | hotfix attempt (less risky than rollback) |
| `probe_negative` | new code broke something | immediate rollback, then investigate |
| `probe_timeout` + systemd active repeatedly | feature flag stuck? configuration mismatch? | investigate first |

### 1b. Negative-memory check before retry

Before writing the recovery brief or spawning architect:

1. Extract the proposed retry approach from the failure classification above — what action would be retried.
2. Run `leadv2-negative-memory` skill with `current_phase: recovery`.
3. Write/update `docs/handoff/<task-id>/negative-memory-matches.yaml`.
4. For any match with `disposition: blocked` → **prepend to recovery brief**:
   ```
   NEGATIVE MEMORY BLOCK: approach "<X>" previously caused "<failure_mode>" (NM-YY).
   Unblock criteria not met. Architect MUST propose alternative — do not retry same approach.
   ```
5. For any match with `disposition: unblocked` → note in brief that the approach is allowed despite prior failure.

If `docs/leadv2-negative-memory.yaml` missing → skip, proceed normally.

### 1c. Compress previous-phase outputs before reading

Before reading any prior-phase handoff files (architect.md, developer.md, diff.md), compress them if large to reduce recovery-brief token cost:

```bash
source .claude/scripts/leadv2-helpers.sh
for f in \
  "docs/handoff/${TASK_ID}/architect.md" \
  "docs/handoff/${TASK_ID}/developer.md" \
  "docs/handoff/${TASK_ID}/diff.md"; do
  [[ -f "$f" ]] && leadv2_compress_handoff "$f"
done
# Read via helper — compressed twin is preferred when it exists
architect_out=$(leadv2_read_handoff "docs/handoff/${TASK_ID}/architect.md")
```

This prevents the full incident log (potentially hundreds of KB) from being ingested raw into the recovery architect brief.

### 2. Recovery attempt N (N starts at 1, max 2) — durable-first bias

**Before spawning architect**, classify the proposed recovery option using `fix_quality`:
- A quick patch that swallows an exception, hardcodes a value, or repeats the same failing approach = `fix_quality: band-aid`. Requires Tier B founder override to apply — do NOT auto-apply.
- Rollback to last good state + open RECOVERY- tracker task = `fix_quality: reasonable`. Apply as second-resort only.
- Redesign via architect that addresses the root cause = `fix_quality: durable`. This is the default first attempt.

**Attempt 1:** If error_trace shows identifiable root cause → propose durable fix via architect(opus) alt-approach. Tag as `fix_quality: durable`.
**Attempt 2 (only if attempt 1 fails):** Rollback to last good state (`fix_quality: reasonable`) + open `RECOVERY-<task-id>` task in docs/tasks.yaml via lib:
```bash
source .claude/scripts/leadv2-tasks-lib.sh
leadv2_tasks_add "RECOVERY-${TASK_ID}" recovery critical \
  --title "investigate recovery failure: ${TASK_ID}" \
  --origin recovery
```
**Attempt 3:** Tier C escalate (circuit break, Step 6).

Quick hotfix (catch-and-swallow exception, magic-number patch) is always `fix_quality: band-aid`. Automatically flagged; requires explicit founder override via `leadv2-decide.sh` to apply. Do NOT include as `recommended` in decision yaml.

Spawn architect(opus) via Agent tool with full state (NOT claude-subsession — we need skills active):

```
# Write recovery brief first:
Write /tmp/recovery-<task-id>-<N>.md:
  Task: <id>
  Mission: <original>
  Deployed: commit <hash> at <ts>
  Probe failure: <type> (<timeout|negative> — <detail>)
  Context.yaml decisions: <cite>
  Context.yaml off_limits: <cite>
  Diff summary (from docs/handoff/<id>/diff.md): <condensed>
  Previous recovery attempts: <none | list of N-1>

# Then spawn architect via Agent tool:
Agent(
  subagent_type: architect,
  model: opus,
  prompt: "
Recovery context: read /tmp/recovery-<task-id>-<N>.md in full.

Question: What do we do?
Options to consider (pick one, justify):
  A. ROLLBACK: git revert + redeploy. When: new code broke existing behavior.
  B. HOTFIX: code patch + redeploy. When: missing small piece, code mostly right.
  C. CONFIG FIX: change env var / feature flag. When: code right, config off.
  D. ABANDON: task scope wrong, rollback + re-plan. When: approach fundamentally flawed.
  E. EXTEND TIMEOUT: probe too short. When: log shows activity, just slow.

Write to docs/handoff/<id>/architect.md (OVERWRITE with recovery output), format:
  decision: <A|B|C|D|E>
  rationale: <one paragraph>
  plan: <concrete steps>
  new_probe: <if probe spec needs change, describe>
  risk_of_recovery: <what this recovery itself might break>
Max 400 words. Last line: DELIVERABLE_COMPLETE.

Skills active: plan-review, devils-advocate, systematic-debugging, leadv2-subagent-protocol.
Codebase graph project: ${LEADV2_CODEBASE_PROJECT}
"
)
```

Read `docs/handoff/<id>/architect.md` (overwritten with recovery output).

### 2b. Diff-only recovery-context (attempt 2+)

When recovery attempt 2 spawns (after attempt 1 fails), **do NOT replay full incident log**.

**Protocol:**
1. Call `.claude/scripts/leadv2-recovery-context.sh --task-id <id> --attempt 2`
2. The script emits the compact RECOVERY-CONTEXT format and archives the full log:
   ```
   RECOVERY-CONTEXT (compact)
   Original task: <id>
   Classification: Heavy
   Regression: <one-paragraph>
   Attempt 1 approach: <two-sentences>
   Attempt 1 failure: <one-sentence>
   Diff between original-broken and attempt-1: <git diff>
   Next approach requested: <one-sentence>
   ```
3. Inject compact context into attempt-2 architect brief in place of full incident log
4. Full incident log archived at `docs/handoff/<id>/recovery-full.md` — available for audit but NOT loaded into architect context

**Fallback:** if diff unavailable, script falls back to `[diff unavailable — check git log manually]`. Proceed with compact context regardless.

### 3. Execute architect decision

| Decision | fix_quality | Action |
|---|---|---|
| A ROLLBACK | reasonable | `.claude/scripts/leadv2-rollback.sh --task-id <id> --reason "<brief>" --target-commit <context.yaml.deploy_gate.commit_hash> --yes` → re-verify deployed state |
| B HOTFIX | band-aid (if patch) / durable (if root-cause fix) | `Agent(developer, sonnet)` with architect's plan → commit → push → re-deploy → re-verify. Tag based on scope of fix. |
| C CONFIG FIX | durable (if misconfiguration was root cause) | `Agent(devops-engineer, sonnet)` with config change plan → update env → systemctl reload → re-verify |
| D ABANDON | reasonable | Rollback + re-open Gate 1 with revised scope (new task-id) |
| E EXTEND | band-aid | Re-run `leadv2-verify` with longer timeout (architect specifies). Flag as band-aid — may hide real latency issues. |

Always set `recommended` in the decision yaml to the option with highest `fix_quality` (durable > reasonable > band-aid).

### 4. Re-verify

After execution of A/B/C/E:
```
Run leadv2-verify skill again with probe spec from context.yaml (possibly updated).
```

### 5. Decision tree after re-verify

| State after recovery N | Action |
|---|---|
| Verify OK | Phase 8 Close — note recovery in history.pattern_for_immune |
| Verify fail, N < 2 | Recovery attempt N+1 (go to step 2) |
| Verify fail, N == 2 | **Circuit break** — step 6 |

### 6. Circuit break

After 2 recoveries failed OR architect answers D ABANDON on attempt 2:

```
PushNotification: "leadv2 circuit break on <task-id>: 2 recoveries failed. rolled back. needs founder."

AskUserQuestion:
  question: "Task <id> failed verify 2x after recovery attempts. Production is at <rolled-back-state | last-hotfix>. What next?"
  options:
    - label: "Abandon task, open tracker item"
      description: "Roll back if not yet, file in docs/ops/RECOVERY_TRACKER.md with full history"
    - label: "Manual takeover"
      description: "Lead freezes state, founder debugs live. Provide log paths + commit range."
    - label: "Retry with new scope"
      description: "Kill this task-id, re-open Gate 1 with founder's revised mission"
```

Write LEAD_V2_STATE:
```
status: paused
phase: recovery
step: circuit_break
note: "2 recoveries failed, founder decision pending. last probe: <result>"
```

### 7. Learning capture

On ANY recovery outcome (success or circuit break) — append to LEAD_V2_STATE.history:

```yaml
history:
  - task: <id>
    closed_at: <ts>
    reflect:
      recovery_used: true
      recovery_attempts: <N>
      recovery_decision: <A|B|C|D|E>
      pattern_for_immune: "when <probe-type> fails with <signature>, <decision> worked"
```

This feeds `leadv2-skill-synthesize` for future auto-learning.

## Rules

- **Max 2 recovery attempts.** No third — circuit break (Tier C escalate).
- **Durable first, rollback second.** Attempt 1 = root-cause fix via architect. Attempt 2 = rollback + RECOVERY- task.
- **Rollback is default for NEG signal (attempt 2).** Durable architect fix is default for attempt 1.
- **Band-aid options require Tier B founder override.** Never auto-apply a `fix_quality: band-aid` option.
- **Each attempt is a full architect(opus) consultation.** Don't reuse previous decision without re-consultation.
- **Recovery log in `rollback.md`** (lives in handoff dir) — append every action.
- **If architect proposes D ABANDON on attempt 1** — accept; do not second-guess. Abandon = open new task-id.
- **`recommended` and `fix_quality` required** in every recovery decision yaml — missing → band-aid + Tier B.

## Anti-patterns

- Bypassing architect — "I know what to do" = the Sonnet-confidence bug that killed trust in Gate 1.
- Looping "just try again" without architect consultation.
- Partial recovery (patched one VPS, ignored the other) — fleet inconsistency is worse than full rollback.
- Skipping history capture — loses the pattern that could prevent this next time.
