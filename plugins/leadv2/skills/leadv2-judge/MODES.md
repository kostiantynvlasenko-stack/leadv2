# Mode-specific reads and output schemas

Each mode (`review`, `question`, `recovery`) has specific allowed reads and a defined output schema. Reference this file when implementing or debugging a judge invocation.

## Mode: review

**Reads (allowed):**
- `docs/handoff/<task-id>/critic.summary.md` + `.full.md` if ambiguous
- `docs/handoff/<task-id>/codex.summary.md` + `.full.md` if ambiguous
- `docs/handoff/<task-id>/sec-auditor.summary.md` (if exists)
- `docs/handoff/<task-id>/build.summary.md`
- `docs/handoff/<task-id>/context.yaml`

NOT allowed: raw code, server logs, MCP graph queries.

**Output:**

```yaml
mode: review
verdict: APPROVE | REVISE | ABORT
confidence: 0.0-1.0
one_liner: "≤25 words for lead to quote"
reasoning: "≤100 words"
blocking_issues: []   # critical/high only; empty if APPROVE
revise_targets: []    # files to revise if REVISE
suggested_action: "spawn_developer_round_2 | propose_gate2 | escalate_to_founder"
```

---

## Mode: question

**Reads (allowed):**
- `docs/handoff/<task-id>/context.yaml`
- `docs/handoff/<task-id>/*.summary.md`
- `docs/handoff/<task-id>/*.full.md` ONLY if summary is ambiguous on the asked dimension
- `BOARD.md` recent rows for "правильно ли" questions
- `lead-patterns.md` for historical priors

NOT allowed without explicit founder OK: raw code, server logs, supabase queries.

**Output:**

```yaml
mode: question
verdict: GO | NO_GO | CONDITIONAL | INSUFFICIENT_INFO
confidence: 0.0-1.0
one_liner: "≤25 words — what to tell founder verbatim"
reasoning: "≤120 words — why this verdict, what evidence"
caveats: []           # ≤5 short bullets
suggested_action: "what lead should do next, ≤15 words"
```

---

## Mode: recovery

**Reads (allowed):**
- `docs/handoff/<task-id>/recovery.log`
- `docs/handoff/<task-id>/<failed-phase>.summary.md` + `.full.md`
- `docs/handoff/<task-id>/context.yaml`
- `docs/leadv2-negative-memory.yaml`
- `lead-patterns.md`

NOT allowed: raw code, server logs without grep filter.

**Output:**

```yaml
mode: recovery
verdict: RETRY_SAME | RETRY_ALT_APPROACH | ESCALATE_TO_FOUNDER | ABORT_TASK
confidence: 0.0-1.0
one_liner: "≤25 words for lead to quote"
reasoning: "≤100 words"
retry_modification: "what to change for next attempt, ≤30 words"  # if RETRY_*
escalation_question: "what to ask founder, single sentence"        # if ESCALATE_*
suggested_action: "spawn_developer_retry | spawn_architect_alt | propose_escalation | mark_aborted"
```
