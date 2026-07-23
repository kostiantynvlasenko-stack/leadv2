# Implementation — Load, Check, and Extract Priors

## Load priors

```python
from pathlib import Path
import yaml

PRIORS_FILE = Path("docs/leadv2-priors.yaml")

def load_priors() -> dict:
    if not PRIORS_FILE.is_file():
        return {}
    try:
        return yaml.safe_load(PRIORS_FILE.read_text()) or {}
    except Exception:
        return {}

priors = load_priors()
```

## Freshness check

```python
from datetime import datetime, timezone, timedelta

compiled_at_str = priors.get("compiled_at", "")
stale = True
if compiled_at_str:
    try:
        compiled_at = datetime.fromisoformat(compiled_at_str.replace("Z", "+00:00"))
        age_hours = (datetime.now(timezone.utc) - compiled_at).total_seconds() / 3600
        stale = age_hours > 168   # 7 days
    except ValueError:
        stale = True

if stale:
    # Log WARN — do not hard-fail; fall through to per-source reads
    import subprocess
    import sys
    print("WARN [leadv2-priors]: priors.yaml missing or older than 7d — recompiling ...", file=sys.stderr)
    try:
        subprocess.run(
            ["bash", ".claude/scripts/leadv2-priors-compile.sh"],
            timeout=60,
            check=False,
        )
        priors = load_priors()   # reload after recompile
    except Exception as e:
        print(f"WARN [leadv2-priors]: recompile failed ({e}) — using stale/empty priors", file=sys.stderr)
```

## Extract slice by change_kind

Callers pass the current task's `change_kind` (from `context.yaml` or `graph_footprint`).

```python
def get_phase_priors(priors: dict, change_kind: str | None) -> dict:
    """Return phase_priors slice for the given change_kind, or empty dict."""
    if not change_kind:
        return {}
    return (
        priors
        .get("phase_priors", {})
        .get("by_change_kind", {})
        .get(change_kind, {})
    )

def get_agent_priors(priors: dict, agent: str) -> dict:
    """Return agent_priors slice for the given agent name."""
    return priors.get("agent_priors", {}).get(agent, {})

def get_active_blocks(priors: dict) -> dict:
    """Return active_blocks dict."""
    return priors.get("active_blocks", {})

def get_risk_priors(priors: dict) -> dict:
    return priors.get("risk_priors", {})

def get_routing_priors(priors: dict) -> dict:
    return priors.get("routing_priors", {})

def get_fix_quality_priors(priors: dict) -> dict:
    return priors.get("fix_quality_priors", {})
```

## Accessor slice structure

Each accessor returns a dict shaped for its use case:

- **`get_phase_priors`** → `{avg_class, success_rate_30d, common_failure_modes, [...]}`
- **`get_agent_priors`** → `{model_recommendation: {change_kind: "model"}, best_on: [...], [...]}`
- **`get_active_blocks`** → `{negative_memory_ids: [...]}`
- **`get_risk_priors`** → `{high_latent_risk_files: [...], induced_regression_rate_30d: 0.0, [...]}`
- **`get_routing_priors`** → `{model_defaults: {...}, [...]}`
- **`get_fix_quality_priors`** → `{band_aid_ratio_30d: 0.0, [...], induced_regression_rate_30d: 0.0, [...]}`
