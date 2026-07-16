---
name: leadv2-token-discipline
description: Enforce token-budget discipline in every /leadv2 phase — background-only Agent spawns, Read with offset/limit, Bash output pre-truncation, pulse-mode silence, MCP caching, and compact triggers. Apply when a session grows long, context cost spikes, a subagent deliverable risks flooding chat, or you are about to spawn agents / read files / emit Bash output. Always on; never skip.
allowed-tools:
  - Read
  - Bash
---

# leadv2-token-discipline — Keep Opus available, kill conversation bloat

## When: every /leadv2 phase. Always on.
## When NOT: never skip.

## The diagnosis (verified Apr 2026 from 30 recent sessions)

Founder uses Opus as lead and hits 1M daily cap fast. Switching lead to Sonnet causes "тупит" (Sonnet is genuinely worse at orchestration). So **keep Opus, fix the conversation length**.

What was eating tokens in real sessions:
- 28/30 recent sessions had **>100 turns**, 26/30 had **>200 turns**, worst = 2257 turns
- Each turn re-sends the growing conversation prefix; turn 1000 input ≈ 550K tokens
- **Foreground Agent spawns** dropped full subagent transcripts (30-100KB each) into chat
- Same files re-read 4-11x per session without offset/limit
- Bash output 5-11KB blobs without `head/tail` at source
- Zero `/compact` events — sessions just kept growing

This is **operational discipline**, not model switching.

## Hard rules

### 1. Lead is Opus, but ≤10 turns per task

`LEADV2_MAIN_MODEL=opus` (default since 2026-07-06 FABLE-RETIRE-01; fable sunset 2026-07-07). Same
turn budget applies to the top-tier lead — opus input/output pricing is well above sonnet. Burn
ladder on cost-ceiling breach: routing.yaml `downgrade_chain` (opus → sonnet → haiku); 24h burn
watch via `LEADV2_OPUS_BUDGET_24H` applies to the lead model. Phase budget:

| Phase pair | Turns |
|---|---|
| 0+1 (Intake + Research spawn) | 1 |
| 2+3 (Classify + Plan-triad spawn) | 1 |
| 4 (Gate-1 auto-accept) | 1 |
| 5+6 (Build + Test-synth) | 2 |
| 7+8 (Review + QA-gate) | 2 |
| 9+10 (PR-open + Async-wait) | 1 |
| 11 (Close) | 1 |
| Buffer | 1 |
| **Total Standard task** | **10** |

If you hit turn 30 in one task → something's wrong (founder asking too much follow-up, lead narrating, fix-rounds spinning). Force `/compact` at next phase boundary.

### 2. Subagent deliverables on disk, NOT in chat
- Every spawn: `run_in_background=true`. Lead receives task-notification (~100 words), not the body.
- Read deliverable with `Read limit=30` for header + summary_for_lead only.
- For review/critic deliverables: use `bash .claude/scripts/lv2 leadv2-critic-tail.sh <file>` — extracts Verdict + summary + severity counts (~50 lines vs ~500).
- Full read ONLY if Verdict says REVISE or no-ship.

### 3. No graph discovery in subagents
- Lead pre-warms graph queries in Phase 0/1 via `mcp__codebase-memory-mcp__*` and writes results to `tasks/<id>/graph-snapshot.yaml`.
- Subagents reference snapshot. They do NOT run their own search_graph/trace_path. This alone saves 30-40% on Standard+ tasks.

### 3b. When discovery IS needed — graph first
If a subagent hits an unrecognized entity (subagent-protocol §6.5) needing one probe: search_graph/trace_path/search_code BEFORE Grep/Read sweeps. Grep only config/JSON/migrations where the graph has zero coverage. Does not relax §3 — still no re-deriving what the lead's snapshot already answers.

### 4. Mission ≤100 lines, prompt ≤300 words
- `leadv2-mission-lint.sh` and `leadv2-prompt-lint.sh` enforce.
- Lead prompt orients (cwd, branch, deliverable, word cap). Subagent reads context.yaml + mission itself.

### 5. Read with `offset/limit` always for files >100 lines
- Never `Read` a 1000-line file without offset+limit.
- Never `cat | head/tail` via Bash — use `Read offset=X limit=Y`.

### 6. Pulse-mode silence
- Between phases: zero free-form chat text. Pulse log only (≤80 chars).
- This isn't politeness — it's that every chat sentence is in next-turn input forever.

### 7. No polling
- Never re-check task status in a loop. `task-notification` arrives automatically.
- `leadv2-resume.sh` is for explicit founder-triggered resume, not periodic re-check.

### 8. Cache MCP results within a task
- `bash .claude/scripts/lv2 leadv2-mcp-cache.sh warm <task-id>` at intake.
- Lead does graph queries once in Phase 0/1, caches via `set <key> <file>`. Phases 3/5/7 read via `get <key>`.

### 9. Heredocs don't enter chat-store
- For long subagent missions: write the file with Edit/Write, then the spawn prompt references the path. Don't cat-heredoc 100-line bodies in chat.
- **NEVER use `Bash(cat > path <<EOF ...EOF)` to create handoff/state/spec files.** Use `Write({file_path, content})` directly — Bash tool stores the FULL command text including the heredoc body, and that body lives in your transcript every future turn. OPS-DEPLOY-LATEST-DO-UPDATE-01 (Apr 29) had 4 bash heredocs at 5-9KB each = ~30KB transcript bloat from one task. Hook `~/.claude/hooks/leadv2-block-bash-heredoc.sh` blocks heredoc-bash inputs >2KB; override with `# bash-guard: allow` only when truly necessary.

### 10. Cost-estimate before Complex
- `bash .claude/scripts/lv2 leadv2-cost-estimate.sh --task-id <id>` runs before Plan-triad on Complex.
- If `within_cap: false` → propose 1-tier-down to founder via single AskUserQuestion.

## Watching the burn

- `bash .claude/scripts/lv2 leadv2-token-watch.sh` — shows 24h Opus consumption
- Threshold: if Opus 24h > 30M tokens → switch lead to Sonnet for next task
- Set `LEADV2_MAIN_MODEL=sonnet` in env to force

## Per-turn burn alert (L4)

V4 restore session burned 783K in one session (~25+ spawns, worst single agent 161K).
Self-monitoring rule: **if a single phase consumed >30K tokens (gauged by spawn count × estimated output), log a pulse warning and suppress the next non-critical spawn**.

Heuristics:
- 1 foreground Opus spawn ≈ 20-50K tokens in context forever
- 1 background Sonnet spawn ≈ 2-5K (task-notification only)
- 1 SSH probe with raw output, no filter ≈ 5-20K
- "Let me just check X too" investigative chain ≈ 30K per hop

When you notice the pattern: >3 spawns in one phase, >2 SSH raw reads, >5 sequential verify-probes → **hard stop, pulse flag `BURN_ALERT`, batch remaining queries into one probe**.

## 500K compact-prep trigger (L7)

When session reaches ~500K tokens (count by turns × estimated turn cost or by feeling that context is very long):
1. Write `docs/leadv2/tasks/<task-id>/pre-compact-resume.md` (5 lines: current phase, last 3 findings, next action) **even if not planning to /compact immediately**
2. Pulse: "500K threshold — pre-compact resume written"

Rationale: V4 session hit 783K without a resume artifact. A future /compact after that point would have lost state. Writing the artifact at 500K costs nothing; skipping it risks losing all context.

## Anti-patterns (forbidden)

- Lead reads full critic/review deliverable when verdict is OK
- Lead spawns Opus subagent for code-writing work (Sonnet does Build, Opus only architect/critic)
- Lead echoes subagent output back into chat ("here's what they found...")
- Lead repeats discovery (search_graph/trace_path) that already lives in graph-snapshot.yaml
- Subagent does its own graph discovery instead of reading injected snapshot
- Long heredoc prompts: `cat > /tmp/foo <<'EOF' (200 lines) EOF`
- TaskOutput on subagent stream files (full transcript overflow)

## Caching opt-in (1h prompt cache)

In `~/.claude/settings.json env`:
```json
"ENABLE_PROMPT_CACHING_1H": "1"
"MAX_MCP_OUTPUT_TOKENS": "15000"
```
Effective for Sonnet/Haiku via OAuth. Opus 1h cache via direct SDK requires `ANTHROPIC_API_KEY` (not OAuth subscription).

## Trade-off table

| Task class | Lead model default | Plan triad | Build subagent | Review |
|---|---|---|---|---|
| Trivial | sonnet | skip | sonnet (1) | skip |
| Light | sonnet | architect-sonnet only | sonnet (1) | reviewer-sonnet |
| Standard | sonnet | architect-opus + critic-opus | sonnet (per group) | critic-opus + reviewer-sonnet |
| Complex | sonnet (or opus if T1/T2/T6/T9) | architect-opus + critic-opus | sonnet | critic-opus + reviewer-sonnet + sec-auditor |

Total Opus calls per Standard task ≈ 2-3 (Plan + Review). NOT every phase. NOT lead.

## Workflow tool — model is per-`agent()`, no global default

When the lead authors a `Workflow` tool script (fan-out orchestration), the model-routing rule is **the same as for the Agent tool but multiplied by fan-out** — and there is **no settings.json default** for workflows. Every `agent()` with no `model:` opt inherits the **main-loop model**. An Opus lead authoring a bare-`agent()` workflow runs the whole fleet on Opus.

- **Rule: every `agent()` in a workflow script carries an explicit `model:`.** No exceptions. A bare `agent()` is a bug — same severity as forgetting `model=` on `Agent(Explore)`.
- Routing mirrors the §model-routing table: `model:'haiku'` for trace/read/discovery (pair with `agentType:'Explore'`), `model:'sonnet'` for write/verify/refute/synthesize, `model:'opus'` only for a single deep-reasoning step — never the whole fleet.
- Hoist the model into a `const` and pass it on every call; forgetting on one call silently routes that agent to Opus.
- `meta.phases[].model` is **display-only** (labels the progress group); it does NOT route. Routing is `opts.model` in the `agent()` call.
- Before launching: compute `agents = items × stages (+ synth)`. If that count on the inherited model is not what you intend, the `model:` opts are missing. (Incident 2026-05-31: a 13-subsystem × trace+verify pipeline shipped 27 Opus agents because no call set `model:`.)
- This applies in **all repos**. In m3-market, workflow agents must still carry `model:` (Claude tiers only — no Codex/gpt-5 routing inside scripts).
