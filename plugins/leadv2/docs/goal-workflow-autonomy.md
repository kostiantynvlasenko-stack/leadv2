# Goal & Workflow — orchestrator self-judgment rubric

**Purpose.** The orchestrator decides **on its own** when to fire `/goal` and when to author a
`Workflow` — the founder should not have to request them each time. Fire them **only** when the
rubric below matches: over-firing wastes tokens, under-firing wastes the founder's prompts.

This is the layer on top of the existing flag-gated mechanics (`LEADV2_DAEMON` for `/goal`,
`LEADV2_WORKFLOW_ENABLED` for the Plan/Review fan-out paths). The flags still exist; this doc says
**when the orchestrator flips them itself.**

---

## `/goal` — autonomous multi-turn completion loop

**What it is.** `/goal "<condition>"` sets a completion condition; a Haiku evaluator checks after
every turn and keeps the orchestrator working until the condition holds or a turn cap trips. One
goal per session; survives compaction via `leadv2-postcompact-goal-reinject.sh`. Real built-in slash
command since Claude Code v2.1.139 (we run ≥2.1.158); it is an in-REPL command, so it never appears
in `claude --help`.

**FIRE when ALL hold:**
- The task spans many turns AND there is real risk of returning to the founder / stalling mid-flow
  before it is actually done.
- The done-state is machine-checkable **from the orchestrator's own output**: a flag file exists,
  `git status` clean, tests exit 0, a queue empty, a count reached. (The evaluator does **not** run
  commands or read files — the condition must be provable from what the orchestrator surfaces.)
- A turn cap is **always** included: `..., or stop after N turns`.

**Canonical leadv2 use.** After Gate 1:
`/goal docs/handoff/$LEADV2_TASK_ID/phase8-passed.flag exists, or stop after 140 turns`.
Daemon mode sets this automatically. **Interactive mode — the orchestrator MAY self-set the same
goal for any Standard+/Heavy task it judges at stall-risk, without asking the founder.**

**DO NOT fire:**
- Phase 7 verify — `verify-probe.sh` (sleeping bash) is strictly cheaper than a per-turn evaluator
  (see `docs/leadv2/research/2026-05-21-goal-pilot-verify.md`). This is a verify-only exclusion.
- Trivial/Light or ≤3-turn tasks — overhead > benefit.
- When the done-state can't be proven from output ("looks good", "UX is nice", "should work").

---

## `Workflow` — deterministic multi-agent fan-out

**What it is.** A JS script the orchestrator authors that spawns/sequences subagents
deterministically (`parallel()` / `pipeline()`), each `agent()` carrying an explicit `model:`.
Returns structured results; the subagents' work stays out of the lead's context.

**FIRE when ANY hold:**
- The session contains **≥2 independent tasks** that can run in parallel (parallel Workflow phases
  instead of serial Agent spawns — serial multi-task spawns proved ~2× slower). Per-phase the old
  ≥4-unit bar still applies for pure fan-out within a single phase; but at session level ≥2 is enough.
- The work decomposes into **≥4 independent units** within a single phase runnable in parallel
  (multi-area/multi-file audit, codebase-wide sweep, N-candidate design panel, per-item migration).
- Confidence needs **independent perspectives**: adversarial verify (N skeptics per finding),
  judge panel, perspective-diverse review.
- Scale **exceeds one context**: broad review/research/migration one transcript can't hold.

**Opt-in.** Invoking `/leadv2` on a qualifying task **is** the Workflow opt-in (the role instructs
it) — no separate founder "use a workflow" request is needed. The flag-gated paths are Phase 2 Plan
and Phase 5 Review: the orchestrator MAY self-set `LEADV2_WORKFLOW_ENABLED=1` for the session when a
Plan/Review meets the fan-out test above.

**DO NOT fire:**
- Linear single-file work or anything one `Agent` / one direct edit handles.
- When you can't name the independent units up front — **scout inline first** (list the files / find
  the sites / scope the diff), then fan out over the discovered work-list.

**Cost discipline (non-negotiable):**
- Every `agent()` carries an explicit `model:` — `haiku` for reads/scans/discovery, `sonnet` for
  synthesis/judgment, `opus` only when genuinely needed. A bare `agent()` runs the whole fleet on the
  lead's model (see `leadv2-token-discipline` SKILL §Workflow). Applies in all repos; in m3-market,
  Claude tiers only — no Codex/gpt-5 routing inside scripts.
- Prefer `pipeline()` over `parallel()` barriers unless a stage genuinely needs all prior results
  (dedup / merge / early-exit-on-zero).
- Read only the workflow's returned summary — never tail subagent transcripts.

---

## Combining the two

`/goal` keeps the **whole pipeline** self-driving to a checkable end; a `Workflow` is **one
well-scoped fan-out within a phase.** They compose: set a `/goal` for the task, author `Workflow`s
for the phases that genuinely fan out.

**Worked example (2026-05-31).** Hotspot discovery for `/simplify`: one `Workflow` fanned 8 `haiku`
scanners across code areas + 1 `sonnet` ranker → top simplify candidates; then a `developer` applied
the #1 and `/simplify` polished the diff. The founder asked once; the orchestrator chose the workflow
shape, the models, and the apply target itself. That is the target behavior of this rubric.
