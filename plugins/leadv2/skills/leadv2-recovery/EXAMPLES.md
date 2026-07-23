# leadv2-recovery — Examples (brief/prompt templates, learning-capture yaml)

Companion to [SKILL.md](./SKILL.md). Full verbatim templates referenced from the main flow.

## Step 2: recovery brief + architect spawn

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

## Step 7: learning capture

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

This feeds immune memory for future pattern avoidance.
