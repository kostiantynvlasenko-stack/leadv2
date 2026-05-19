---
name: leadv2-priors
description: [internal] Injects relevant slice of leadv2-priors.yaml into classify/plan/build/premortem/llm-judge;…
allowed-tools:
  - Read
  - Bash
---

# Lead v2 Priors — Unified Operator Intuition

## When: classify, plan, build, review, premortem, or llm-judge needs contextual defaults
## When NOT: during active code writes or mid-task file edits; trivial tasks (skip for speed)

---

## Protocol

### 1. Load priors

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

### 2. Freshness check

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

### 3. Extract slice by change_kind

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

### 4. Inject into calling skill

Callers receive a compact dict. Inject into context, mission brief, or decision table.

Example injection for `lead-classify`:
```python
pp = get_phase_priors(priors, suspected_change_kind)
if pp:
    avg_class   = pp.get("avg_class")           # default class hint
    sr_30d      = pp.get("success_rate_30d")    # risk signal
    fail_modes  = pp.get("common_failure_modes", [])
```

Example injection for `leadv2-plan`:
```python
for agent in plan_steps_agents:
    ap = get_agent_priors(priors, agent)
    model_rec = ap.get("model_recommendation", {}).get(change_kind) or ap.get("model_recommendation", {}).get("default", "sonnet")
    best_on   = ap.get("best_on", [])
```

Example injection for `leadv2-premortem`:
```python
rp = get_risk_priors(priors)
high_risk_files = rp.get("high_latent_risk_files", [])
induced_rate    = rp.get("induced_regression_rate_30d", 0.0)
```

Example injection for `leadv2-llm-judge` (deploy packet, ≤300 tokens):
```python
fqp = get_fix_quality_priors(priors)
blocks = get_active_blocks(priors)
priors_summary = {
    "band_aid_ratio_30d":  fqp.get("band_aid_ratio_30d"),
    "active_nm_ids":       blocks.get("negative_memory_ids", []),
    "induced_regression_rate_30d": get_risk_priors(priors).get("induced_regression_rate_30d"),
}
```

---

## Rules

- Priors never override explicit founder decisions — they inform defaults only.
- If `priors.yaml` is missing or stale (>7d): log WARN, trigger recompile, fall through to old per-source reads. Never hard-fail.
- Read `docs/leadv2-priors.yaml` once per phase entry — do NOT re-read inside loops.
- `change_kind` slice may return `{}` for unknown types — treat as no-prior, not as error.
- Priors are compiled READ-ONLY from source files — this skill never writes to source files.

## Anti-patterns

- Blocking a phase because priors.yaml is missing — it is enrichment, never a gate.
- Reading the full priors dict and injecting all fields — extract only the relevant slice for token efficiency.
- Treating `success_rate_30d: insufficient_data` as 0 — skip the field when calculating risk adjustments.
- Auto-promoting patterns based on priors — promotion remains manual (human review required).
