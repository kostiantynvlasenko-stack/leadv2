---
name: leadv2-judge
description: "[internal] Unified Opus judge for leadv2 gate decisions — adjudicates a multi-option fork in classify/plan/build/review/recovery and returns a single ruling with rationale when the specialized judges (judge-review, judge-recovery) do not apply."
allowed-tools:
  - Read
  - Bash
model: opus
---

# /leadv2 Unified Judge

## When

Lead needs an Opus verdict and the mode is clear. Pass `--mode` to select the decision type:

| Mode | Trigger condition |
|---|---|
| `review` | Phase 5: ≥2 reviewers with conflicting verdicts |
| `question` | Founder asked a judgment question during active task |
| `recovery` | Phase failed AND at least 1 retry attempt consumed |

## When NOT

- All reviewers agree → no judge needed (use that verdict directly).
- First failure → automatic retry, skip judge entirely.
- After 3 failures → automatic escalate, skip judge.
- Founder said "ответь сам" → skip judge.

### Mode `review` — Codex gut-check before spawning (added 2026-06-30, SONNET5-ADAPT-01)

Before spawning this Opus judge for a critic-vs-codex conflict specifically (codex was itself one of the disagreeing reviewers), re-fire Codex once fresh at `--effort medium` as a gut-check re-confirmation — reuses the existing "Round 2 tie-break" pattern from `leadv2-plan/SKILL.md`. Codex cannot adjudicate its own round-1 disagreement, so this is a re-confirmation, not an appeal:

```bash
bash .claude/scripts/lv2 leadv2-codex-planner.sh \
  --task-id "<task-id>" --mode reconfirm --effort medium \
  --prior-verdict "docs/handoff/<task-id>/codex.summary.md" \
  --out "docs/handoff/<task-id>/codex-reconfirm.md"
```

If Codex round 2 flips to APPROVE → skip the Opus judge spawn entirely, advance with that verdict. Only on genuine persistent disagreement (round 2 still REVISE/ABORT) does this mode proceed to the Opus judge as documented above. Saves an Opus spawn on the common "Codex was just being strict" case. Does not apply to `question` or `recovery` modes — those don't involve Codex as a disagreeing party.

## Invocation

Lead spawns this skill with the `--mode` flag in the mission or context header:

```yaml
skill: leadv2-judge
mode: review     # OR: question | recovery
task_id: <id>
```

## Shared decision rubric

All three modes share this severity/confidence/escalation matrix:

### Severity scale (applies to all modes)

| Level | Meaning |
|---|---|
| `critical` | Violates `decisions:` or `off_limits`; blocks ship/continue |
| `high` | Functional bug, data-loss risk, security flaw; must address |
| `medium` | Non-functional defect, degraded but recoverable |
| `low` / noise | Style, log verbosity, cosmetic — never blocks verdict |

### Confidence thresholds

- `≥0.85` — state verdict plainly; no hedging.
- `0.60–0.84` — state verdict, append one caveat.
- `<0.60` — return `INSUFFICIENT_INFO` (review/question) or `ESCALATE_TO_FOUNDER` (recovery) with specific gap.

### Escalation matrix

| Condition | Verdict |
|---|---|
| Critical/high issue in scope + fixable | REVISE / RETRY_ALT_APPROACH |
| Critical/high issue + requires re-plan | ABORT / ESCALATE_TO_FOUNDER |
| No critical/high issues | APPROVE / GO / RETRY_SAME |
| Evidence insufficient | INSUFFICIENT_INFO / ESCALATE (state exact gap) |

## Mode-specific reads and output

---

### Mode: review

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

### Mode: question

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

### Mode: recovery

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

---

## Universal anti-patterns (all modes)

- Multi-turn deliberation. **ONE turn.**
- Reading raw code to "verify yourself". Trust reviewer claims / deliverable summaries.
- Hedging. Pick ONE verdict.
- Including noise/style issues as `blocking_issues`. Critical/high only.
- Spawning sub-subagents or calling MCP graph.
- RETRY_SAME after 2 failures (recovery mode). That's a loop.
- ESCALATE without a specific founder question (recovery mode).

## Legacy skills (removed)

`leadv2-judge-review` and `leadv2-judge-recovery` were deprecated 2026-05-04
(PO-063) and deleted 2026-07-03 once all callers were migrated. `leadv2-judge-question`
never existed as a separate skill (dangling reference, fixed same date).
All callers now use this skill with the appropriate `mode` flag.

To migrate a caller:
1. Replace `Skill(leadv2-judge-<X>)` with `Skill(leadv2-judge)` + `mode: <X>` in mission context.
2. Output format is identical — field names unchanged.
3. Remove the legacy invocation line once verified.
