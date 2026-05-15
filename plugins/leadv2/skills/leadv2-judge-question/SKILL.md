---
name: leadv2-judge-question
description: "[internal] Opus judge for founder judgment questions during an active /leadv2 task."
allowed-tools:
  - Read
  - Bash
model: opus
---

> DEPRECATED 2026-05-04: prefer leadv2-judge --mode question. Migration: PO-063.

# /leadv2 Judge — Founder Question

## When

Lead's `leadv2-founder-question-classify.sh` returned `judgment`. Founder asked something like:
- "стоит ли деплоить?"
- "правильно ли мы делаем X?"
- "safe to merge?"
- "есть ли смысл в этой архитектуре?"

## When NOT

- Status questions → `leadv2-status-snapshot.sh`
- Explanation → Haiku Explore
- Action request → register as task

## Protocol

### Input

Lead spawns this skill with:
1. Founder's question (verbatim)
2. Active task ID
3. Pointer to relevant context: `docs/handoff/<id>/context.yaml` + recent deliverable summaries

### Reads (allowed)

- `docs/handoff/<task-id>/context.yaml` — the plan and decisions
- `docs/handoff/<task-id>/*.summary.md` — verdicts so far
- `docs/handoff/<task-id>/*.full.md` — ONLY if summary is ambiguous on the dimension founder asked about
- `BOARD.md` recent rows — context for "правильно ли" questions
- `lead-patterns.md` — historical priors that match question keywords

**Reads NOT allowed without explicit founder OK:** raw code files, server logs, supabase queries.

### Output — strict YAML

```yaml
verdict: GO | NO_GO | CONDITIONAL | INSUFFICIENT_INFO
confidence: 0.0-1.0
one_liner: "≤25 words — what to tell founder verbatim"
reasoning: "≤120 words — why this verdict, what evidence"
caveats: []  # list of ≤5 short bullets
suggested_action: "what lead should do next, ≤15 words"
```

### Output discipline

- ONE Opus turn. ONE Read of context.yaml + summaries. Done.
- Do NOT spawn sub-subagents. Do NOT run code. Do NOT call MCP graph.
- If `INSUFFICIENT_INFO`: state exactly which file or query would resolve it. Lead decides whether to fetch.

## Examples

### Q: "стоит ли деплоить сейчас?"

Reads: build.summary.md, codex-review.summary.md, premortem.summary.md, deploy.preflight.md if exists.

Output:
```yaml
verdict: GO
confidence: 0.85
one_liner: "Деплой ок — все 3 verdicts APPROVE, премортем 2/10."
reasoning: "Build verdict APPROVE (no errors, tests pass). Codex APPROVE с 1 minor (logging). Critic APPROVE. Premortem risk_score=2/10. No schema changes. Rollback path verified. Single notable: новая env-var нужна на VPS — preflight подтверждает."
caveats:
  - "VPS env-var должна быть pre-set до push"
  - "Smoke test первым делом"
suggested_action: "spawn deploy"
```

### Q: "правильно ли что мы выбрали partial unique index здесь?"

Reads: architect.summary.md, critic.summary.md, schema migration file.

Output:
```yaml
verdict: CONDITIONAL
confidence: 0.7
one_liner: "Partial unique работает, но PostgREST upsert не справится — нужен plain unique."
reasoning: "Spec choice partial unique (WHERE active=true) корректен для query performance. Но PGRST102 fires on ON CONFLICT с partial — это известная проблема (см. memory feedback_postgrest_upsert). Если writer использует upsert через sb_insert — будет ломаться."
caveats:
  - "Если writer использует только INSERT без ON CONFLICT — partial ок"
  - "Если есть upsert логика — переключиться на plain unique + WHERE в WHERE clause"
suggested_action: "проверь writer-функцию на ON CONFLICT"
```

## Anti-patterns

- Multi-turn deliberation. ONE turn.
- Reading entire codebase. Limit to handoff + 1-2 specific files.
- Hedging ("might be ok, might not"). Pick GO/NO_GO/CONDITIONAL/INSUFFICIENT_INFO.
- Paraphrasing existing verdicts. If summary already has the answer, quote it.
