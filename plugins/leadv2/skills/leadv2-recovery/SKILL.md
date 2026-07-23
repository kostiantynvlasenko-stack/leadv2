---
name: leadv2-recovery
description: "[internal] Phase-7 failure recovery: rollback or alternate architecture, two attempts, then founder escalation."
allowed-tools:
  - Read
  - Write
  - Edit
  - Bash
---

# Lead v2 Recovery — Circuit Breaker

## When: Phase 7 verify failed. When NOT: during Plan/Build/Review (use their own escalation).

**vs emergency-mode:** a verify-probe failure AFTER a normal deploy → this skill; a founder pre-grant ("no approvals"/emergency) BEFORE Phase 5 review even runs → `leadv2-emergency-mode` (archived: `skills/archive/leadv2-emergency-mode/SKILL.md`) instead — the two never fire on the same task.

## Protocol

### 0. Root cause context

Set a static default — architect determines root cause from diff and probe output in the recovery brief.

```
CAUSED_BY:
  task_id: null
  cause_unknown: true
```

Log to `docs/handoff/<task-id>/rollback.md`:
```
caused_by: unknown (architect to determine from diff)
```

### 0b. Validate probe result contract (PO-058)

Before classifying failure, validate the probe result file against the contract (`docs/specs/leadv2-verify-contract.md`) and derive `outcome`. Full validation script (source helpers, run `_validate_probe_result`, parse `PROBE_RESULT="docs/handoff/${TASK_ID}/verify-probe-result.yaml"`, fallback to `${PROBE_OUTCOME:-probe_timeout}`): see [REFERENCE.md](./REFERENCE.md#0b-validate-probe-result-contract).

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

Before reading any prior-phase handoff files (architect.md, developer.md, diff.md), compress them if large to reduce recovery-brief token cost. Full compression script (loops `architect.md`/`developer.md`/`diff.md` through `leadv2_compress_handoff`, reads via `leadv2_read_handoff`): see [REFERENCE.md](./REFERENCE.md#1c-compress-previous-phase-outputs).

This prevents the full incident log (potentially hundreds of KB) from being ingested raw into the recovery architect brief.

### 2. Recovery attempt N (N starts at 1, max 2) — durable-first bias

**Before spawning architect**, classify the proposed recovery option using `fix_quality`:
- A quick patch that swallows an exception, hardcodes a value, or repeats the same failing approach = `fix_quality: band-aid`. Requires Tier B founder override to apply — do NOT auto-apply.
- Rollback to last good state + open RECOVERY- tracker task = `fix_quality: reasonable`. Apply as second-resort only.
- Redesign via architect that addresses the root cause = `fix_quality: durable`. This is the default first attempt.

**Attempt 1:** If error_trace shows identifiable root cause → propose durable fix via architect(opus) alt-approach. Tag as `fix_quality: durable`.
**Attempt 2 (only if attempt 1 fails):** Rollback to last good state (`fix_quality: reasonable`) + open `RECOVERY-<task-id>` task in docs/tasks.yaml via lib:
```bash
source "$(bash .claude/scripts/lv2 --path leadv2-tasks-lib.sh)"
leadv2_tasks_add "RECOVERY-${TASK_ID}" recovery critical \
  --title "investigate recovery failure: ${TASK_ID}" \
  --origin recovery
```
**Attempt 3:** Tier C escalate (circuit break, Step 6).

Quick hotfix (catch-and-swallow exception, magic-number patch) is always `fix_quality: band-aid`. Automatically flagged; requires explicit founder override via `leadv2-decide.sh` to apply. Do NOT include as `recommended` in decision yaml.

Spawn architect(opus) via Agent tool with full state (NOT claude-subsession — we need skills active). Write the recovery brief to `/tmp/recovery-<task-id>-<N>.md` first, then spawn with the standard options (ROLLBACK/HOTFIX/CONFIG FIX/ABANDON/EXTEND TIMEOUT) and output contract (`decision`, `rationale`, `plan`, `new_probe`, `risk_of_recovery`, max 400 words, `DELIVERABLE_COMPLETE`). Full brief template + exact Agent() spawn prompt: see [EXAMPLES.md](./EXAMPLES.md#step-2-recovery-brief--architect-spawn).

Read `docs/handoff/<id>/architect.md` (overwritten with recovery output).

### 2b. Diff-only recovery-context (attempt 2+)

When recovery attempt 2 spawns (after attempt 1 fails), **do NOT replay full incident log** — call `bash .claude/scripts/lv2 leadv2-recovery-context.sh --task-id <id> --attempt 2` and inject its compact RECOVERY-CONTEXT output into the attempt-2 architect brief instead. Full incident log archived at `docs/handoff/<id>/recovery-full.md` (audit only, not loaded into context). Compact-format spec + fallback behavior: see [REFERENCE.md](./REFERENCE.md#2b-diff-only-recovery-context).

### 3. Execute architect decision

| Decision | fix_quality | Action |
|---|---|---|
| A ROLLBACK | reasonable | `bash .claude/scripts/lv2 leadv2-rollback.sh --task-id <id> --reason "<brief>" --target-commit <context.yaml.deploy_gate.commit_hash> --yes` → re-verify deployed state |
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

After 2 recoveries failed OR architect answers D ABANDON on attempt 2: send a `PushNotification` that recovery failed 2x and needs founder, then `AskUserQuestion` with options Abandon/Manual takeover/Retry with new scope, and write `LEAD_V2_STATE` with `status: paused`, `phase: recovery`, `step: circuit_break`. Exact notification text, question wording, and options: see [REFERENCE.md](./REFERENCE.md#6-circuit-break).

### 7. Learning capture

On ANY recovery outcome (success or circuit break) — append an entry to `LEAD_V2_STATE.history` recording `recovery_used`, `recovery_attempts`, `recovery_decision`, and a `pattern_for_immune` string. Exact yaml shape: see [EXAMPLES.md](./EXAMPLES.md#step-7-learning-capture).

This feeds immune memory for future pattern avoidance.

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
