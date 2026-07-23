---
name: leadv2-priors
description: "[internal] Load the fresh, phase-relevant slice of operator priors for classify/plan/build/review/judge."
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

Load `docs/leadv2-priors.yaml` once per phase entry. For detailed code and error handling, see [IMPLEMENTATION.md](./IMPLEMENTATION.md).

### 2. Freshness check

Check compilation timestamp. If missing or older than 7 days, trigger recompile via `.claude/scripts/leadv2-priors-compile.sh`. Log WARN but do NOT hard-fail — fall through to per-source reads on stale/missing. Full implementation: [IMPLEMENTATION.md](./IMPLEMENTATION.md).

### 3. Extract slice by change_kind

Call one of these accessor functions to extract the relevant slice:
- `get_phase_priors(priors, change_kind)` — phase defaults for the task's change_kind
- `get_agent_priors(priors, agent_name)` — agent model/routing hints
- `get_active_blocks(priors)` — active negative-memory IDs
- `get_risk_priors(priors)` — regression/latent-risk signals
- `get_routing_priors(priors)` — model routing defaults
- `get_fix_quality_priors(priors)` — band-aid ratio, quality signals

Full accessor implementations and slice structure: [IMPLEMENTATION.md](./IMPLEMENTATION.md).

### 4. Inject into calling skill

Pass the extracted slice to the caller's context, mission brief, or decision table. Do NOT inject the full priors dict — extract and inject only the relevant subset for token efficiency.

See [EXAMPLES.md](./EXAMPLES.md) for example injections per caller type (lead-classify, leadv2-plan, leadv2-premortem, leadv2-llm-judge).

---

## Rules

- **Priors never override explicit founder decisions** — they inform defaults only.
- **If `priors.yaml` is missing or stale (>7d):** log WARN, trigger recompile, fall through to old per-source reads. Never hard-fail.
- **Read `docs/leadv2-priors.yaml` once per phase entry** — do NOT re-read inside loops.
- **`change_kind` slice may return `{}`** for unknown types — treat as no-prior, not as error.
- **Priors are compiled READ-ONLY** from source files — this skill never writes to source files.

## Anti-patterns

- Blocking a phase because priors.yaml is missing — it is enrichment, never a gate.
- Reading the full priors dict and injecting all fields — extract only the relevant slice for token efficiency.
- Treating `success_rate_30d: insufficient_data` as 0 — skip the field when calculating risk adjustments.
- Auto-promoting patterns based on priors — promotion remains manual (human review required).
