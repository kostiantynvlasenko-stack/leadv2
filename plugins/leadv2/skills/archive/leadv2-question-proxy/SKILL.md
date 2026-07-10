---
name: leadv2-question-proxy
description: "[DORMANT — zero production firings as of 2026-07-03; e2e-test before relying on it] [internal] Use during any phase with an active claude-subsession.sh in flight (Phase 2/4/5/7): IPC bridge where a subagent writes its question to docs/handoff/<task-id>/questions/, a Monitor watches the _signal file, and lead proxies the question to the founder via AskUserQuestion (or silently auto-resolves graph: queries via MCP). Not for use when no subsessions are active."
allowed-tools:
  - Read
  - Write
  - Bash
  - Grep
  - Glob
---

# Lead v2 Question Proxy

> **ARCHIVED 2026-07-10 (PROMPT-HYGIENE-01 #6).** Moved here because it never fired in production (0 firings as of 2026-07-03). Kept as a fallback reference, not auto-discovered from `skills/archive/`. Restore to `skills/` and e2e-test before relying on it again.

## When: any phase during active subsessions. When NOT: no subsessions active.

## Setup — monitor at subsession start

At Phase 2 / Phase 4 / Phase 5 / Phase 7 when at least one `claude-subsession.sh` is in flight, start a persistent Monitor:

```
Monitor(
  command: while true; do
    for sig in docs/handoff/*/questions/_signal; do
      [[ -f "$sig" ]] && {
        task_id=$(echo "$sig" | awk -F/ '{print $(NF-2)}')
        echo "QUESTION_PENDING:$task_id"
        rm -f "$sig"
      }
    done
    sleep 5
  done
  description: "subagent question mailbox"
  persistent: true
  timeout_ms: 3600000
)
```

## Protocol on notification

### 0. Check for `graph:` prefix — auto-proxy to MCP (no founder prompt)

Read the pending YAML `question:` field. If it starts with `graph:` — this is a subagent asking for MCP output. Lead handles silently:

**Supported forms:**
- `graph: search_graph query="<text>" [limit=N]`
- `graph: trace_path function_name="<symbol>" [depth=N]`
- `graph: get_code_snippet qualified_name="<name>"`
- `graph: get_architecture`
- `graph: query_graph cypher="<Cypher>"`

**Action:** parse → call `mcp__codebase-memory-mcp__<tool>` with `project="${LEADV2_CODEBASE_PROJECT}"` → write the JSON/text output into `<qid>-answered.yaml` as `answer:` field → done.

**Do NOT use AskUserQuestion** for `graph:` questions. Founder shouldn't see these — they're subagent infrastructure.

### 1. Identify latest pending question (non-graph)

```bash
ls -t docs/handoff/<task-id>/questions/*-pending.yaml 2>/dev/null | head -1
```

Read the YAML:
```yaml
qid: q-1745500000-12345
question: |
  Should we add an index on foo.bar?
context: |
  Current query scans 100k rows per request, plan says add index but I'm not sure on which field.
who: architect
asked_at: 2026-04-24T14:32:00Z
```

### 2. Check for batching — are there multiple pending?

```bash
count=$(ls docs/handoff/<task-id>/questions/*-pending.yaml 2>/dev/null | wc -l)
```

- count == 1 → proceed with single AskUserQuestion
- count 2-3 → batch into single AskUserQuestion (multiSelect or sequential)
- count >3 → first three only, defer rest

### 3. Prompt founder

Use AskUserQuestion tool. Format:

```
question: "[subagent: <who>] <question text>"
header: "Вопрос от <who>"
options:
  # 2-4 options inferred from context, OR free-form "Other"
```

If the subagent question is truly open (e.g., "which field should I index?"), use two-option framing:
```
- label: "Вариант A: <most likely>"
  description: "<rationale, 1 sentence>"
- label: "Вариант B: <alternative>"
  description: "..."
```

Let "Other" capture anything else.

### 3b. Write lock file immediately on receiving signal (PO-062)

Before prompting founder (step 3), write an empty lock file to signal "answer in progress":

```bash
touch docs/handoff/<task-id>/questions/<qid>-answer.lock
```

This prevents the subagent from timing out during long founder deliberation. Subagent polls for the lock and extends its wait window once it appears. Write the lock for EVERY question (graph-proxy or founder-directed) immediately after reading `_signal`.

### 4. Write answer back

For each pending question, write `<qid>-answered.yaml`:

```yaml
answer: |
  <founder's selection OR Other text>
answered_at: 2026-04-24T14:35:00Z
by: founder
```

Subagent poll will pick it up within 5s.

### 5. Follow-up questions

Subagent may ask follow-ups. Same mailbox pattern. Monitor continues running.

### 6. Cleanup at subsession exit

When all subsessions for a task exit:
- Keep `questions/` dir for handoff archive (Close phase 7 archives everything)
- Kill Monitor via TaskStop

## Timeout handling

If subagent writes question but lead is busy with another Monitor task:
- Subagent side: `ask-lead.sh` timeout default **30 min** (1800s). If lead writes `<qid>-answer.lock`, the deadline is extended by another 30 min (one extension total). Only then does subagent write "TIMEOUT — proceeded with assumption X".
- Lead side: write `<qid>-answer.lock` immediately on receiving `_signal` (step 3b). On late notification, write answer anyway — subagent can still pick it up if within extended window.
- Log all timeouts to `docs/handoff/<task-id>/questions/timeouts.log`

## Rules

- **Batch questions when possible.** Flooding founder = bad UX.
- **Always use AskUserQuestion, never raw chat text.** Structured answers > free-form.
- **Never proxy a question the founder can't answer in <30 sec.** If architect asks "which of 5 migration strategies" — lead should synthesize and ask as 2-3 options.
- **Questions from multiple subagents in parallel** — process FIFO by `asked_at` timestamp.
- **Subagent identity in question header** — founder knows who's asking.

## Anti-patterns

- Proxying verbatim subagent question with 200+ words of context — condense to essentials.
- Leaving `_signal` file after processing — next poll will re-fire.
- Answering subagent question yourself from memory — if it needs founder, don't substitute.
- Forgetting to write `<qid>-answered.yaml` — subagent hangs 10 min then timeouts.
