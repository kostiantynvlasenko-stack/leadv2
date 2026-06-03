---
name: leadv2-llm-judge
description: [internal] Opus deploy gate; reads diff stats, premortem, hack findings; returns risk 0-10 + go/no-go.
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

### 3. Parse and write output

Parse Opus response into `docs/handoff/<task-id>/llm-judge.yaml`:

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

### 3b. Mandatory YAML writer

After parsing Opus response and writing `llm-judge.yaml`, also write a
stable `docs/handoff/<task-id>/llm-judge.yaml` using this Python block.
This runs even if skipping (writes with `skipped: true`):

```bash
python3 - "$TASK_ID" "docs/handoff/$TASK_ID/llm-judge.yaml" <<'PY'
import sys, yaml, os
from pathlib import Path
from datetime import datetime, timezone

task_id, src_path = sys.argv[1], sys.argv[2]
src = Path(src_path)

if src.is_file():
    raw = yaml.safe_load(src.read_text()) or {}
    judge = raw.get("llm_judge", raw)
else:
    judge = {}

out = Path(f"docs/handoff/{task_id}/llm-judge.yaml")
out.parent.mkdir(parents=True, exist_ok=True)

data = {
    # Nested llm_judge block — shape expected by existing status/deploy readers.
    "llm_judge": {
        "task_id": task_id,
        "judged_at": datetime.now(timezone.utc).isoformat(),
        "model_used": judge.get("model_used", "opus"),
        "verdict": judge.get("verdict", "unknown"),
        "overall_risk": judge.get("overall_risk", judge.get("risk_score", 0.0)),
        "confidence": judge.get("confidence", 0.0),
        "axes": judge.get("axes", {}),
        "blockers": judge.get("blockers", []),
        "caveats": judge.get("caveats", []),
        "reasoning": judge.get("reasoning", ""),
        "skipped": judge.get("skipped", False),
        "skip_reason": judge.get("skip_reason", ""),
    },
    # Top-level convenience fields (F-PERSIST additions — do not conflict with nested shape).
    "escalated_from_haiku": False,
    "opus_used": judge.get("model_used", "").startswith("opus") if judge.get("model_used") else True,
    "timestamp_utc": datetime.now(timezone.utc).isoformat(),
}
import tempfile
tmp = out.with_suffix(".tmp")
tmp.write_text(yaml.safe_dump(data, sort_keys=False))
os.replace(tmp, out)
print(f"[llm-judge-writer] wrote {out}", file=sys.stderr)
PY
```

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
