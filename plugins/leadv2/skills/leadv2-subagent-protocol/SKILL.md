---
name: leadv2-subagent-protocol
description: "Operating rules for all /leadv2 subagents: handoff/off_limits discipline, ask-lead.sh graph proxy, <=50 word chat, DELIVERABLE_COMPLETE marker. Triggers: any subagent role in /leadv2 flow."
allowed-tools:
  - Read
  - Write
  - Edit
  - Bash
  - Glob
  - Grep
---

# Lead v2 Subagent Protocol

> **Hardest rule:** the LAST line of `<role>.full.md` MUST be the literal string `DELIVERABLE_COMPLETE` (or `DELIVERABLE_BLOCKED: <one-sentence-reason>` if you cannot finish). Without this exact marker on its own line, Lead treats your work as failed and re-spawns the same task. **This is the #1 cause of wasted re-spawns in this system.**

> **Hardest rule #2:** your FINAL assistant message returned to lead MUST be ONE LINE. Format: `DELIVERABLE_COMPLETE — see docs/handoff/<task-id>/<role>.full.md` (or `DELIVERABLE_BLOCKED: <reason>`). NO recap, NO summary table, NO "what I did", NO emoji headers. Lead reads the file. Audit shows 87% of subagents bloat parent context with multi-KB final messages — this is the #1 token leak. Violators waste 5-58KB of parent context per spawn.

> **Turn-cap (COST-LEVERS-01):** Hard limit — **30 tool calls per subagent run**. At call 30 without reaching Acceptance: write `DELIVERABLE_BLOCKED: turn-cap reached at <step>` and stop. Do NOT loop past 30 hoping it resolves. [lean: cap enforced by self-monitoring only — upgrade when workflow runtime exposes a hard stop hook]

> **Token-checkpoint (EFFICIENCY-TUNE-01):** After EVERY completed mission item (not every tool call) write ONE line to `docs/handoff/<task-id>/<role>.progress.log`: `<UTC-ts> item=<N> done=<what> next=<what>`. This is your resume anchor. Missions with >3 items and no progress.log by item 2 are a protocol violation.

## Mission-size cap & resume (EFFICIENCY-TUNE-01)
Missions with >6 file-touching items should be split at authoring time (lead's job). Mid-mission, past ~150K tokens (rule of thumb: >15 files Read OR >20 tool results): stop at the next clean item boundary, write progress.log, return `DELIVERABLE_BLOCKED: token-checkpoint — N/M items done`.
Lead-side (informational): on death or that marker, lead auto-resumes ONCE via a fresh subagent reading progress.log + context.yaml (never the dead transcript). If that also dies/blocks, lead spawns a fresh "finisher" with a NARROWED mission (remaining items only, re-stated) — never a 3rd blind resume of the same mission text.

> **Context-first (COST-LEVERS-01):** Lead pre-specifies files, paths, and facts in the mission. **Use the `## Graph context` block and explicit `Reads:` list as your first source — do NOT re-discover what is already injected.** Every re-discovery turn wastes ~2K tokens and compounds across all parallel subagents.

Rules for operating as a subagent inside a /leadv2 run. These apply whether you're spawned via `claude-subsession.sh` (isolated process) or via Agent tool (shared parent session).

## 1. Handoff discipline — contract, graph context, question proxy

Three things to internalize before your first tool call: the task's immutable handoff contract (1a), the graph context lead already injected for you (1b), and the escape hatch when you need more (1c — `ask-lead.sh`). Read all three once; don't re-derive them mid-task. If the repo root has a `CONTEXT.md`, read it; use its canonical terms and honor the _Avoid_ list.

### 1a. Handoff file contract — IMMUTABLE per task

**Before doing anything:** read `docs/handoff/<task-id>/context.yaml` (if it exists).

```yaml
decisions:      # locked — you MUST respect every D1..Dn
off_limits:     # do NOT touch anything in this list, ever
plan.steps:     # your mission is one of these — honor reads/writes
research:       # pointers to prior analysis
```

- `decisions` and `off_limits` are **append-only within a task**. Never rewrite them. If you need to change a decision → return to lead with "decision conflict" — do not work around.
- Read only files listed in your `plan.steps.reads:`. If you need more, see §1c (question proxy).
- Write your deliverable to `docs/handoff/<task-id>/<role>.summary.md` (≤50w) and `docs/handoff/<task-id>/<role>.full.md` (full analysis, DELIVERABLE_COMPLETE last line). See §5 for format. Lead reads the summary file first.

### 1b. Graph context injected — USE IT, don't re-discover

Mission file contains a `## Graph context` block pre-populated by lead from codebase-memory-mcp.

Graph queries are cheap when fresh — but DON'T re-issue queries already populated in mission's `## Graph context` block. That's your cache.

- Inside a `claude -p` headless subsession: **you do NOT have MCP access.** Do not attempt `search_graph` / `trace_path` / etc directly.
- Inside an Agent-tool subagent (shared parent session): MCP may be available if your agent frontmatter allows it (`tools: ... mcp__codebase-memory-mcp__*`). Use it normally.
- Either way: start from mission's Graph context. Only Grep config/JSON/migrations (where graph has no coverage).

### 1c. Question proxy — ask-lead.sh

When you need user input OR more graph info mid-task:

```bash
.claude/scripts/ask-lead.sh <task-id> "<question-text>" [--context "<extra>"] [--timeout <sec=300>]
```

- Default timeout 300s — if no answer, stdout will be `TIMEOUT`. Your response: log the timeout in your deliverable, proceed with your best assumption, explicitly state the assumption.
- **Graph proxy shortcut:** if your question starts with `graph:`, it is auto-proxied to MCP by lead — founder does not see it. Supported forms:
  - `graph: search_graph query="<text>"`
  - `graph: trace_path function_name="<symbol>"`
  - `graph: get_code_snippet qualified_name="<name>"`
  - `graph: get_architecture`
  - `graph: query_graph cypher="<Cypher>"`

Use `graph:` queries freely — they cost Claude tokens on lead side only, and they're silent to founder.

Use regular (non-graph) questions sparingly — each one interrupts founder. Batch where possible.

## 2.5-2.6. Nested spawns & escalation tokens

For nested sub-spawn rules (5-level hard cap, allowed models/subagent_types, the escalation-token procedure for a supervised out-of-allowlist spawn, and the background-spawn watchdog requirement) — see [NESTED-SPAWNS.md](./NESTED-SPAWNS.md). Read it before your first `Agent(...)` call from within this subagent; most subagent runs never need it.

## 4. Chat output discipline — SILENT by default

**DURING task (between tool calls): emit ZERO text.** No "Now I'll...", no "I found...", no "Let me check...". Call the tool, get the result, call the next tool. Every sentence you narrate mid-task compounds in lead's 200K context forever.

**Self-monitoring cap:** if you've made 30+ tool calls without reaching your Acceptance criteria, STOP. Write `DELIVERABLE_BLOCKED: stuck at <step> — <one sentence reason>` to your deliverable file and return that as your final message. Do not loop past 30 calls hoping it resolves.

**Final message to lead: ≤50 words.** PO/strategist: ≤30 words. Format:
```
<one-sentence verdict>. deliverable: docs/handoff/<id>/<role>.md. notable: <1 item if any>.
```

Full analysis, CHALLENGE blocks, diffs, findings → go to the deliverable file. Do NOT paste them in chat. If you paste >50 words in chat, it's a bug — truncate.

## 5. DELIVERABLE — two-file split (MANDATORY)

Write TWO files per deliverable:

1. `docs/handoff/<task-id>/<role>.summary.md` — ≤50 words overview. Must include:
   - First line: one-sentence outcome
   - 2-3 bullet key findings or changes
   - "Full: full.md" at the end if more detail exists

2. `docs/handoff/<task-id>/<role>.full.md` — full analysis, detailed diffs, reasoning. Last line MUST be:
   ```
   DELIVERABLE_COMPLETE
   ```

Lead reads `.summary.md` by default. Lead reads `.full.md` only when summary warrants deeper look (flagged issue, conflict, ambiguity).

**Backward compat:** a symlink `<role>.md -> <role>.full.md` is kept for one cycle for any existing callers. Do not create it yourself — the orchestrator maintains the symlink.

Lead uses `DELIVERABLE_COMPLETE` in `.full.md` to detect completion. Without it in the full file, lead treats your run as failed and re-spawns. Do not forget. (see top-of-file rule)

## 6. Mission-drift self-checks (MD patterns from lead-patterns.md)

Before claiming done, ask yourself:
- **MD-01:** Is my summary <200 words but mission was multi-step? If yes — re-expand in deliverable.
- **MD-02:** Does my deliverable reference the `decisions:` from context.yaml? If no — spec-drift risk, cite explicitly.
- **MD-03:** Did I just paste lead's prompt back? That's not work.
- **MD-04:** Does `git diff` (for code tasks) actually show the expected file changes? "Done" without diff = confabulation.
- **MD-05:** Did I rely on any table/flag/script/method name I never verified exists? Unverified entity → verify now (§6.5) or mark blocked.

Fail any self-check → fix before writing DELIVERABLE_COMPLETE.

## 6.5. Unrecognized-entity rule — verify before you build on it

Any identifier you are about to depend on that is NOT present in `context.yaml`, your mission file, or the `## Graph context` block — table name, column, env flag, script path, library method, API endpoint, persona slug — MUST be existence-verified BEFORE writing code or plans that use it. Partial recognition ("the concept is familiar") does NOT count as verification; versioned/renamed entities are exactly where memory is wrong.

One probe, ≤1 tool call:

- Code symbol / function → `graph: search_graph query="<name>"` (ask-lead proxy) or local Grep.
- File / script path → Glob the exact path.
- DB table / column → Grep migrations for `CREATE TABLE <name>` / the column name.
- Library method → verify against the installed package (e.g. `python3 -c "import x; print(hasattr(x.Y, 'z'))"`), never from memory.
- Env flag → Grep repo config / `.env.example`.

If the entity does not exist → STOP. Report `decision conflict` to lead or write `DELIVERABLE_BLOCKED: entity <name> not found`. **Never substitute a near-name, assume a rename, or invent a plausible variant.** Repeat incidents this rule exists for: querying persona tables by UUID where slug is canonical, calling library methods that drifted between versions, shipping shell that references a table never created.

## 6.6. Minimalism — write the least code that works

For build/dev roles (developer, frontend-developer, postgres-pro): the "skip it → stdlib → existing dep → minimal impl" ladder, what NEVER to simplify away, and the `# lean:` marker convention — see [MINIMALISM.md](./MINIMALISM.md). Review roles apply the same ladder adversarially when judging a diff.

## 7. Off-limits as hard stop

If you find yourself about to modify a path listed in `context.yaml.off_limits`:
1. STOP.
2. Call `ask-lead.sh <task-id> "off_limits conflict: <path> is listed off-limits but mission requires touching it. context: <why>"`.
3. Wait for founder's decision via lead.
4. Do NOT work around by editing a related file — that's still a violation.

## 8. Which files are safe to Read

- `docs/handoff/<task-id>/*` — all yours
- `docs/agents/<persona>/STATE.md,DIALOGUE.md,QUEUE.md` — read-only reference
- `docs/BOARD.md`, `docs/ROADMAP.md`, `docs/specs/*` — reference
- `.claude/ref/lead-patterns.md` — if you want to check CR/PS/MD patterns
- **Code files:** only those in your `plan.steps.reads:`. Don't scan code broadly.

## 9. Which files NEVER to Write

- Other subagents' deliverables (your role only — `<role>.md`)
- `context.yaml` (only lead writes this)
- `LEAD_V2_STATE.md` (only lead writes)
- Any persona STATE.md unless you ARE that persona (e.g., PO writes its own STATE.md, but architect doesn't)
- `.claude/skills/*/SKILL.md` — only `leadv2-skill-synthesize` creates these, not raw subagents

## 10. Lead reading discipline

The lead orchestrator (not the subagent) follows a separate set of context-hygiene rules when
consuming your deliverable — default to `.summary.md`, bounded `.full.md` reads, the 3-tier
read protocol, and handoff-file compression. Full detail: [LEAD-READING.md](./LEAD-READING.md).
Not subagent-facing, but useful if you need to predict what the lead will do with your output.

## Writable scope — $WRITE_ROOT

**Rule: write ONLY under the worktree root you were spawned in.** Never touch main-repo paths.

- Your writable prefix is the `cwd` you were spawned with (the worktree root). All file writes — code, configs, test fixtures — must resolve under that prefix.
- **State files are lead-owned.** `docs/leadv2/active.yaml`, `.claude/settings.json`, `LEAD_V2_STATE.md` — never write them. If you need to signal state back to lead, write to `docs/handoff/<task-id>/<role>.full.md` (your deliverable).
- **Main-repo paths are off-limits during worktree tasks.** If you find yourself writing to a path outside your worktree root (e.g., the main checkout under `/worktrees/../` parent), STOP — that is a guard violation. Signal via your deliverable instead.
- If you need lead to update a state file, say so in your deliverable: `LEAD_ACTION: update active.yaml field X to Y`.

## Rules

- **Trust context.yaml.** It's the single source of truth for this task.
- **Trust the Graph context block.** Don't re-discover what lead already queried.
- **Stay in lane.** Your role frontmatter defines your scope.
- **Finish with the marker.** Without `DELIVERABLE_COMPLETE`, you're not done.
- **Keep chat empty.** Final message = ONE LINE pointer. Lead reads files; multi-KB final summaries cost parent ~5-58KB context per spawn.
- **Lead obeys §10.** Reading discipline is part of the protocol, not optional.

## Anti-patterns

- Copying context.yaml contents into your deliverable (waste of tokens — lead has the file).
- Skipping the graph context block "because I want to verify myself" — lead's query IS the verification.
- Writing elaborate prose in chat summary to prove effort. Marker + pointer is enough.
- Asking founder "how should I do X?" when X is clearly an engineering decision (your role).
- **VPS SSH direct ops** — `ssh + git checkout`, `ssh + scp`, `ssh + git pull` bypassing `deploy-latest.sh`. V4 restore incident: one agent did `ssh + git checkout` on one VPS only, causing fleet drift and a prod incident. **VPS modifications ONLY via `deploy-latest.sh` (or `deploy.sh` in `.claude/leadv2-overrides/`).** If your deliverable mentions `ssh.*git checkout` or `ssh.*scp` to modify VPS code → BLOCK yourself and use ask-lead.sh. This is a Critical protocol violation.
- Ignoring MD-XX self-checks because "I'm sure it's fine". The checks are exactly when confidence is wrong.
- **Do exactly what was asked**: no drive-by refactors, no unrequested files; propose extras in one line, don't do them. State INTENT + acceptance criteria, not keystrokes — Sonnet 5 executes literally, so strip stale/contradictory constraints before spawn.
