# Usage Examples — Injection per Caller Type

## lead-classify

```python
pp = get_phase_priors(priors, suspected_change_kind)
if pp:
    avg_class   = pp.get("avg_class")           # default class hint
    sr_30d      = pp.get("success_rate_30d")    # risk signal
    fail_modes  = pp.get("common_failure_modes", [])
```

## leadv2-plan

```python
for agent in plan_steps_agents:
    ap = get_agent_priors(priors, agent)
    model_rec = ap.get("model_recommendation", {}).get(change_kind) or ap.get("model_recommendation", {}).get("default", "sonnet")
    best_on   = ap.get("best_on", [])
```

## leadv2-premortem

```python
rp = get_risk_priors(priors)
high_risk_files = rp.get("high_latent_risk_files", [])
induced_rate    = rp.get("induced_regression_rate_30d", 0.0)
```

## leadv2-llm-judge (deploy packet, ≤300 tokens)

```python
fqp = get_fix_quality_priors(priors)
blocks = get_active_blocks(priors)
priors_summary = {
    "band_aid_ratio_30d":  fqp.get("band_aid_ratio_30d"),
    "active_nm_ids":       blocks.get("negative_memory_ids", []),
    "induced_regression_rate_30d": get_risk_priors(priors).get("induced_regression_rate_30d"),
}
```
