# EXAMPLES: Workflow tool model routing

## Pattern: model is per-`agent()`, no global default

When the lead authors a `Workflow` tool script (fan-out orchestration), the model-routing rule is **the same as for the Agent tool but multiplied by fan-out** — and there is **no settings.json default** for workflows. Every `agent()` with no `model:` opt inherits the **main-loop model**. An Opus lead authoring a bare-`agent()` workflow runs the whole fleet on Opus.

### Rule
**Every `agent()` in a workflow script carries an explicit `model:`.** No exceptions. A bare `agent()` is a bug — same severity as forgetting `model=` on `Agent(Explore)`.

### Routing mirrors the task-class table
- `model:'haiku'` for trace/read/discovery (pair with `agentType:'Explore'`)
- `model:'sonnet'` for write/verify/refute/synthesize
- `model:'opus'` only for a single deep-reasoning step — never the whole fleet

### Implementation
- Hoist the model into a `const` and pass it on every call; forgetting on one call silently routes that agent to Opus
- `meta.phases[].model` is **display-only** (labels the progress group); it does NOT route. Routing is `opts.model` in the `agent()` call
- Before launching: compute `agents = items × stages (+ synth)`. If that count on the inherited model is not what you intend, the `model:` opts are missing

### Incident example: 2026-05-31

A 13-subsystem × trace+verify pipeline shipped 27 Opus agents because no call set `model:`. Full cost impact: ~$2K Opus spend when Haiku + Sonnet would have cost ~$50.

**This applies in all repos.** In m3-market, workflow agents must still carry `model:` (Claude tiers only — no Codex/gpt-5 routing inside scripts).
