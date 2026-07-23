---
name: leadv2-diverge
description: "Phase 1.5 divergent ideation before planning (isolated frame-shifted generators + critic). Triggers: explicit /leadv2 diverge, or auto on Heavy that passes the open-ended self-judge."
allowed-tools:
  - Read
  - Write
  - Edit
  - Bash
  - Grep
  - Glob
---

# Lead v2 Diverge — Frame-Shifted Divergent Ideation

> Stop picking the textbook answer. The first three answers the model gives are
> the answers a senior engineer gives in thirty seconds — correct, forgettable.
> The interesting answers live past number three, in the awkward middle nobody
> walks into. This phase makes the model walk there *before* it commits to a plan.

Ported from **ADHD** (https://github.com/UditAkhourii/adhd, Udit Akhouri, MIT).
The load-bearing port choices: divergence branches are **isolated Agent spawns**
(no shared context), and the generator/critic split is **mechanical** (separate
spawns, opposite system prompts) — never promised inside one prompt.

## When: Phase 1.5, AFTER classify, BEFORE Phase 2 plan.

This is the widen-the-search step. Phase 2 (architect+critic+Codex) is
convergent by construction — the architect proposes, the critic prunes. That
anchors on the first plausible architecture. Diverge runs first to map the
*shape* of the solution space so Phase 2 converges on a candidate set, not on
the obvious default.

## Pre-flight gate — run BEFORE anything (this phase is expensive)

~10 Agent spawns, 30–90s, 5–10× a single answer. In a large-CLAUDE.md repo each
branch reloads the base substrate, so real cost ≈ `N × (base + branch)`. Do NOT
pay it when a direct plan is better.

Evaluate the steps **in this exact order**. Explicit invocation overrides class
and self-judge — but NOT the environment guards in Step 0, which can never spawn.

**Step 0 — environment guards (block EVERYTHING, incl. explicit `/leadv2 diverge`).**
If any holds, do NOT spawn. Write `diverge: skipped (<reason>)` to STATE.md AND
say it loudly in chat (never silent — the founder may have typed `diverge`):
- `LEADV2_DRY_RUN=1` → "dry-run: divergence not spawned"
- last cost-estimate returned `within_cap: false` → "over token cap: divergence skipped"
- `emergency_mode=true` in STATE.md, or founder granted "no approvals" → "emergency mode: divergence skipped"

**Step 1 — explicit invocation (overrides Step 2 + Step 3).** If the founder typed
`/leadv2 diverge` (or "diverge this", "widen this", "give me a few ways",
"разойдись по вариантам"), and Step 0 passed, go straight to Phase 1 — regardless
of class (even Trivial/Light) and without the self-judge. They opted in.

**Step 2 — class hard-skip (AUTO path only; explicit already passed in Step 1):**
- `class` is `Trivial` or `Light` → skip to Phase 2.
- `bug:` prefix WITH a known/located root cause → skip (fuzzy bugs with NO root
  cause are a valid USE case — keep those).

**Step 3 — self-judge (AUTO path only).** All three must hold, else skip:
1. **Open-ended?** Would a senior give multiple viable answers, or is there one
   canonical answer? Canonical → skip.
2. **High-stakes?** Architecture, public API/SDK/CLI surface, schema design,
   migration strategy, naming a real product, fuzzy bug with no root cause,
   positioning/pricing = yes. Routine wiring = no.
3. **Open phrasing?** Did the founder AVOID closed words ("quick", "standard",
   "canonical", "textbook", "just", "one-line", "how do I", "what is the syntax")?
   If they used any, they want the direct answer → skip.

**Step 4 — auto-fire policy (AUTO path, when Step 3 passes):**
- `Heavy` (or `Strategic`, if your repo's classifier emits it) → run automatically.
- `Standard` → do NOT auto-run.
  - If `LEADV2_DAEMON=1` or `LEADV2_BOT_MODE` set → skip without prompting (no
    human to answer; `diverge: skipped (daemon, Standard not auto)`).
  - Else fire ONE `AskUserQuestion`: *"Open-ended design call. Run divergent
    ideation (~10 agents, ~60s) before planning?"* options `[Diverge first
    (recommended) / Skip — plan directly]`, 60s timeout → default **Skip**.
  - NOTE: product naming / positioning / pricing often classify as `Standard`,
    not `Heavy` — those are prime diverge cases but will NOT auto-fire. Use
    explicit `/leadv2 diverge` for them.

On any skip, write `diverge: skipped (<reason>)` to STATE.md and proceed to
Phase 2. On auto-skip you may tell the founder once: *"Direct plan; run
`/leadv2 diverge` for a wider search with explicit trap detection."*

## Load the frames

```bash
# defaults ship with the plugin; repo may extend/override by id
FRAMES_DEFAULT="${CLAUDE_PLUGIN_ROOT}/data/leadv2-frames.yaml"
FRAMES_REPO="docs/leadv2-frames.yaml"   # optional per-repo frame-pack
```
Read the default file. If `docs/leadv2-frames.yaml` exists, merge repo frames
over defaults by `id` (repo wins on collision; new ids append). Also read the
`scoring:` weights and `selection:` policy.

**Hard spawn ceiling (clamp AFTER merging any repo override — non-negotiable).**
A repo `selection:` block cannot blow the per-turn spawn budget. Clamp the
effective values: `frames_per_run ≤ 8`, `ideas_per_frame ≤ 12`, `top_k ≤ 5`.
Total spawns = `frames_per_run + 1 + top_k` must be `≤ 14`; if a repo override
exceeds it, clamp down and log `diverge: selection clamped (<requested> → <used>)`
to STATE.md. The default 5+1+3 = 9 is the recommended point.

> **PREFERRED — saved workflow (offload, model-pinned, 2026-06-09):** when the `Workflow` tool is available, issue
> `Workflow({name:"leadv2-diverge", args:{taskId, problem, n}})` instead of the manual Phase 1/2/3 below.
> It runs N deterministic frame-shifted generators (sonnet) in parallel + a judge (critic, sonnet) that scores/
> clusters/flags-traps and writes divergence.md, returning `{candidate_count, recommended, top[]}`. Honors the
> pre-flight gate above (run it FIRST). The manual phases below are the FALLBACK when `Workflow` is unavailable.

## Manual fallback (Workflow tool unavailable)

For the full Phase 1 (DIVERGE) / Phase 2 (FOCUS) / Phase 3 (DEEPEN top-K) spawn
mechanics, generator/critic prompt text, and the `divergence.md` + `context.yaml`
output schema, see [PHASES.md](./PHASES.md). Only needed when the `Workflow`
tool above is not available — read it in full before running the manual path.

## Cost banner, anti-patterns, calibration

- Before spawning (manual path), a cost banner MUST be appended to STATE.md.
- Known ways this phase goes wrong (convergence-disguised-as-divergence,
  skipping isolation, critic-in-the-generator, refusing to commit, walls of
  prose) and how to scale frame/idea counts to stakes.

Full text: [REFERENCE.md](./REFERENCE.md).
