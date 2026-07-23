# leadv2-llm-judge — schemas

Reference schemas for the deploy packet (input) and `llm-judge.yaml` (output).
Pulled out of SKILL.md step 1 and step 3 — read this when you need the exact
field shapes, not just the flow.

## Deploy packet (input to the Opus judge, step 1)

Build yaml packet (≤4k tokens — strip verbose fields, keep signal dense):

```yaml
deploy_packet:
  task_id: <id>
  classification: Standard
  graph_footprint:
    risk_score: low|medium|high|critical
    change_kind: feature|refactor|cross_service
    files_touched: 4
  coverage:
    new_code_pct: 65
    passed: true
  offlimits: clean | block_<rc>
  premortem:
    success_prob: 0.78
    verdict: proceed | proceed_with_caution | skip_recommended
    top_risk_factors: [list of triggered factors]
  hack_findings:
    info: 2
    warn: 1
    block: 0
  diff_stats:
    files_changed: 4
    lines_added: 87
    lines_removed: 12
  review_rounds: 1
  review_findings_remaining: 0
  rag_prior_outcome_summary: "3 similar past; 2 success, 1 rollback (different cause)"
  negative_memory_hits: []
```

Packet assembly rule: if a field is missing/unknown, omit it rather than invent it.

## Output — `docs/handoff/<task-id>/llm-judge.yaml` (step 3, before the mandatory writer normalizes it)

Parse the Opus response into this shape:

```yaml
llm_judge:
  task_id: <id>
  judged_at: <ISO>
  model_used: opus | sonnet  # from router
  verdict: go | no-go | go-with-caveats
  overall_risk: 3.2           # 0-10
  confidence: 0.82
  axes:
    reversibility: 8
    blast_radius: 6
    durability_of_fix: 7
    test_coverage: 6
    context_consensus: 9
  blockers: []
  caveats: ["Coverage at 65% — borderline"]
  reasoning: "Durable fix, clean offlimits, moderate blast radius. Green light."
  skipped: false              # true if Light+clean skip applied
  skip_reason: ""
```
