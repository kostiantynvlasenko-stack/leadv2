---
name: leadv2-diverge
description: "Phase 1.5 — divergent ideation BEFORE planning. Spawns N isolated frame-shifted generator agents (zero cross-talk), then a separate critic scores / clusters / flags traps / deepens top-K. Surfaces a non-obvious-but-viable candidate set that Phase 2 architect converges on. Expensive (~9 Agent spawns, hard ceiling 14) — gated to open-ended high-stakes design decisions. Triggers: explicit /leadv2 diverge (overrides class+self-judge; honors dry-run/cost-cap/emergency); auto on Heavy that passes the open-ended self-judge. Ported from ADHD (UditAkhourii/adhd, MIT)."
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

## Phase 1 — DIVERGE (no critic)

1. **Pick frames** (lead picks — no RNG needed). Take `selection.frames_per_run`
   (default 5). For code-shaped problems choose 4 tagged `code`/`design` + 1
   tagged `wild`. For product/strategy, mix all tags. **Vary the picks** vs the
   last diverge run on this repo (skim recent `docs/handoff/*/divergence.md`
   `frames_used:`) so re-runs explore differently. Always reserve ≥1 `wild`.

2. **Spawn N parallel isolated generators** — ONE message, all in background:
   ```
   Agent(subagent_type=general-purpose, model=sonnet, run_in_background=true)
   ```
   One spawn per frame. **Isolation is the mechanism, not a slogan** — branches
   that share context anchor each other and the method collapses to a wider
   single thought. Each spawn's prompt may contain ONLY, and nothing else:
   - the problem statement (1 short paragraph the lead writes — NOT the brief verbatim),
   - that ONE frame's vantage prompt,
   - an OPTIONAL hard-constraints blob, ≤200 words, of immovable facts only
     (stack, a hard limit) — no design opinions, no prior decisions.

   **Explicitly FORBIDDEN in a diverge spawn** (these are shared-anchoring leaks,
   the exact thing the ADHD port removes): any other branch's output; the full or
   partial `context.yaml`; Phase-1 `prior_art` / immune-memory / negative-memory
   entries; architect `decisions[]`; the MCP `## Graph context` block; the BOARD /
   RECOVERY excerpts. If you cannot state the problem in ≤200 words without pasting
   one of those, the task is not diverge-shaped — skip to Phase 2. Do NOT inherit
   the mission-file builder from Phase 2; diverge spawns get a fresh minimal prompt.

   Generator instruction (verbatim into each spawn):
   > You are in DIVERGENT mode. You are a generator, not a critic.
   > Generate {ideas_per_frame} short, distinct ideas under this frame. Each
   > idea is one phrase or one sentence. Do NOT evaluate, rank, or hedge.
   > The first three obvious answers everyone would give are BANNED — assume
   > the reader already had them. Push into the awkward middle. Bad/weird/absurd
   > ideas are welcome; they seed better ones.
   > Frame — {frame.label}: {frame.prompt}
   > Output a JSON array ONLY, no prose: [{"text":"...","rationale":"..."}]
   > Deliverable file: docs/handoff/<id>/diverge-<frame.id>.json — write it and
   > end with DELIVERABLE_COMPLETE.

3. Wait on the deliverable files (Monitor or background notifications). Read
   each with `Read limit=30`. Collect all ideas, tag each with its `frameId`.
   A branch that returns unparseable JSON contributes zero ideas — do not block.

## Phase 2 — FOCUS (critic on)

One critic spawn does score + cluster in a single call:
```
Agent(subagent_type=critic, model=<opus if Heavy/Strategic else sonnet>, run_in_background=true)
```
Mission (writes `docs/handoff/<id>/diverge-focus.json`):
> You are in CONVERGENT mode — now the critic. For the idea pool below:
> 1. SCORE each on novelty / viability / fit (0–10). Weighted total =
>    novelty*{w.novelty} + viability*{w.viability} + fit*{w.fit}. If an idea is
>    attractive-but-a-TRAP (hidden cost, false economy, won't scale, premature
>    abstraction), set "trap" to a one-line MECHANISTIC reason; else omit it.
> 2. CLUSTER all ideas into 3–6 groups by UNDERLYING ANGLE (not surface
>    keywords) — e.g. "remove-the-server plays", "cache-shaped plays".
> Output JSON only:
> {"scores":[{"id","novelty","viability","fit","trap?"}],
>  "clusters":[{"label","ideaIds":[...]}]}

After the critic returns:
- **traps** = ideas with a `trap` reason (reported separately, excluded from shortlist).
- **ranked** = non-trap ideas sorted by weighted total, desc.
- **shortlist** = top `min(4, top_k+1)` of ranked (≥2). Assign each a stable
  `id` (`s1`, `s2`, …) here — the same id used in the context.yaml block.
- **non_obvious_pick** = the **id** of the shortlist entry with the highest
  `novelty + 0.5*viability`. Mark it ★ — the non-obvious-but-viable bet.

## Phase 3 — DEEPEN top-K

Spawn `top_k` (default 3) parallel generators on the ranked top-K (one message,
background):
```
Agent(subagent_type=general-purpose, model=sonnet, run_in_background=true)
```
Deepen instruction per idea (writes `docs/handoff/<id>/deepen-<n>.json`):
> You are in FOCUS mode. Take ONE promising idea and connect dots.
> - Sketch how it would actually work (4–8 sentences).
> - Name the load-bearing risk.
> - Name the first concrete step a coder would take.
> - Generate 3–5 sub-ideas branching off (variations, hybrids, unlocks).
> Idea: {idea.text}{ " ("+rationale+")" if rationale }
> Sibling ideas (recombine if useful): {up to 12 sibling one-liners}
> Output JSON only: {"sketch":"...","childIdeas":[{"text","rationale"}]}

**Provocation** (no spawn — free): the single highest-novelty leaf in the whole
pool, phrased as `"What if we took this seriously: <text>"`.

## Output

Write the full artifact to `docs/handoff/<id>/divergence.md`:
1. **Brief** — 1–2 lines: the problem + any reframe used. `frames_used: [...]`.
2. **Wide set** — full pool grouped by cluster, each cluster labeled by angle.
   Each idea one line with score chips `[N7 V8 F9]`.
3. **Converge** — the 2–4 shortlist with one reason each. ★ non-obvious pick.
   **Traps** listed separately, each with its one-line reason.
4. **Focus** — the K deepened branches: sketch · load-bearing risk · first step
   · child ideas.
5. **Provocation** — the one wildcard.

Then inject a COMPACT block into `docs/handoff/<id>/context.yaml` for Phase 2:
```yaml
divergence:
  ran: true
  frames_used: [hardware-eyes, inversion, ...]
  shortlist:
    - id: s1                        # stable id — referenced by non_obvious_pick
      text: "..."
      score: {novelty: 8, viability: 7, fit: 9}
    - id: s2
      text: "..."
      score: {novelty: 6, viability: 9, fit: 8}
  non_obvious_pick: s1             # an id from shortlist[] — NOT a free string;
                                    # architect MUST evaluate this entry
  traps:                            # seed Phase 2 off_limits
    - {text: "...", reason: "..."}
  artifact: docs/handoff/<id>/divergence.md
```
Every `shortlist[]` entry carries a stable `id` (`s1`, `s2`, …) and a `score`
map. `non_obvious_pick` is the **id** of one shortlist entry — never a duplicated
text string (text drifts and can't be matched back). Keep the block ≤40 lines —
Phase 2 reads the full `divergence.md` on demand.

## Cost banner (token discipline)

Before spawning, append to STATE.md:
`diverge: running — N diverge + 1 focus + K deepen ≈ <N+1+K> Agent spawns`.
This makes the cost visible against the per-turn cap. If the session is already
near its spawn budget, prefer `frames_per_run: 3, ideas_per_frame: 4` (a 3×4
run ≈ 7 spawns) and note the reduced breadth in `divergence.md`.

## Anti-patterns (how this phase goes wrong)

- **Convergence disguised as divergence** — 10 minor variants of one idea is not
  breadth. If every candidate shares one assumption, you decorated, didn't diverge.
- **Skipping isolation** — simulating branches sequentially in one context is NOT
  diverge. Use real parallel Agent spawns; each gets a fresh context.
- **Critic in the generator** — never let a diverge spawn evaluate. Generation
  and judgment are separate spawns with opposite postures.
- **Refusing to commit** — after diverging, the shortlist + ★ pick is a real
  position, not "here are 20 ideas, you decide".
- **Walls of prose** — cluster, label, chip-score. The structure is half the value.

## Calibration

Scale to stakes. Naming a function = 3 frames × 4 ideas. "How should we shard
this under bursty load" / product positioning = 5 frames × 8 ideas. Default 5×6.
Flag wild-frame ideas clearly on serious strategy work so they don't read as
unserious. Stop diverging when new candidates repeat the shape of existing ones.
