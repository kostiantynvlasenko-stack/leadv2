# Implementation Examples

Reference implementations for each step in the premortem-deploy protocol.

## Step 2: Load token ceiling

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

## Step 3: Read estimated tokens

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

## Step 4: Evaluate ceiling

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

## Step 5: Example output

```yaml
# docs/handoff/<task-id>/premortem-deploy.yaml
block_deploy: false
ceiling_status: ok
task_class: Standard
ceiling_input_tokens: 800000
estimated_input_tokens: 240000
utilization_pct: 30.0
routing_yaml: .claude/ref/leadv2-routing.yaml
timestamp: 2026-04-27T00:00:00Z
```

## Step 6: Lead reads and circuit-breaks

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
