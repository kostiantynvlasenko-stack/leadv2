---
name: leadv2-premortem
description: [internal] Bash+heuristic probability table for build/deploy success and rollback risk; no LLM cost.
allowed-tools:
  - Read
  - Bash
  - Glob
---

# Lead v2 Pre-Mortem Simulator

## When
- Before Build spawn: `--phase build` — predict build success given plan complexity
- Before Deploy commit: `--phase deploy` — predict verify success + regression risk
- Ad-hoc: `bash .claude/scripts/lv2 leadv2-premortem.sh --task-id <id> --phase <build|deploy>`

## When NOT
- Light class with clean offlimits and no negative-memory hits — skip to save time
- Phase is Trivial — premortem adds no signal

## Protocol (no LLM — bash+heuristics only)

### 1. Read context inputs

```bash
# Always read:
docs/handoff/<task-id>/context.yaml          # task class, graph_footprint, decisions, off_limits
docs/handoff/<task-id>/prior-art.yaml        # RAG similarity matches + prior outcomes
docs/handoff/<task-id>/negative-memory.yaml  # negative-memory match hits (if run)

# For deploy phase also:
docs/handoff/<task-id>/coverage.yaml         # coverage.passed, new_code_pct
docs/handoff/<task-id>/review.yaml           # review findings remaining
```

### 1b. Enrich probability table with risk priors

```python
import yaml
from pathlib import Path

priors_path = Path("docs/leadv2-priors.yaml")
risk_priors = {}
if priors_path.is_file():
    try:
        p = yaml.safe_load(priors_path.read_text()) or {}
        risk_priors = p.get("risk_priors", {})
    except Exception:
        pass  # non-blocking: fall through to base table

# DEFENSIVE READ (Risk 5): fields remain "insufficient_data" until 10+ history entries exist.
# Always guard before numeric use — treat string sentinel and None identically as "no data".
def _prior_float(d: dict, key: str, default: float = 0.0) -> float:
    val = d.get(key, default)
    if val in (None, "insufficient_data", ""):
        return default
    try:
        return float(val)
    except (TypeError, ValueError):
        return default

def _prior_list(d: dict, key: str) -> list:
    val = d.get(key, [])
    if val in (None, "insufficient_data", ""):
        return []
    return val if isinstance(val, list) else []

# Adjust base success probability:
# - If change_kind file is in risk_priors.high_latent_risk_files → apply extra -0.05
# - If risk_priors.induced_regression_rate_30d > 0.15 → apply extra -0.05
high_risk_files = [f.split("  #")[0].strip() for f in _prior_list(risk_priors, "high_latent_risk_files")]
induced_rate = _prior_float(risk_priors, "induced_regression_rate_30d")

extra_risk = 0.0
if any(hf in str(changed_files) for hf in high_risk_files):
    extra_risk += 0.05   # known-hot file touched
if induced_rate > 0.15:
    extra_risk += 0.05   # recent regression rate elevated

# Add extra_risk to the failure-risk deduction before clamping
```

### 2. Compute probability table

Base success probability starts at **0.80**.

Risk factor weights (additive to failure risk = subtract from success):

| Factor | Condition | Weight (deduct from success) |
|---|---|---|
| `rag_prior_similar_rolled_back` | prior-art has outcome=rollback within top-3 similar | +0.15 |
| `graph_footprint_risk_high` | context.yaml graph_footprint.risk_score == high | +0.10 |
| `graph_footprint_risk_critical` | graph_footprint.risk_score == critical | +0.20 |
| `blast_radius_high` | graph_footprint.impacted_callers_count >= 10 (and < 25) | +0.10 |
| `blast_radius_critical` | graph_footprint.impacted_callers_count >= 25 | +0.20 (replaces blast_radius_high — mutually exclusive) |
| `negative_memory_match` | negative-memory.yaml has ≥1 match | +0.20 |
| `change_kind_cross_service` | context.yaml graph_footprint.change_kind contains cross_service | +0.05 |
| `off_limits_candidates_nonzero` | context.yaml off_limits list non-empty | +0.05 |
| `coverage_low` | deploy phase AND coverage.new_code_pct < 50 | +0.10 |
| `review_findings_remaining` | deploy phase AND review findings remaining > 0 | +0.15 |
| `high_decision_count` | decisions count > 5 | +0.05 |
| `no_prior_art` | prior-art.yaml empty or missing | +0.03 |
| `class_heavy_or_strategic` | task class is Heavy or Strategic | +0.05 |

**Positive factors (add to success):**

| Factor | Condition | Weight (add to success) |
|---|---|---|
| `prior_all_success` | prior-art top-3 all outcome=success | -0.10 (reduces risk) |
| `coverage_high` | deploy phase AND coverage.new_code_pct >= 70 | -0.05 |
| `class_light` | task class is Light | -0.05 |

Clamp final success probability to [0.05, 0.95].

### 3. Compute outcome distribution

Distribute remaining probability across failure modes proportionally:

```yaml
predicted_outcome_prob:
  success: <computed>
  block_offlimits: 0.02 * (risk_high ? 3 : 1)
  rollback: 0.10 * (negative_memory ? 2 : 1) * (rollback_prior ? 1.5 : 1)
  verify_timeout: 0.08 * (cross_service ? 1.5 : 1)
  partial_coverage: 0.05 * (coverage_low ? 2 : 1)
# Normalize to sum=1.0
```

### 4. Verdict

```
success_prob > 0.70  → verdict: proceed
success_prob 0.40-0.70 → verdict: proceed_with_caution
success_prob < 0.40  → verdict: skip_recommended
```

### 5. Output

Write `docs/handoff/<task-id>/premortem-<phase>.yaml`:

```yaml
premortem:
  task_id: <id>
  phase: build | deploy
  computed_at: <ISO timestamp>
  predicted_outcome_prob:
    success: 0.75
    block_offlimits: 0.02
    rollback: 0.10
    verify_timeout: 0.08
    partial_coverage: 0.05
  risk_factors:
    - factor: rag_prior_similar_rolled_back
      triggered: true
      weight: +0.15
    - factor: graph_footprint_risk_high
      triggered: false
      weight: +0.10
    # ... all factors listed, triggered: true|false
  verdict: proceed | proceed_with_caution | skip_recommended
  notes: "<one-line rationale>"
```

### 5b. Mandatory YAML writer (runs immediately after writing premortem-<phase>.yaml)

Write a unified `docs/handoff/<task-id>/premortem.yaml` so downstream consumers
(trajectory checker, llm-judge) have a stable single path regardless of phase:

```bash
python3 - "$TASK_ID" "$PHASE" "docs/handoff/$TASK_ID/premortem-${PHASE}.yaml" <<'PY'
import sys, yaml, os
from pathlib import Path
from datetime import datetime, timezone

task_id, phase, src_path = sys.argv[1], sys.argv[2], sys.argv[3]
src = Path(src_path)
if not src.is_file():
    print(f"[premortem-writer] WARN: source {src_path} not found, skipping", file=sys.stderr)
    sys.exit(0)

raw = yaml.safe_load(src.read_text()) or {}
pre = raw.get("premortem", raw)  # handle top-level or nested

out = Path(f"docs/handoff/{task_id}/premortem.yaml")
out.parent.mkdir(parents=True, exist_ok=True)

# Idempotent: overwrite with the latest phase data
data = {
    "task_id": task_id,
    "phase": phase,
    "verdict": pre.get("verdict", "unknown"),
    "probability_table": {
        "build_success":        pre.get("predicted_outcome_prob", {}).get("success", 0.0),
        "deploy_clean":         pre.get("predicted_outcome_prob", {}).get("success", 0.0),
        "block_risk":           pre.get("predicted_outcome_prob", {}).get("block_offlimits", 0.0),
        "rollback_probability": pre.get("predicted_outcome_prob", {}).get("rollback", 0.0),
    },
    "signals_used": [
        f["factor"] for f in pre.get("risk_factors", []) if f.get("triggered")
    ],
    "notes": pre.get("notes", ""),
    "timestamp_utc": datetime.now(timezone.utc).isoformat(),
}
import tempfile
tmp = out.with_suffix(".tmp")
tmp.write_text(yaml.safe_dump(data, sort_keys=False))
os.replace(tmp, out)
print(f"[premortem-writer] wrote {out}", file=sys.stderr)
PY
```

Exit codes:
- `0` = proceed
- `1` = proceed_with_caution
- `2` = skip_recommended

### 6. Verdict routing

| Verdict | Action |
|---|---|
| `proceed` | Continue normal flow |
| `proceed_with_caution` | Spawn extra critic pass (build phase) OR upgrade to Tier B decision (deploy phase) |
| `skip_recommended` | Tier B default-timeout to founder: "Premortem says 40% success — skip / continue / redesign?" Default=redesign via architect |

## Wire-in points

- **Between Plan and Build (Phase 3→4):** call `bash .claude/scripts/lv2 leadv2-premortem.sh --task-id <id> --phase build`
  - If exit=2: Tier B pause before Build, recommend architect redesign
  - If exit=1: spawn extra critic pass reviewing plan complexity
  - If exit=0: proceed to Build as normal

- **Between Review and Deploy (Phase 5→6):** call `bash .claude/scripts/lv2 leadv2-premortem.sh --task-id <id> --phase deploy`
  - If exit=2: Tier B pause, default=redesign
  - If exit=1: pre-mortem verdict added to LLM-judge packet (caution flag)
  - If exit=0: proceed to LLM-judge gate

## Calibration note

These probabilities are **calibration targets based on code patterns**, not empirical measurements.
Tune weights in `leadv2-premortem.sh` as real outcome data accumulates (target: 50+ tasks).
Document tuning history in `.claude/ref/leadv2-premortem-calibration.md`.

## Rules

- **No LLM calls.** All logic is bash+python heuristics. Zero token cost.
- **Non-blocking for proceed.** Do not add latency to the happy path.
- **Verbose factor list.** Always write all factors with triggered: true|false. LLM-judge reads this.
- **Audit trail.** premortem-<phase>.yaml is append-once — never overwrite an existing run.
