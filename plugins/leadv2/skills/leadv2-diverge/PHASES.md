# Manual fallback — Phase 1/2/3 execution + output schema

This is the manual execution path for `leadv2-diverge`, used only when the
`Workflow` tool is unavailable (the SKILL.md "Load the frames" section's
PREFERRED note explains when to use `Workflow({name:"leadv2-diverge", ...})`
instead — check that first).

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
