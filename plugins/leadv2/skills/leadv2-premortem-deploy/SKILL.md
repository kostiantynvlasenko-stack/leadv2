---
name: leadv2-premortem-deploy
description: "[internal] Phase 6 Deploy gate, mandatory: checks est. tokens vs class token ceiling before commit. Skip if Trivial/Light with no cost signals, or cost-estimate.yaml absent."
status: deferred-v0.2
allowed-tools:
  - Read
  - Bash
---

# Lead v2 Pre-Mortem Deploy — Token Ceiling Guard

## When
Before Deploy commit (Phase 6) — check that estimated input tokens do not
exceed the token ceiling for the task's classification class.

## When NOT
- Phase is Trivial or Light with no prior cost signals — ceiling rarely breached
- cost-estimate.yaml is absent — skip guard, log warn, proceed

## Protocol

### 1. Read inputs
```
docs/handoff/<task-id>/context.yaml       — classification.class
docs/handoff/<task-id>/cost-estimate.yaml — expected_total_usd.mean, estimated_input_tokens
.claude/ref/leadv2-routing.yaml           — token_ceiling_per_task.<class>.input
```

### 2. Load token ceiling
Fetch task class and ceiling thresholds from routing.yaml. For implementation details, see [EXAMPLES.md](./EXAMPLES.md#step-2-load-token-ceiling).

### 3. Read estimated tokens from cost-estimate.yaml
Fetch direct `estimated_input_tokens` field, or derive from `expected_total_usd.mean` if absent. For implementation details, see [EXAMPLES.md](./EXAMPLES.md#step-3-read-estimated-tokens).

### 4. Evaluate ceiling
Compare estimated input tokens against ceiling using warn_threshold_pct (60%) and hard_stop_threshold_pct (95%). Classify status as `ok | warn | hard_stop | unknown`. For implementation details, see [EXAMPLES.md](./EXAMPLES.md#step-4-evaluate-ceiling).

### 5. Write premortem-deploy output
Write `docs/handoff/<task-id>/premortem-deploy.yaml` with fields: `block_deploy`, `ceiling_status`, `task_class`, `ceiling_input_tokens`, `estimated_input_tokens`, `utilization_pct`, `routing_yaml`, `timestamp`.

### 6. Lead reads and circuit-breaks if needed
Lead reads `premortem-deploy.yaml.block_deploy`:
- `false` → proceed with Deploy
- `true` → circuit-break: emit warn to founder, downgrade models per `downgrade_chain` in routing.yaml before spawning any further subsessions

For bash read implementation, see [EXAMPLES.md](./EXAMPLES.md#step-6-lead-reads-and-circuit-breaks).

## Output contract

```yaml
# docs/handoff/<task-id>/premortem-deploy.yaml
block_deploy: bool            # REQUIRED — lead reads this field
ceiling_status: str           # ok | warn_60pct | hard_stop_95pct | unknown
task_class: str
ceiling_input_tokens: int | null
estimated_input_tokens: int | null
utilization_pct: float | null
routing_yaml: str
timestamp: str
```

## Rules

- `block_deploy: true` does NOT hard-stop the session — it signals lead to downgrade models.
- If cost-estimate.yaml is absent: write `ceiling_status: unknown`, `block_deploy: false` and continue.
- If routing.yaml missing: same — unknown, no block.
- Never block on cost alone — only token ceiling (subscription model, not per-call billing).
- Log warn to stderr on any parse error, do not raise.

## Anti-patterns

- Blocking deploy solely because estimated_usd is high — use token ceiling, not USD.
- Parsing token ceiling without reading task_class from context.yaml — class determines the correct ceiling row.
- Skipping the step when cost-estimate.yaml is small — even Light tasks should get a ceiling check for calibration.
