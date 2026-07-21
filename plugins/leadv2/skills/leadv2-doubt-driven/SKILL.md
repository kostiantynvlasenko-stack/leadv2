---
name: leadv2-doubt-driven
description: "[internal] Fresh-context adversarial review for risky Phase-4 branching, irreversible changes, invariants, or module contracts."
---

# leadv2-doubt-driven

Doubt-Driven Development — adversarial review *during* build, not after.

## When to trigger

Apply to a specific decision (not the whole build) when it involves:
- Irreversible operations (deploy, migration, DB write, external send)
- Unverifiable invariants (thread safety, idempotency, partial-chain correctness)
- Module boundary contracts (producer/consumer signature match between parallel groups)
- Branching logic where the wrong branch is non-obvious

Skip for: renaming, formatting, obvious one-liners, pure tooling changes.

## The loop

### 1. CLAIM
Name the decision and why it matters. One sentence.
> "Step 1 of `threads_post_text` uses retryable HTTP — a retry after network drop could create a duplicate media container."

### 2. EXTRACT
Isolate the artifact + contract. Strip all reasoning. The critic receives ONLY:
- The artifact: exact code block or config section under review
- The contract: what it must guarantee (invariant, return type, side-effect policy)

Do NOT pass your reasoning or the CLAIM to the critic.

### 3. DOUBT
Spawn `Agent(subagent_type=critic, model=sonnet, run_in_background=true)` with:
```
You are a fresh-context adversarial reviewer. Find issues with this artifact.

Contract: <contract text>

Artifact:
<artifact text>

Adversarial prompt: find correctness issues, invariant violations, contract mismatches.
Output: list of findings. One sentence each. Mark severity: critical / high / medium / noise.
```

### 4. RECONCILE
Classify each finding:
- **contract_misread** → re-read the artifact yourself; if critic was wrong, note and move on
- **actionable** → fix before proceeding
- **trade-off** → document in context.yaml decisions[], proceed with caveat
- **noise** → discard

### 5. STOP conditions
Stop the loop when:
- All findings classified and actionable ones fixed
- 3 cycles with zero actionable findings (doubt theater — escalate instead of looping)
- Founder explicit approval after 2 unresolved cycles

## Cross-model rule

After single-model critic, if the decision is Heavy class or the artifact involves an irreversible external call: surface to founder — "want a second opinion from Codex?" Skipping is acceptable; silent skipping is not.

## Output

Append to `docs/handoff/<task_id>/doubt-log.md`:
```yaml
decision: <one-line claim>
artifact_hash: <sha256 of artifact text>
cycles: N
findings:
  - text: <finding>
    classification: actionable | trade-off | noise | contract_misread
    resolved: true | false
outcome: fixed | caveat_logged | escalated
```

## Integration with Phase 4

Lead calls this skill before spawning the next parallel group when any group deliverable contains:
- A non-idempotent external call
- A DB migration step
- A contract boundary between parallel groups

Do NOT run for every function — only for decisions that would cause Phase 7 verify failure or require a rollback if wrong.
