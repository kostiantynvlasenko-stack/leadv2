---
name: leadv2-judge-recovery
description: "[internal] Opus judge for recovery decisions."
allowed-tools:
  - Read
  - Bash
model: opus
---

> DEPRECATED 2026-05-04: prefer leadv2-judge --mode recovery. Migration: PO-063.

# /leadv2 Judge — Recovery Decision

## When

A phase failed (verify-probe BLOCK, deploy fail, build fail) AND lead has consumed at least 1 retry attempt. Lead spawns this skill to decide: retry once more, propose alternative architecture, or escalate to founder.

## When NOT

- First failure → automatic retry, no judge.
- After 3 failures → automatic escalate, no judge.
- Founder explicitly said "abort" → no judge.

## Reads (allowed)

- `docs/handoff/<task-id>/recovery.log` — list of attempts so far
- `docs/handoff/<task-id>/<failed-phase>.summary.md` + `.full.md`
- `docs/handoff/<task-id>/context.yaml`
- `docs/leadv2-negative-memory.yaml` — known failure patterns
- `lead-patterns.md` — historical recovery success rates

NOT allowed: raw code, server logs without grep filter.

## Output — strict YAML

```yaml
verdict: RETRY_SAME | RETRY_ALT_APPROACH | ESCALATE_TO_FOUNDER | ABORT_TASK
confidence: 0.0-1.0
one_liner: "≤25 words for lead to quote"
reasoning: "≤100 words"
retry_modification: "what to change for next attempt, ≤30 words"  # if RETRY_*
escalation_question: "what to ask founder, single sentence"      # if ESCALATE_*
suggested_action: "spawn_developer_retry | spawn_architect_alt | propose_escalation | mark_aborted"
```

## Decision rules

- **RETRY_SAME** when failure was transient (timeout, flake) and attempts<2.
- **RETRY_ALT_APPROACH** when failure root-cause maps to a known negative-memory pattern → architect proposes different design.
- **ESCALATE_TO_FOUNDER** when fix requires scope/decision change, or attempts≥2 with same failure-mode.
- **ABORT_TASK** only when continuing would violate `off_limits` or `decisions:`.

## Anti-patterns

- Recommending RETRY_SAME after 2 failures. That's a loop.
- ESCALATE without a specific question. Founder needs a yes/no.
- Reading code to diagnose. Use deliverable summaries; if they don't say why, flag NEEDS-INFO.
