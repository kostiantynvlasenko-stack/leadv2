---
name: leadv2-founder-question-router
description: "[internal] Lead-side router for founder questions during an active /leadv2 task."
allowed-tools:
  - Read
  - Bash
  - Skill
  - Agent
---

# /leadv2 Founder-Question Router

## When

- A `/leadv2` task is in flight (`active.yaml` has at least one session).
- Founder typed a free-form message (NOT a slash command).
- The message is NOT a Gate-1 / Gate-2 explicit approval/rejection (those are handled by the gate skills, not here).

## When NOT

- No active task → ignore, fall through to normal /leadv2 intake.
- Founder typed `/<command>` → route to that command.
- Founder explicitly said "ответь сам" / "skip router" → answer directly (rare, log it).

## Protocol — fixed 4 steps

### Step 1: Classify

```bash
CLASS=$(bash .claude/scripts/lv2 leadv2-founder-question-classify.sh "$FOUNDER_MSG")
```

Possible classes:
- `status`
- `judgment`
- `explanation`
- `action_request`
- `chat`

### Step 2: Dispatch

| Class | Lead action |
|---|---|
| `status` | `bash .claude/scripts/lv2 leadv2-status-snapshot.sh` → quote output verbatim. NO LLM judgment. |
| `judgment` | `Skill(leadv2-judge)` with `mode: question` + the question + active task context. Quote Opus verdict. |
| `explanation` | `Agent(subagent_type=Explore, model=haiku)` with question + word limit 120. Quote summary. |
| `action_request` | Acknowledge + write new RECOVERY-task to BOARD or amend `context.yaml` plan.steps. Do NOT execute the change yourself. |
| `chat` | One-line ack ("ок", "понял", "ясно"). Optionally offer to register as task. |

### Step 3: Return — verbatim, do not paraphrase

Quote the dispatched output to founder character-for-character. Do not "smooth it out", do not rephrase, do not add caveats.

Lead's job is bus, not interpreter.

### Step 4: Resume

If active phase has a pending action from `leadv2-phase-advance.sh`, continue it. Founder question doesn't pause the task unless founder explicitly said "стоп" / "pause" / "wait".

## Examples

**Founder:** "где мы по фазе"
- Class: `status`
- Action: `bash .claude/scripts/lv2 leadv2-status-snapshot.sh`
- Output: "phase=review, verdicts=[APPROVE, REVISE], action=spawn_developer_revise"

**Founder:** "стоит ли деплоить или подождать"
- Class: `judgment`
- Action: `Skill(leadv2-judge)` with `mode: question` + full deploy-gate context
- Output (Opus): "ship — risk=3/10, reason: tests pass, no schema changes"

**Founder:** "почему ты выбрал Sonnet а не Opus для этого билда"
- Class: `explanation`
- Action: `Agent(subagent_type=Explore, model=haiku)` reading routing.yaml + recent route logs
- Output: "Routing rule R7: Standard class + total_lines<300 → sonnet"

**Founder:** "добавь еще проверку на null в линию 42"
- Class: `action_request`
- Action: ack + add to context.yaml plan.steps OR write RECOVERY-task
- Output: "ок, добавил в plan.steps как S7. поехали в Build round 2 после текущего."

**Founder:** "ну всё понял спасибо"
- Class: `chat`
- Action: one-line ack
- Output: "👍"

## Anti-patterns

- Lead answers a `judgment` question with its own opinion. Wrong: spawn judge.
- Lead reads code to answer `explanation`. Wrong: spawn Haiku Explore.
- Lead executes the `action_request` immediately. Wrong: register it, finish current phase first.
- Lead paraphrases Opus verdict. Wrong: quote verbatim.
- Lead writes >50 words for `chat` class. Wrong: one line.

## Why this exists

Sonnet lead drifts on judgment questions ("стоит ли", "правильно ли"). Routing every judgment to Opus judge gives Sonnet only state-machine work — at which Sonnet is reliable. Lead burn drops because Opus is called 1 turn per judgment, not for the entire task.
