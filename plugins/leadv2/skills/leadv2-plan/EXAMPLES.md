# leadv2-plan — Examples

Worked recipes and the alternate Workflow-fan-out script. Consulted only when the pointing step
in `SKILL.md` fires.

## Precomputed Aggregate Recipe

Referenced from step **1c. Pre-compute heavy aggregates BEFORE the architect spawn**.

Recipe — action_log fingerprint per persona:

```bash
# Lead-side, before spawning architect.
for persona in nik respiro; do
  count=$(.claude/scripts/sb_get.py action_log \
    --filter "persona_id=eq.${persona}" \
    --filter "created_at=gte.now()-interval'7 days'" \
    --select "action_type" \
    --limit 500 | jq 'length')
  by_type=$(.claude/scripts/sb_get.py action_log \
    --filter "persona_id=eq.${persona}" \
    --filter "created_at=gte.now()-interval'7 days'" \
    --select "action_type" \
    --limit 500 | jq -r 'group_by(.action_type) | map({(.[0].action_type): length}) | add')
  echo "  ${persona}: total=${count} by_type=${by_type}"
done > /tmp/action-log-fp-<id>.txt
```

Embed the *output* of this script in the mission file under `## Pre-computed aggregates`, NOT the
raw rows — the architect should see one block of text, not 200 JSON rows.

## Workflow Enabled Fan Out

Referenced from step **2b. Stage 1 — planning spawns**, branch `LEADV2_WORKFLOW_ENABLED=1` (and
the `Workflow` tool available). This is the non-default path — when the flag is unset or the tool
is unavailable, use the manual path in SKILL.md instead.

```js
// Workflow script — planning fan-out
const results = await parallel([
  agent("architect", {
    model: "claude-sonnet-5",   // CODEX-56-ROUTING: always sonnet, never opus — cross-check on Codex's plan
    prompt: `<architect mission — cross-check Codex's plan, full mission context + graph context from /tmp/mission-<id>.md>`,
    outputSchema: {
      type: "object",
      properties: {
        recommendation: { type: "string" },
        decisions: { type: "array", items: { type: "object" } },
        off_limits: { type: "array", items: { type: "string" } },
        deliverable_path: { type: "string" }
      },
      required: ["recommendation", "decisions", "off_limits"]
    }
  }),
  agent("critic", {
    model: "claude-sonnet-5",
    prompt: `<initial framing review — review mission scope, highlight structural risks, do NOT review a plan (none exists yet)>`,
    outputSchema: {
      type: "object",
      properties: {
        concerns: { type: "array", items: { type: "string" } },
        severity_max: { type: "string", enum: ["critical", "high", "medium", "low", "none"] }
      },
      required: ["concerns", "severity_max"]
    }
  })
]);

// Synthesis stage (pipeline after parallel)
const synthesis = await pipeline(results, {
  agent: "lead",
  prompt: `Synthesize architect + critic outputs into context.yaml decisions/off_limits/plan.steps`,
});

// Adversarial-verify stage — class >= Standard only
// For Heavy/Strategic: 2-of-3 refute kills a finding (majority vote)
if (taskClass >= "Standard") {
  const verified = await pipeline(synthesis, {
    agent: "critic",
    prompt: `Adversarial verify: for each proposed decision, refute or confirm.
             A decision is killed if ≥2 of 3 review dimensions (correctness, risk, feasibility) refute it.`,
    outputSchema: {
      type: "object",
      properties: {
        verified_decisions: { type: "array" },
        killed_decisions: { type: "array" },
        kill_reasons: { type: "object" }
      }
    }
  });
}
```

The Workflow returns structured JSON results directly — no Monitor polling, no manual
deliverable-file reads. Codex (`leadv2-codex-planner.sh`) stays orthogonal: fire it as an optional
background Bash call outside the Workflow if available.

**Note:** `Workflow` requires Max or Team plan. If the tool is not available in the current
session, fall through to the manual path in SKILL.md.
