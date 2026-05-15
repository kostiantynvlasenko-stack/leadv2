# Architecture

## Mental model

The lead is a **router**, not a thinker. It owns:

1. **State** — which phase, what's been decided, what's in flight
2. **Routing** — which model spawns next, with what context
3. **Gates** — the single Gate 1 (plan approval) and automated downstream gates (review verdict, verify-probe)
4. **Memory** — append corrections to immune memory, pre-filter future plans

It never writes application code itself. Every meaningful decision is delegated to a specialist via the `Agent` tool.

## Phases

```
Phase 0  Intake          Read task → classify → check immune memory for similar prior tasks
Phase 1  History primer  Pull top-3 similar past tasks; surface their failure modes
Phase 2  Plan            Spawn architect (Opus) + critic (Opus) in parallel; optional Codex 2nd brain
                         → synthesize into plan.steps, off_limits, decisions
                         → present to user at GATE 1
Phase 3  Premortem       Probability table: build success, deploy success, rollback risk
Phase 4  Build           Spawn parallel developer/frontend-developer/postgres-pro/devops-engineer
                         subagents per plan.parallel_groups
Phase 5  Review          Spawn critic primary + optional Codex + security-auditor (if auth/secrets/RLS touched)
                         Max 2 review rounds, then architect escape if still disputed
Phase 6  Deploy          Execute .claude/leadv2-overrides/deploy.sh with LEAD_V2_TASK_ID
Phase 7  Verify          Execute .claude/leadv2-overrides/verify.sh; parse exit code
                         0 = pass → Phase 8
                         1 = timeout → leadv2-recovery (max 2 attempts)
                         2 = negative signal → immediate rollback + recovery
Phase 8  Close           Cost summary, lead-reflect entry, propose next task from queue
```

## Model routing

| Role | Model | Spawn mechanism | When |
|---|---|---|---|
| Main lead (you) | Sonnet | — | Always |
| architect | Opus | `Agent(subagent_type=architect, model=opus)` | Phase 2 (Heavy/arch); Phase 7 recovery alt |
| critic | Opus | `Agent(subagent_type=critic, model=opus)` | Phase 2 Stage 2; Phase 5 Review |
| developer | Sonnet | `Agent(subagent_type=developer, model=sonnet)` | Phase 4 Build |
| frontend-developer | Sonnet | `Agent(subagent_type=frontend-developer, model=sonnet)` | Phase 4 Build (UI tasks) |
| postgres-pro | Sonnet | `Agent(subagent_type=postgres-pro, model=sonnet)` | Phase 4 Build (DB tasks) |
| devops-engineer | Sonnet | `Agent(subagent_type=devops-engineer, model=sonnet)` | Phase 4 Build (infra tasks) |
| security-auditor | Sonnet | `Agent(subagent_type=security-auditor, model=sonnet)` | Phase 5 (auth/secrets/RLS touched) |
| Explore | Haiku | `Agent(subagent_type=Explore, model=haiku)` | Pre-Plan graph discovery |
| Codex (2nd brain) | gpt-5.5 high/xhigh | `leadv2-codex-planner.sh` / `codex-task.sh` | Phase 2 + Phase 5 — optional, requires `codex_enabled: true` |

**Why Sonnet main, Opus on triggers:** Opus is expensive per-token but stronger at architectural reasoning. Sonnet is cheaper and faster for routing/coordination. The lead routes; Opus thinks.

## One-gate philosophy

You pause at **exactly one gate** — initial plan approval. Everything after that is automated, gated by automated checks (tests, review verdict, security audit, verify-probe) with a circuit breaker.

Why one gate, not many:

1. **More gates ≠ safer.** Each gate is a context switch for you. By the time you've approved 5 things, you're rubber-stamping.
2. **The downstream gates already exist** — they're just automated (review verdict, security audit pass/fail, verify-probe exit code). The lead respects them.
3. **Circuit breaker:** if Verify fails twice, escalate to user with full context. The floor is "rollback + escalate", not "shipped broken".

You can re-enter the loop any time. Type into the chat and the lead stops, processes your input, and routes accordingly.

## Subagent protocol

Every subagent:

1. Receives a tight prompt with: task summary, plan context, off-limits files, expected deliverable, word/finding limit
2. Writes its deliverable to `docs/handoff/<task_id>/<phase>-<role>-output.{yaml,md}`
3. Never reads files outside its mission scope (token discipline)
4. Reports back to lead with a structured summary and `DELIVERABLE_COMPLETE` marker

Subagents don't talk to each other. They report to the lead, lead synthesizes, lead routes next.

## State files

Per-task state lives at:

```
docs/leadv2/tasks/<task-id>/
├── STATE.md          # current phase, last decision, owner
├── pulse.md          # append-only event log
├── context.yaml      # plan, decisions, off_limits
└── handoff/
    ├── plan-architect-output.md
    ├── plan-critic-output.md
    ├── plan-codex-output.md      (if codex_enabled)
    ├── build-developer-output.md
    └── ...
```

Global state:
- `docs/LEAD_V2_STATE.md` — active sessions, recent history
- `docs/leadv2/tasks.yaml` — task queue (top-of-list = next)
- `docs/leadv2/immune-memory/` — past corrections + failure modes

## Token discipline

Plugin hooks enforce:

- `Read` over 100 lines requires `offset/limit` (override env: `LEADV2_ALLOW_FULL_READ=1` per turn)
- Heredocs in `Bash` (`<<EOF`) blocked — use file references instead
- `TaskOutput` blocked on codex/glm jobs — read output files directly
- Duplicate reads of the same file are dropped
- Lead is blocked from `Edit/Write` on `.py/.sh/.ts/.tsx/.sql` files — must delegate
- Bash output is capped at 25K tokens per call

These hooks are active only in the lead's main context. Subagents run in their own contexts and aren't subject to the same restrictions.

## Memory model

Two memories:

1. **Project memory** (in your repo, source-controlled): `docs/leadv2/immune-memory/`, `docs/leadv2/tasks.yaml`, history. Sharable across team.

2. **Lead's working memory** (per-session, in Claude context): current phase, last 3 findings, plan steps. Re-injected after `/compact` via `pre-compact-resume.md`.

## Recovery loop

If Phase 7 Verify fails:

1. **Iteration 1** — lead reads probe output, classifies failure (timeout vs negative signal), spawns recovery skill with full context
2. **Iteration 2** — if still failing, architect proposes an alt-approach (different fix strategy)
3. **Iteration 3** — escalate to user with: original plan, what we tried, what failed, what architect suggests next

Hard cap 5 recovery iterations before forced escalation. Configurable via `extensions.md`.

## Subsessions (advanced)

For very long contexts (e.g. agent meetings, persona-specific work), the lead can spawn a `claude-subsession` — a child Claude process that gets its own context window and reports back a final summary. Costs more but enables 100+ turn deep dives without pollluting the lead's main context.

Spawned via `leadv2-claude-subsession.sh`. Use sparingly.

## What's NOT in this plugin

- A web UI / dashboard (CLI only)
- A persistent server (it's all Claude Code subagents)
- Hosted memory (your project memory lives in your repo)
- A scheduler (Codex's MCP scheduling tools handle that)
- Built-in deploy logic (you write `deploy.sh`)
