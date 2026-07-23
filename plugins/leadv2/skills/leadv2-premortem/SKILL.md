---
name: leadv2-premortem
description: "[internal] Bash+heuristic probability table for build/deploy success and rollback risk; no LLM cost."
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

## What it computes

No LLM calls — pure bash+heuristics. Reads `context.yaml` / `prior-art.yaml` /
`negative-memory.yaml` (+ `coverage.yaml` / `review.yaml` for deploy phase), scores a
weighted risk-factor table against a 0.80 base success probability, derives an outcome
distribution (success / block_offlimits / rollback / verify_timeout / partial_coverage),
and writes `docs/handoff/<task-id>/premortem-<phase>.yaml` plus a unified
`docs/handoff/<task-id>/premortem.yaml` for downstream consumers (trajectory checker,
llm-judge).

For the full weight tables, the risk-prior enrichment logic, the outcome-distribution
formula, the output YAML schema, and the unified-writer script, see
[ALGORITHM.md](./ALGORITHM.md).

Exit codes:
- `0` = proceed
- `1` = proceed_with_caution
- `2` = skip_recommended

## Wire-in points

- **Between Plan and Build (Phase 3→4):** call `bash .claude/scripts/lv2 leadv2-premortem.sh --task-id <id> --phase build`
  - If exit=2: Tier B pause before Build, recommend architect redesign
  - If exit=1: spawn extra critic pass reviewing plan complexity
  - If exit=0: proceed to Build as normal

- **Between Review and Deploy (Phase 5→6):** call `bash .claude/scripts/lv2 leadv2-premortem.sh --task-id <id> --phase deploy`
  - If exit=2: Tier B pause, default=redesign
  - If exit=1: pre-mortem verdict added to LLM-judge packet (caution flag)
  - If exit=0: proceed to LLM-judge gate

## Verdict routing

| Verdict | Action |
|---|---|
| `proceed` | Continue normal flow |
| `proceed_with_caution` | Spawn extra critic pass (build phase) OR upgrade to Tier B decision (deploy phase) |
| `skip_recommended` | Tier B default-timeout to founder: "Premortem says 40% success — skip / continue / redesign?" Default=redesign via architect |

## Calibration note

These probabilities are **calibration targets based on code patterns**, not empirical measurements.
Tune weights in `leadv2-premortem.sh` as real outcome data accumulates (target: 50+ tasks).
Document tuning history in `.claude/ref/leadv2-premortem-calibration.md`.

## Rules

- **No LLM calls.** All logic is bash+python heuristics. Zero token cost.
- **Non-blocking for proceed.** Do not add latency to the happy path.
- **Verbose factor list.** Always write all factors with triggered: true|false. LLM-judge reads this.
- **Audit trail.** premortem-<phase>.yaml is append-once — never overwrite an existing run.
