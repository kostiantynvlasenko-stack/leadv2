---
name: leadv2-deploy
description: "[internal] Phase 6 — commit, push, deploy via project override or escalate; circuit-breaks on unresolved Critical/High."
allowed-tools:
  - Read
  - Write
  - Edit
  - Bash
  - Grep
  - Glob
---

# Lead v2 Deploy — Universal Wrapper

## When: Phase 6, after Review clean. When NOT: Critical/High unresolved.

## Protocol

### 0.1. Divergence preflight (Step 0 — run BEFORE 0.5 / before building further)

```bash
git fetch origin main
BEHIND=$(git rev-list --count HEAD..origin/main 2>/dev/null || echo "0")
```

| `$BEHIND` | Action |
|---|---|
| 0 | Clean — proceed to 0.5 |
| 1-5 | **WARN:** `"[DIVERGENCE] Task branch is ${BEHIND} commit(s) behind origin/main. Rebase NOW before continuing — ff-only merge will fail at deploy."` Attempt auto-rebase: `git rebase origin/main`. If rebase exits 0, proceed. If conflicts, STOP and surface to founder. |
| >5 | **BLOCK:** do not attempt auto-rebase. Surface: `"[DIVERGENCE_BLOCK] ${BEHIND} commits behind — manual rebase required before deploy."` Set `LEAD_V2_STATE.status: paused`. |

Record result in `context.yaml.deploy_gate.divergence_check` (`{behind: N, action: "clean|rebase_ok|rebase_conflict|block"}`).

### 0.5. Pre-mortem check (deploy phase)

```bash
bash .claude/scripts/lv2 leadv2-premortem.sh \
  --task-id <task-id> \
  --phase deploy
pm_rc=$?
```

| Exit | Verdict | Action |
|---|---|---|
| 0 | proceed | Continue |
| 1 | proceed_with_caution | Add premortem caution flag to LLM-judge packet; proceed |
| 2 | skip_recommended | Tier B pause — "Premortem says <pct>% success — redesign / continue?" (default: redesign via architect) |

Record verdict in `context.yaml.deploy_gate.premortem_verdict`.

### 0.7. LLM-judge gate (after premortem, before auto-Gate 2)

Skip condition:
```
task.classification == Light
AND offlimits exit 0
AND premortem.verdict == proceed
AND hack_findings.block == 0
```

If not skipped:
```bash
judge_out=$(bash .claude/scripts/lv2 leadv2-llm-judge.sh \
  --task-id <task-id> --class <classification>)
judge_rc=$?

prompt_file=$(printf '%s\n' "$judge_out" | grep '^judge_prompt_file=' | cut -d= -f2)
judge_model=$(printf '%s\n' "$judge_out" | grep '^model=' | cut -d= -f2)
```

Spawn Opus/Sonnet judge agent, parse response via:
```bash
bash .claude/scripts/lv2 leadv2-llm-judge-parse.sh \
  --task-id <task-id> \
  --response-file <agent_response_file> \
  --model <judge_model>
```

Record `context.yaml.deploy_gate.llm_judge_verdict` and `llm_judge_overall_risk`.

### 0. Auto-Gate 2 check (Tier A — silent deploy for low-risk tasks)

Requirements — ALL must be true:
```
[ ] task.classification == Light
[ ] graph_footprint.risk_score == low
[ ] off_limits check clean (exit 0)
[ ] coverage.yaml.passed == true  OR  coverage_gate == skipped
[ ] llm_judge.verdict in [go, go-with-caveats]  OR  llm_judge.skipped == true
```

If ALL true → proceed silently, log `"auto-Gate-2 passed (Tier A)"` to `LEAD_V2_STATE.md`.
If `llm_judge.verdict == no-go` → **block deploy**, Tier B decision (default: redesign via architect).
Otherwise → compose Tier B decision via `leadv2-founder-input` with recommended = "Deploy (durable)".

### 0.8. Compress Review outputs before reading

```bash
source .claude/scripts/lv2 leadv2-helpers.sh
for f in \
  "docs/handoff/${TASK_ID}/critic.md" \
  "docs/handoff/${TASK_ID}/developer.md" \
  "docs/handoff/${TASK_ID}/hack-detection.summary.md"; do
  [[ -f "$f" ]] && leadv2_compress_handoff "$f"
done
review_summary=$(leadv2_read_handoff "docs/handoff/${TASK_ID}/critic.md")
```

### 1. Precondition gate — ALL must pass

```
[ ] reviews.codex_round_1.critical == 0 AND high == 0 (or rev2/rev3 cleared)
[ ] reviews.disposition == "resolved" OR "TODO-filed-with-ticket"
[ ] Tests pass
[ ] git status -sb non-empty; git diff --stat touches expected files
[ ] off_limits check passes
[ ] decisions: all honored
[ ] verification.live_signal defined in context.yaml
[ ] G-Eval gate passes (Standard+ only)
```

Failure at any step:
```
PushNotification: "leadv2 deploy blocked: <which check> failed"
AskUserQuestion with 2 options (abort / fix-then-retry)
Set LEAD_V2_STATE.status: paused
```

### 2. Commit

```
Agent(developer, sonnet, prompt="
Task-id: <id>
Write conventional commit for current staged + unstaged changes.
Format: <type>: <subject> (≤72 chars). Body: 2-3 lines, reference task-id.
Do NOT include 'Generated with Claude' or similar attribution.
Stage all expected files, commit, output commit hash.
")
```

Record commit hash in `context.yaml.deploy_gate.commit_hash`.

### 3. Push to main

```
Agent(devops-engineer, sonnet, prompt="
git push origin main
Confirm push succeeded (origin/main == local main).
Output last commit on origin/main.
")
```

### 4. Deploy — Step 5: Project override hook

Check for project-level override **first**:

```bash
OVERRIDE="${CLAUDE_PROJECT_ROOT:-$PWD}/.claude/leadv2-overrides/deploy.sh"
if [[ -f "$OVERRIDE" ]]; then
  LEAD_V2_TASK_ID="<task-id>" bash "$OVERRIDE"
  rc=$?
else
  # No override defined for this project — escalate to founder
  bash .claude/scripts/ask-lead.sh "<task-id>" \
    "no deploy override defined for this project (.claude/leadv2-overrides/deploy.sh missing). Define it or provide manual deploy steps."
  rc=1
fi
```

Override exit codes: 0=success, 1=partial, 2=all-failed.

Spawn via Agent for logging:
```
Agent(devops-engineer, sonnet, prompt="LEAD_V2_TASK_ID=<id> bash .claude/leadv2-overrides/deploy.sh; echo exit=$?")
```

Update `context.yaml.deploy_gate` with deploy result.

### 5. Failure handling

| Result | Action |
|---|---|
| Deploy rc=0, no errors | Proceed to Phase 7 Verify |
| rc=1 (partial) | AskUserQuestion: "partial deploy. continue?" OR trigger `leadv2-rollback.sh` |
| rc=2 (all failed) | Immediate `leadv2-rollback.sh` → PushNotification |
| Running but log errors | Proceed to Phase 7 — verify will catch it |

### 6. State update

```bash
source .claude/scripts/lv2 leadv2-helpers.sh && leadv2_active_update_phase verify
```

Log: `"commit <hash>, deploy rc=<rc>, verify pending"` to `LEAD_V2_STATE.md`.

Proceed to Phase 7 Verify.

## Rules

- **No human gate here.** Gate 1 was the only approval. Deploy is automated given preconditions.
- **Project override is the ONLY deploy path.** No hardcoded VPS IPs or repo-specific commands here.
- **Conventional commit only.** No attribution lines.
- **Rollback is cheap — use it.** Don't debate if in doubt.

## Anti-patterns

- Hardcoding VPS IPs or project-specific deploy commands in this skill — use `.claude/leadv2-overrides/deploy.sh`.
- Skipping off_limits structural check.
- Deploying without precondition gate passing.
