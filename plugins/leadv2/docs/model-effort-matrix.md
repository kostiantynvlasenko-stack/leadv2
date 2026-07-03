# Model × Effort Routing Matrix — canonical source (EFFORT-ROUTING-01, 2026-07-03)

The lead picks TWO knobs per spawn, not one: **model = task hardness, effort = marginal
value of extra thinking**. They are independent axes. Getting either wrong wastes quota
or quality; getting both wrong (weak model × max effort) is the worst trade — burns
thinking tokens AND fails the task.

## The three-question decision procedure (lead runs this per spawn)

1. **Code-shaped AND repo has `codex_enabled: true`?** → **Codex** (zero Claude quota).
   Effort: `high` default; `xhigh` for Heavy plan / final adversarial review.
2. **Background / bulk / mechanical — nobody waits at screen?** → **GLM** via
   `glm-coder.sh bg` (zero Claude quota; GLM-5.2 ≈ Sonnet 5 on SWE-bench Pro 62.1 vs
   63.2, within ~1% of Opus 4.8 on FrontierSWE long-horizon). Banned for
   architecture / design / safety. Haiku is the fallback when GLM lane is absent.
3. **Else Claude ladder by hardness** (interactive work):

| Hardness | Model | Effort | Examples |
|---|---|---|---|
| Reads, classify, greps, commits, aggregation | haiku | `low` | Explore, capability-classifier, quality-scorer, archive-write |
| Standard build / synthesis | sonnet | `medium` | developer, plan-synthesize, context.yaml writes |
| Adversarial gate / verdict | sonnet | `high` | critic, security-auditor, verify-blocking (Codex is primary; this is the 2nd voice) |
| Heavy design synthesis / judge | **fable → opus → sonnet** | `xhigh` | Heavy/Strategic architect, diverge judge, safety-touched review verdict |
| One-shot irreversible / Strategic gate | **fable → opus → sonnet** | `max` | Strategic plan synthesis, final deploy verdict on Heavy+safety |

## Effort ladder semantics

- `low` — no deliberation needed: the task is lookup, transform, or checklist-shaped.
- `medium` — DEFAULT for every spawn unless a rule below raises it. Standard code fits here.
- `high` — the output is a gate or verdict (review finding, judge score, security call):
  correctness has leverage, a miss costs a bad merge.
- `xhigh` — genuine novel synthesis: Heavy design, root-cause synthesis AFTER evidence
  is gathered, diverge judging across candidate frames.
- `max` — reserved: Strategic synthesis and irreversible one-shot verdicts only.
  NEVER a frontmatter default.

**Escalation direction rule:** when a task outgrows its tier, escalate the MODEL, not
the effort. Sonnet's effort cap is `high` — if a sonnet spawn seems to need `xhigh`,
it needs fable/opus (or Codex), not a longer sonnet run. Thinking tokens are output
tokens — the most quota-expensive thing a spawn emits.

## Fable — only the hardest thinking (founder directive 2026-07-03)

Fable (or the repo's top-tier pin) is allowed ONLY where genuinely novel reasoning or
judgment happens:

- Heavy/Strategic plan **synthesis** (not discovery — discovery is haiku/Explore)
- Diverge judge (scoring/clustering candidate frames)
- Safety-touched review **verdict** (not the scan — scans are Codex/sonnet/haiku)
- Root-cause **synthesis** after cheap models gathered the evidence

Fable is BANNED for: evidence gathering, file reads, bulk transforms, classification,
mechanical edits, commit messages, status aggregation, anything a checklist could do.

**Never hard-pin fable.** Always the chain `fable → opus → sonnet` (fable sunset risk;
opus is first-class for design/synthesis/verdicts). In workflows:
`model: MODELS.think || 'fable'` with opus fallback on refusal/absence.

## Zero-Claude-quota lanes come FIRST (founder: "GLM и Codex по максимуму")

Priority order for any spawn: **Codex → GLM → Claude ladder.** Both external lanes run
on separate subscription pools; every task routed there protects the Fable/Opus weekly
cap for the few spawns that truly need it.

| Lane | Carries | Effort control | Gate |
|---|---|---|---|
| Codex (gpt-5.5) | plan review, adversarial review, bug-hunt/root-cause, fitting dev tasks | `--effort medium\|high\|xhigh` on codex-task.sh | `codex-policy.yaml codex_enabled: true` |
| GLM-5.2 | background latency-class, bulk/mechanical transforms, standard code nobody waits on | prompt-level (no knob) | repo override (e.g. PE `extensions.md §Model routing v2`) |

Fallback ladders on lane failure: see `docs/model-routing.md §Codex quota EXHAUSTION`.
Surface every fallback to the founder — never degrade silently.

## Per-phase defaults (class × phase)

| Class | Plan | Build | Review |
|---|---|---|---|
| Trivial | skip | haiku `low` inline | skip |
| Light | sonnet `medium` single-pass | sonnet `medium` (GLM if background) | skip (low-risk) or Codex `medium` |
| Standard | architect sonnet `medium` + Codex `high` + critic sonnet `high` | sonnet `medium` / GLM bulk | Codex `high` + critic sonnet `high` |
| Heavy | architect fable→opus `xhigh` + Codex `xhigh` + critic sonnet `high` | sonnet `medium` parallel fan-out / GLM bulk | Codex `xhigh` + verdict fable→opus `xhigh` (safety) |
| Strategic | fable→opus `max` + Codex `xhigh` | as Heavy | as Heavy, verdict `max` |

## Anti-patterns (each one observed in production before this doc)

1. **`effort: max` in agent frontmatter** — makes EVERY direct Agent spawn burn max
   thinking regardless of class. Frontmatter default is `high` for adversarial roles,
   `medium` otherwise; workflows override per-class via `opts.effort`.
2. **Cranking effort instead of escalating model** — sonnet `xhigh` on a Heavy design
   task. Wrong axis: use fable/opus `xhigh`.
3. **Fable/opus for discovery** — evidence gathering is haiku; synthesis is fable.
4. **Haiku for verdicts** — a `low`-effort judge on a gate decision (acceptable only as
   an explicit degraded-mode fallback, logged as such).
5. **Ignoring the external lanes** — running sonnet review when Codex is available, or
   sonnet bulk transforms when GLM is available: burns Claude quota for nothing.

## Where this is enforced

- `agents/*.md` frontmatter — per-role defaults (this doc is the authority).
- `workflows/*.js` — per-class `effort:` pins on every `agent()` call.
- `commands/leadv2.md §Routing summary` — the table the lead sees at invocation.
- Per-repo `routing.yaml` — may add advisory `effort:` keys per step; router scripts
  pass them through untouched.

Benchmark sources (2026-07): benchlm.ai claude-sonnet-5-vs-glm-5-2, codingfleet.com
glm-5.2 comparison, semgrep.dev GLM-5.2 cyber benchmarks.
