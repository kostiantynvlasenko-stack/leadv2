---
name: leadv2-premortem-deploy
description: [internal] Token-ceiling guard before deploy; compares cost-estimate.yaml to routing.yaml ceiling; emits…
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

```python
import yaml
from pathlib import Path

routing = yaml.safe_load(Path(".claude/ref/leadv2-routing.yaml").read_text()) or {}
ceilings = routing.get("stop_rules", {}).get("token_ceiling_per_task", {})
task_class = context.get("classification", {}).get("class", "Standard")
ceiling_input = ceilings.get(task_class, {}).get("input", None)
warn_pct = ceilings.get("warn_threshold_pct", 60) / 100
hard_stop_pct = ceilings.get("hard_stop_threshold_pct", 95) / 100
```

### 3. Read estimated tokens from cost-estimate.yaml

```python
estimate = yaml.safe_load(Path(f"docs/handoff/{task_id}/cost-estimate.yaml").read_text()) or {}
# Try direct field first, then derive from USD estimate
estimated_input = estimate.get("estimated_input_tokens")
if estimated_input is None:
    # Fallback: derive from expected_total_usd.mean using Sonnet pricing
    mean_usd = (estimate.get("expected_total_usd") or {}).get("mean", 0.0)
    # Rough: $3/1M input tokens for Sonnet
    estimated_input = int(mean_usd / 3.0 * 1_000_000) if mean_usd else 0
```

### 4. Evaluate ceiling

```python
if ceiling_input and estimated_input:
    ratio = estimated_input / ceiling_input
    if ratio >= hard_stop_pct:
        status = "hard_stop"
        block_deploy = True
    elif ratio >= warn_pct:
        status = "warn"
        block_deploy = False
    else:
        status = "ok"
        block_deploy = False
else:
    status = "unknown"
    block_deploy = False
    ratio = None
```

### 5. Write premortem-deploy output

Write `docs/handoff/<task-id>/premortem-deploy.yaml`:

```yaml
block_deploy: false          # true if estimated_input >= 95% of ceiling
ceiling_status: ok           # ok | warn_60pct | hard_stop_95pct | unknown
task_class: Standard
ceiling_input_tokens: 800000
estimated_input_tokens: 240000
utilization_pct: 30.0
routing_yaml: .claude/ref/leadv2-routing.yaml
timestamp: 2026-04-27T00:00:00Z
```

### 6. Lead reads and circuit-breaks if needed

Lead reads `premortem-deploy.yaml.block_deploy`:
- `false` → proceed with Deploy
- `true` → circuit-break: emit warn to founder, downgrade models per
  `downgrade_chain` in routing.yaml before spawning any further subsessions

```bash
block=$(python3 -c "
import yaml, sys
d = yaml.safe_load(open('docs/handoff/$TASK_ID/premortem-deploy.yaml')) or {}
print('true' if d.get('block_deploy') else 'false')
" 2>/dev/null || echo "false")

if [[ "$block" == "true" ]]; then
    echo "[premortem-deploy] WARN: token ceiling breached — applying model downgrade before deploy"
    # Apply downgrade_chain: opus→sonnet, sonnet→haiku
fi
```

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
