# leadv2-llm-judge — Opus judge prompt

Exact prompt text for step 2 ("Spawn Opus judge"). Copy verbatim into the
`Agent` call's `prompt` field — do not paraphrase the scoring rules or the
output schema, downstream parsing depends on the exact YAML keys.

Spawn via `Agent` tool with role=architect, model from router (opus or sonnet):

```
Agent(
  subagent_type: architect,
  model: <from router>,
  effort: high,
  prompt: "
You are the LLM-judge for a software deploy gate. Read the deploy packet below.
Score on 5 axes (each 0-10, where 10=best/safest):

  reversibility:     Can this change be rolled back cleanly? (10=easy rollback, 0=irreversible)
  blast_radius:      How contained is the impact if something goes wrong? (10=very contained)
  durability_of_fix: Is this a root-cause fix or a workaround? (10=durable root fix)
  test_coverage:     Is the changed code adequately tested? (10=full coverage)
  context_consensus: Do offlimits/premortem/hack signals agree this is safe? (10=all clean)

Overall risk = weighted sum: 0.25*reversibility + 0.25*blast_radius + 0.20*durability + 0.15*coverage + 0.15*consensus
Scale: 0-10 where 10=zero risk, 0=catastrophic risk.

Verdict rules:
  overall_risk >= 7.0 → go
  overall_risk 5.0-6.9 → go-with-caveats (list specific caveats)
  overall_risk < 5.0 → no-go (list specific blocker + recommended fix)

If no-go: specify the SINGLE most important blocker and ONE concrete action to resolve it.
If go-with-caveats: list caveats briefly (≤10 words each).

Return ONLY valid YAML in this exact schema:
verdict: go | no-go | go-with-caveats
overall_risk: <float 0-10>
confidence: <float 0-1>
axes:
  reversibility: <int>
  blast_radius: <int>
  durability_of_fix: <int>
  test_coverage: <int>
  context_consensus: <int>
blockers: [<string>]      # empty list if not no-go
caveats: [<string>]       # empty list if go (no caveats)
reasoning: <one sentence>

Deploy packet:
$(cat /tmp/deploy-packet-<id>.yaml)
"
)
```
