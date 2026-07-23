---
name: leadv2-token-discipline
description: "[internal] Token discipline for every phase: bounded reads/output, compact handoffs, quiet pulses, cache telemetry, and capped spawns."
allowed-tools:
  - Read
  - Bash
---

# leadv2-token-discipline — Keep Opus available, kill conversation bloat

## When: every /leadv2 phase. Always on.
## When NOT: never skip.

See [REFERENCE.md](./REFERENCE.md) for diagnosis and trade-off table.

## Hard rules

### 1. Lead is Opus, but ≤10 turns per task

`LEADV2_MAIN_MODEL=opus`. Phase budget:

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

If you hit turn 30 in one task → force `/compact` at next phase boundary.

### 2. Subagent deliverables on disk, NOT in chat
- Every spawn: `run_in_background=true`. Lead receives task-notification (~100 words), not the body.
- Read deliverable with `Read limit=30` for header + summary_for_lead only.
- For review/critic deliverables: use `bash .claude/scripts/lv2 leadv2-critic-tail.sh <file>` — extracts Verdict + summary + severity counts.
- Full read ONLY if Verdict says REVISE or no-ship.

### 3. No graph discovery in subagents
- Lead pre-warms graph queries in Phase 0/1 via `mcp__codebase-memory-mcp__*` and writes results to `tasks/<id>/graph-snapshot.yaml`.
- Subagents reference snapshot. They do NOT run their own search_graph/trace_path.

### 3b. When discovery IS needed — graph first
If a subagent hits an unrecognized entity needing one probe: search_graph/trace_path/search_code BEFORE Grep/Read sweeps.

### 4. Mission ≤100 lines, prompt ≤300 words
- `leadv2-mission-lint.sh` and `leadv2-prompt-lint.sh` enforce.
- Lead prompt orients (cwd, branch, deliverable, word cap). Subagent reads context.yaml + mission itself.

### 5. Read with `offset/limit` always for files >100 lines
- Never `Read` a 1000-line file without offset+limit.
- Never `cat | head/tail` via Bash — use `Read offset=X limit=Y`.

### 6. Pulse-mode silence
- Between phases: zero free-form chat text. Pulse log only (≤80 chars).

### 7. No polling
- Never re-check task status in a loop. `task-notification` arrives automatically.
- `leadv2-resume.sh` is for explicit founder-triggered resume, not periodic re-check.

### 8. Cache MCP results within a task
- `bash .claude/scripts/lv2 leadv2-mcp-cache.sh warm <task-id>` at intake.
- Lead does graph queries once in Phase 0/1, caches via `set <key> <file>`. Phases 3/5/7 read via `get <key>`.

### 9. Heredocs don't enter chat-store
- For long subagent missions: write the file with Edit/Write, then reference the path.
- **NEVER use `Bash(cat > path <<EOF ...EOF)` to create handoff files.** Use `Write({file_path, content})` directly.
- Hook `~/.claude/hooks/leadv2-block-bash-heredoc.sh` blocks heredoc-bash inputs >2KB; override with `# bash-guard: allow` only when necessary.

### 10. Cost-estimate before Complex
- `bash .claude/scripts/lv2 leadv2-cost-estimate.sh --task-id <id>` runs before Plan-triad on Complex.
- If `within_cap: false` → propose 1-tier-down to founder via AskUserQuestion.

## Watching the burn

- `bash .claude/scripts/lv2 leadv2-token-watch.sh` — shows 24h Opus consumption
- Threshold: if Opus 24h > 30M tokens → switch lead to Sonnet for next task
- Set `LEADV2_MAIN_MODEL=sonnet` in env to force

## Per-turn burn alert

**If a single phase consumed >30K tokens (gauged by spawn count × estimated output):**
- Log a pulse warning
- Suppress the next non-critical spawn

Heuristics:
- 1 foreground Opus spawn ≈ 20-50K tokens in context forever
- 1 background Sonnet spawn ≈ 2-5K (task-notification only)
- 1 SSH probe with raw output, no filter ≈ 5-20K
- "Let me just check X too" investigative chain ≈ 30K per hop

When you notice: >3 spawns in one phase, >2 SSH raw reads, >5 sequential verify-probes → **hard stop, pulse flag `BURN_ALERT`, batch remaining queries into one probe**.

## 500K compact-prep trigger

When session reaches ~500K tokens:
1. Write `docs/leadv2/tasks/<task-id>/pre-compact-resume.md` (5 lines: current phase, last 3 findings, next action) **even if not planning to /compact immediately**
2. Pulse: "500K threshold — pre-compact resume written"

## Anti-patterns (forbidden)

- Lead reads full critic/review deliverable when verdict is OK
- Lead spawns Opus subagent for code-writing work (Sonnet does Build, Opus only architect/critic)
- Lead echoes subagent output back into chat
- Lead repeats discovery (search_graph/trace_path) that already lives in graph-snapshot.yaml
- Subagent does its own graph discovery instead of reading injected snapshot
- Long heredoc prompts: `cat > /tmp/foo <<'EOF' (200 lines) EOF`
- TaskOutput on subagent stream files

## Prompt caching

Claude Code manages prompt caching automatically. Subscription sessions receive one-hour TTL automatically; API-key and third-party providers use their configured TTL and may opt into one hour with `ENABLE_PROMPT_CACHING_1H=1`.

Keep `MAX_MCP_OUTPUT_TOKENS=15000` if your environment supports it, and avoid mid-session model or MCP-set changes because they invalidate the cache prefix.

## Workflow tool routing

Every `agent()` in a workflow script carries an explicit `model:`. No exceptions. See [EXAMPLES.md](./EXAMPLES.md) for detailed routing patterns and incident examples.
