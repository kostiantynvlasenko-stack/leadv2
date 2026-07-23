---
name: leadv2-llm-judge
description: "[internal] Phase 6 Deploy gate, mandatory: Opus risk verdict (0-10, go/no-go) from diff+premortem+hack findings. Skip only if Light+clean+premortem-proceed+zero hack blocks."
allowed-tools:
  - Read
  - Write
  - Bash
  - Glob
---

# Lead v2 LLM-Judge Deploy Gate

## When
- Phase 6 Deploy, AFTER premortem (step 0.6), BEFORE auto-Gate 2 check (step 0)
- Insert as step 0.7 in deploy protocol

## When NOT
- `task.classification == Light` AND `offlimits clean` AND `premortem.verdict == proceed` AND `hack_findings.block == 0`
  → Skip entirely. Log `llm_judge: skipped (Light+clean)` to context.yaml.
  Saves Opus tokens for predictable low-risk deploys.

## Cost
- Single Opus call, high-effort, ~3-8k tokens in (packet), ~500 tokens out
- Approximate cost: $0.05–0.15 per task
- Use `leadv2-router.sh --phase deploy --step llm_judge` to confirm Opus allowed;
  auto-downgrade to Sonnet if Opus would exceed task cost ceiling

## Protocol

### 1. Assemble compact deploy packet

Read inputs (all from `docs/handoff/<task-id>/`):

```
context.yaml       → task_id, classification, graph_footprint, decisions, off_limits
coverage.yaml      → new_code_pct, passed
offlimits result   → from context.yaml.deploy_gate.offlimits_result
premortem-deploy.yaml → success_prob, verdict
hack-detection.yaml   → findings by severity (info/warn/block)
review.yaml           → findings_remaining, rounds
prior-art.yaml        → top-3 outcomes summary
negative-memory.yaml  → hits count
```

For the exact packet yaml shape, see [SCHEMAS.md](./SCHEMAS.md) ("Deploy packet").

Packet assembly rule: if a field is missing/unknown, omit it rather than invent it.

### 2. Spawn Opus judge

Use `leadv2-router.sh` to confirm model selection:

```bash
router_out=$(bash .claude/scripts/lv2 leadv2-router.sh \
  --phase deploy --step llm_judge \
  --task-id <id> --class <classification>)
model=$(echo "$router_out" | grep '^model=' | cut -d= -f2)
ceiling_status=$(echo "$router_out" | grep '^ceiling_status=' | cut -d= -f2)

# If hard_stop_95pct: skip judge, log warning, treat as go-with-caveats
[[ "$ceiling_status" == "hard_stop_95pct" ]] && {
  log_warn "LLM-judge skipped: cost ceiling reached. Treating as go-with-caveats."
  # Write synthetic verdict
  exit 0
}
```

Spawn via `Agent` tool with role=architect, model from router (opus or sonnet).
For the exact prompt text (scoring axes, weights, verdict thresholds, output
schema) — copy it verbatim from [PROMPT.md](./PROMPT.md).

### 3. Parse and write output

Parse Opus response into `docs/handoff/<task-id>/llm-judge.yaml`.
For the exact output schema, see [SCHEMAS.md](./SCHEMAS.md) ("Output —
llm-judge.yaml").

### 3b. Mandatory YAML writer

After parsing Opus response and writing `llm-judge.yaml`, also run the
stable writer script that normalizes `docs/handoff/<task-id>/llm-judge.yaml`.
This runs even if skipping (writes with `skipped: true`).
Exact script (copy verbatim, do not re-implement): [WRITER.md](./WRITER.md).

### 4. Route decision

| Verdict | overall_risk | Action |
|---|---|---|
| `go` | < 5 | Proceed to auto-Gate 2 silently (Tier A) |
| `go` | 5–7 | Treat as `go-with-caveats` — Tier B |
| `go-with-caveats` | any | Tier B default-timeout (10 min, default=proceed, caveats noted) |
| `no-go` | < 5 | Tier B (default=redesign via architect; founder can override to proceed) — NOT Tier C |

`no-go` is NOT Tier C because we always prefer forward motion with information.
Founder can override to force-proceed with risk acknowledged.

On `no-go` and class ≥ Standard:
- Block deploy
- Spawn architect with llm-judge blocker + deploy packet → root-cause redesign
- Return to Plan phase (respect R6.14 durable-fix bias)
- Record in context.yaml: `deploy_gate.llm_judge_block: true`

### 5. Update auto-Gate 2 conditions

Auto-Gate 2 (Tier A silent deploy) requires ALL of:
- Original Gate 2 conditions (light class, low risk, offlimits clean, coverage passed)
- PLUS: `llm_judge.verdict in [go, go-with-caveats]` OR `llm_judge.skipped == true`

If llm_judge.verdict == `no-go` → auto-Gate 2 is blocked regardless of other conditions.

## Deploy packet assembly script

The packet is assembled by `leadv2-llm-judge.sh` into `/tmp/deploy-packet-<id>.yaml`.
This script is called by lead during Phase 6.

## Rules

- **Packet ≤ 4k tokens.** Strip multi-line yaml values; truncate lists to top-3.
- **Skip Light+clean.** No Opus for predictable low-risk.
- **Router decides model.** Never hardcode opus — let router downgrade if ceiling reached.
- **Parse YAML strictly.** If Opus response is not valid YAML, re-prompt once; if still invalid, treat as `go-with-caveats` and log parse error.
- **Judgment is advisory.** Founder can always override `no-go` via Tier B decision with explicit acknowledgment.
