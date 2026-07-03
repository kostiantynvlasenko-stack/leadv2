---
name: leadv2-iterative-recovery
description: "Structured layer-peeling recovery when each fix opens the next blocker. Hard cap 5 iterations, per-blocker commits, mandatory verify between each. Triggers: verify-probe returns BLOCKED after fix; symptom changes post-deploy; recovery note says \"layer N/N\"; >2 sequential hotfixes on same symptom."
allowed-tools:
  - Read
  - Write
  - Edit
  - Bash
---

# leadv2-iterative-recovery — Layer-Peeling Recovery

## When to invoke
- Verify-probe returns BLOCKED after a fix deployed
- Symptom changes (new blocker visible after first fix clears)
- Recovery note for this task says "layer N/N" pattern
- ≥3 sequential hotfixes already applied to the same symptom

## Hard caps
- **Max 5 iterations** per task. Iteration 6 → mandatory `Skill(leadv2-judge) mode=recovery` escalation with `reason: iteration_cap_reached`. Lead does NOT decide to continue itself.
- Each blocker gets its own commit. Never batch fixes targeting different layers in one commit.
- Iteration N+1 cannot start until verify-probe for iteration N returns GREEN or the blocker is conclusively named.

## Per-iteration structure

```
Iteration N:
  1. Name the blocker precisely (one sentence, root cause not symptom)
  1b. Codex second-hypothesis check (see below) — reconcile before scoping the fix
  2. Scope the fix to ONLY this blocker — touch nothing else
  3. Syntax-check: bash -n (sh) / python3 -m py_compile (py)
  4. Deploy both VPS via deploy-latest.sh
  5. leadv2-verify probe → wait for GREEN / RED / BLOCKED
  6. GREEN → proceed to Phase 8 Close
  7. RED/BLOCKED → name the NEW blocker → Iteration N+1
  8. Pulse: "iter-N: <blocker-name> → <GREEN|next-blocker>"
```

### 1b. Codex second-hypothesis check (added 2026-06-30, SONNET5-ADAPT-01)

The exact failure mode this targets: a whole session burned on 2 wrong root-cause theories before the real cause (a swallowed NOT-NULL error, sitting in the log the whole time) was found — see persona-engine's CLAUDE.md "Diagnosis protocol" section. A second, independent reader catches this cheaply.

If `bash ~/.claude/scripts/codex-task.sh status >/dev/null 2>&1` succeeds, fire Codex as an independent hypothesis generator in background, in parallel with the lead's own log read for step 1:

```bash
bash .claude/scripts/lv2 leadv2-codex-planner.sh \
  --task-id "<task-id>" --mode diagnose --effort medium \
  --log-path "<failure-log-path>" --diff-paths "<last-diff>" \
  --out "docs/handoff/<task-id>/codex-iter-${N}-hypothesis.md" &
```

Monitor for completion, then reconcile: if Codex's hypothesis matches the lead's, proceed with high confidence. If they diverge, do NOT pick one blind — re-check the actual error log/runtime evidence (per the Diagnosis protocol: read the error first, never ship on a code-read hypothesis alone) before naming the blocker in step 1. Skip silently if `codex-task.sh status` fails (no ChatGPT login) — lead's own read is sufficient, this is advisory only and never blocks the iteration.

## Traceability — mandatory log

After each iteration, lead writes to `docs/handoff/<task-id>/iterative-blockers.yaml`:

```yaml
- iteration: 1
  blocker: "claim_expires_at NULL causes immediate claim expiry"
  root_cause: "cadence_type was string not int, broke epoch calc"
  fix_commit: abc1234
  verify_result: BLOCKED
  next_blocker: "allcaps regex missing -i flag"
- iteration: 2
  blocker: "allcaps regex -i flag missing"
  fix_commit: def5678
  verify_result: GREEN
```

Lead writes this file — not subagent. It becomes the canonical chain.

**No-progress stall check (mandatory after each entry write):**

After writing each entry to `iterative-blockers.yaml`, call the helper with the `root_cause` slug:

```bash
bash scripts/leadv2-noprogress-check.sh \
  docs/handoff/<task-id>/recovery-sig.jsonl \
  "<root_cause_slug>"
```

- Exit 0 (`PROGRESS`) → continue to next iteration normally.
- Exit 1 (`STALLED`) → stop layer-peel immediately; escalate to founder via `ask-lead.sh <task-id> "iterative-recovery stalled: same root_cause <slug> repeated <N> times with no progress. Recommend: escalate to Skill(leadv2-judge) mode=recovery or abort."`. Do NOT attempt another fix iteration.

> **Signature independence:** the `root_cause` slug passed here is distinct from the `dimension:severity` signature used by the review workflow's stall-check. Always use separate JSONL paths per tracker: `recovery-sig.jsonl` for this recovery loop, and a different file for the review workflow — mixing them produces false STALLED/PROGRESS signals.

## Probe discipline — batch signals
- ONE SQL query per iteration covering all key metrics — not 5 sequential probes.
- Probe template:
  ```sql
  SELECT signal, COUNT(*) as hits, MAX(created_at) as last_seen
  FROM pe_log
  WHERE created_at > NOW() - INTERVAL '30 minutes'
    AND signal IN ('publish_success','cadence_floor_check','bypass_chosen',
                   'claim_next_success','block_action_enter')
  GROUP BY signal;
  ```

## Token discipline
- Do NOT re-read audit/investigation files between iterations — already on disk.
- Do NOT re-spawn forensics agent per iteration — use targeted grep on pe_log via SSH.
- Investigation prompt cap: 200 words, "max 3 findings, Critical only".

## Escape hatch
After 5 iterations OR 3h wall-clock (whichever comes first), even if blockers remain:
1. Write `iterative-blockers.yaml` with the full chain found
2. Call `Skill(leadv2-judge)` with `mode=recovery` and the chain as context
3. Judge decides: continue / architect-alt / abort. Lead does not self-decide.
