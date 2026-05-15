---
name: leadv2-subagent-protocol
description: Operating rules for all /leadv2 subagents: handoff/off_limits discipline, ask-lead.sh graph proxy, <=50 word chat, DELIVERABLE_COMPLETE marker. Triggers: any subagent role in /leadv2 flow.
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

Rules for operating as a subagent inside a /leadv2 run. These apply whether you're spawned via `claude-subsession.sh` (isolated process) or via Agent tool (shared parent session).

## 1. Handoff file contract — IMMUTABLE per task

**Before doing anything:** read `docs/handoff/<task-id>/context.yaml` (if it exists).

```yaml
decisions:      # locked — you MUST respect every D1..Dn
off_limits:     # do NOT touch anything in this list, ever
plan.steps:     # your mission is one of these — honor reads/writes
research:       # pointers to prior analysis
```

- `decisions` and `off_limits` are **append-only within a task**. Never rewrite them. If you need to change a decision → return to lead with "decision conflict" — do not work around.
- Read only files listed in your `plan.steps.reads:`. If you need more, see §3 (question proxy).
- Write your deliverable to `docs/handoff/<task-id>/<role>.summary.md` (≤50w) and `docs/handoff/<task-id>/<role>.full.md` (full analysis, DELIVERABLE_COMPLETE last line). See §5 for format. Lead reads the summary file first.

## 2. Graph context injected — USE IT, don't re-discover

Mission file contains a `## Graph context` block pre-populated by lead from codebase-memory-mcp.

Graph queries are cheap when fresh — but DON'T re-issue queries already populated in mission's `## Graph context` block. That's your cache.

- Inside a `claude -p` headless subsession: **you do NOT have MCP access.** Do not attempt `search_graph` / `trace_path` / etc directly.
- Inside an Agent-tool subagent (shared parent session): MCP may be available if your agent frontmatter allows it (`tools: ... mcp__codebase-memory-mcp__*`). Use it normally.
- Either way: start from mission's Graph context. Only Grep config/JSON/migrations (where graph has no coverage).

## 3. Question proxy — ask-lead.sh

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

Fail any self-check → fix before writing DELIVERABLE_COMPLETE.

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

## 10. Lead reading discipline — context-hygiene rules for the orchestrator

These rules apply to the **lead** (Sonnet/Opus orchestrator chat), not the subagent. They exist because each turn re-sends the entire lead history; any KB read into chat compounds per turn until compaction kicks in.

**Hard rules for lead when consuming subagent output:**

1. **Default = read `.summary.md` only, with `Read offset=0 limit=30`.** Never read full deliverables in chat unless the summary flagged a conflict, ambiguity, or block.
2. **`.full.md` reads are bounded.** If you must inspect the full deliverable, use `Read offset=0 limit=30` first (header + DELIVERABLE_COMPLETE check). Read the body only if the header doesn't answer your question.
3. **Mission/prompt files: write to disk via Write, never inline-paste in chat.** Templates live at `~/.claude/prompts/leadv2-<role>.md`. Spawn scripts read them by path. The body never enters lead transcript.
4. **SSH / journal / log output: filter at source.** Never `journalctl ...` raw — always pipe through `grep -E '<signal>'` and `tail -50` or `head -50` on the remote side. Use `~/.claude/scripts/ssh-grep.sh <host> <unit> <pattern>` (see helper).
5. **Bash output that exceeds 100 lines: pre-truncate at the source command.** Never `cmd | head -50` from lead — always `cmd --limit 50` or remote `head/tail/grep` flags.
6. **No polling.** Never re-check `git status` between edits, never `wc -c` background output files, never `codex-task.sh status`. Wait for `<task-notification>` and read the deliverable.
7. **Effort routing:** spawn `--effort max` only when classification is Heavy or Strategic. Standard/Light → `--effort high`. Trivial → no subsession (use Agent tool).
8. **Pre-compute heavy data outside subagents.** If a subagent needs aggregates (action_log fingerprint, follower deltas, action counts), compute in bash via `sb_get` + `jq` and embed the *result* in the mission file. Don't make Opus burn 30k tokens reading 200 raw rows.
9. **Don't re-paraphrase deliverables to founder.** If founder asks "what did architect say?", quote the `.summary.md` (≤50 words) directly — don't re-narrate.

**Failure modes this prevents:**
- Reading 226-line architect-design.md fully into lead → ~30k tokens × every subsequent turn until compaction.
- 9 hours of `journalctl` output dumped raw → tens of KB stuck in lead history.
- Writing PO/architect mission files via Write inline → mission body lives in transcript forever.

When you violate one of these, save a `feedback` memory the same turn so the next session learns. Don't just apologize — document.

## 3-tier read protocol (jcode-inspired)

Lead reads subagent output at three explicit tiers — never the full file by default. This is mandatory; deliverable-format below MUST support all three.

| Tier | What | When | How |
|---|---|---|---|
| **Status snapshot** | Lifecycle event only — task-notification | Always | Auto: spawn returns `task-notification` with output path; lead does NOT Read yet |
| **Summary read** | Verdict + summary_for_lead + severity counts | Default after notification | `bash .claude/scripts/critic-tail.sh <file>` OR `Read limit=10` |
| **Full context read** | Whole deliverable | ONLY when summary signals REVISE / no-ship / NEEDS-INFO | `Read offset=X limit=Y` — never unbounded |

**Subagent obligations:**
- First line: `Verdict: APPROVE | REVISE | NEEDS-INFO | BLOCK`
- Second line: `summary_for_lead: <≤30 words>`
- Severity-tagged findings use predictable labels (`critical:`, `c1:`, `severity: critical`, etc.) so `critic-tail.sh` can count them.
- Last line literally: `DELIVERABLE_COMPLETE`

**Lead obligations:**
- After task-notification: `bash .claude/scripts/critic-tail.sh <file>` for review-class deliverables, `Read limit=10` for build-class.
- Full read ONLY when tier-2 signals action required.
- Never `TaskOutput` a subsession stream file — overflow risk.

## Handoff-file compression (M5)

Subagent produces `<role>.summary.md` (≤50 words for chat) + `<role>.full.md` (full content, ends with `DELIVERABLE_COMPLETE`). Lead may automatically emit `<role>.compressed.md` after detecting `DELIVERABLE_COMPLETE` — **do not generate the compressed file yourself**. The compression runs on the lead side via `leadv2_compress_handoff` and is transparent to the subagent.

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
