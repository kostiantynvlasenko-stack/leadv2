---
name: leadv2-review
description: "Phase 5 — Agent(critic) primary + optional Codex + security-auditor review; max 2 rounds then architect escape. Triggers: after Build, class >= Standard-light."
allowed-tools:
  - Read
  - Write
  - Edit
  - Bash
  - Grep
  - Glob
---

# Lead v2 Review — Adversarial Loop

## When: Phase 5, after Build. When NOT: Trivial / Light tasks (direct to deploy).

## Pre-check: Skip-review gate (ALL conditions must be true to skip)

Before spawning any reviewer, evaluate:
```
Skip-review conditions (ALL must be true):
  1. task.classification == Light
  2. graph_footprint.risk_score == low
  3. off_limits check clean (no conflict raised during Build)
  4. lead-patterns.md immune list has NO match for this task fingerprint
  5. no RAG-intake prior match with outcome=rolled_back (similarity ≥ 0.6)
```
If ALL five are true → skip review entirely. Mark in LEAD_V2_STATE.history:
```yaml
review:
  disposition: skipped-low-risk
  reason: "Light class + graph risk=low + no prior rollback match"
```
Then proceed directly to Phase 6 Deploy.

If ANY condition is false → proceed with normal review flow below.

## Protocol

### §0a. Trajectory pre-check (cheap structural gate)

**Run BEFORE §1 for Standard and Heavy tasks only.**
Skip for Light class when the §0 skip-review gate has already passed (do not double-gate Light tasks).

```bash
bash .claude/scripts/lv2 leadv2-trajectory-check.sh \
  --task-id "${TASK_ID}" \
  --class "${TASK_CLASS}"
# Exit codes:
#   0 → trajectory ok, proceed to §1
#   1 → trajectory mismatch (missing events or strict-mode extras)
#   2 → script/config error
```

**On exit 0:** proceed normally to §1.

**On exit 1 with `missing_events` non-empty:**
- Read `docs/handoff/<task-id>/trajectory.yaml` to identify which role is responsible for the missing artifact.
  - `build/developer` artifact missing → re-spawn `developer` agent with mission:
    `"Phase 4 build was incomplete — produce artifact '<artifact>' as specified in context.yaml plan.steps"`
  - `plan/architect` artifact missing → re-spawn `architect` agent with mission:
    `"Phase 2 plan was incomplete — produce docs/handoff/<task-id>/architect.md"`
  - `plan/critic` artifact missing → re-spawn `critic` agent similarly.
- Max 1 retry per missing artifact.
- After the re-spawn completes, re-run `leadv2-trajectory-check.sh` once.
  - If still failing → escalate via `ask-lead.sh`.

**On exit 1 with only `out_of_order` (no missing events):**
- Log a warning to `LEAD_V2_STATE.md` history: `"trajectory: out_of_order timing skew, proceeding"`
- Proceed to §1 — timing skew alone is not a blocker.

**On exit 2:**
- Escalate via `ask-lead.sh <task-id> "trajectory-check script error — see stderr"`.
- Do not proceed to review until resolved.

**Save result to handoff dir** (done automatically by the script):
`docs/handoff/<task-id>/trajectory.yaml`

### 1. Determine reviewers — decide from context.yaml

**Reviewer routing — Codex is optional, Agent(critic) is the reliable default:**

```
# Check Codex availability first (requires active ChatGPT login):
CODEX_OK=$(bash .claude/scripts/lv2 codex-task.sh status >/dev/null 2>&1 && echo "1" || echo "0")

Always fire (one of):
  if CODEX_OK: Codex adversarial-review (background) + Agent(critic, sonnet) in Stage 2
  if !CODEX_OK: Agent(critic, sonnet, run_in_background=true) — Codex fallback, equally valid

HARD GATE for critic(opus) — spawn ONLY if ALL of:
  (a) diff touches safety-sensitive surface:
      [safety gate, RLS policies, auth, publish path, webhook verification, billing/Paddle]
  (b) hack-detection OR Codex/critic Round 1 flagged a High severity finding
  (c) the finding is structural (design/correctness), not style/naming

HARD GATE for security-auditor(sonnet) — spawn ONLY if diff touches:
  [*crypto*, *auth*, *token*, *secret*, *webhook*, *billing*, RLS migrations]

HARD GATE: cross-tenant / multi-persona triggers (auto-upgrade Round 1)
  If ANY of the following hits, force critic=opus AND spawn security-auditor
  regardless of (a)/(b)/(c) above:
    - context.yaml lists >=2 persona ids in `applies_to`
    - diff touches files matching `personas/_shared/**` OR `agent/**` AND brief
      mentions any of: 'across personas', 'all personas', 'multi-tenant', 'RLS'
    - new/changed grant statement in any *.sql migration (GRANT, REVOKE,
      CREATE POLICY) with USING clause involving auth.uid() or persona_id
  Reason: 2026-05-12 FEAT-OBS-BATCH-1 — architect proposed RLS-client grant
  (cross-tenant hole), only opus critic + security-auditor parallel caught it.
```

If neither extra reviewer fires → primary reviewer output (Codex or critic(sonnet)) IS the review; proceed to Phase 6 Deploy on `disposition == resolved`.

### 1b. Ensure question-proxy Monitor is running

If not already started in Phase 2 (because Trivial task skipped Plan), start it now:

```
Monitor:
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
```

### 1c. Prepare diff for reviewers

Before spawning any reviewer, generate and store the diff:

```bash
# Generate diff from task start SHA to current HEAD
git diff "${TASK_START_SHA}..HEAD" > "/tmp/leadv2-review-${TASK_ID}.diff"
# Also write to handoff dir for persistence
cp "/tmp/leadv2-review-${TASK_ID}.diff" "docs/handoff/${TASK_ID}/diff.patch"
```

Reviewer mission files MUST include a `## Diff` section embedding the path to the diff file:
```
## Diff
File: /tmp/leadv2-review-<task-id>.diff
Read this diff first. Review diff, not full files.
Budget: spend <15% of tokens on file-context lookups (allowed when diff lacks context).
```

**Security-auditor exception:** may always read full files in security-sensitive paths without the 15% budget constraint:
- `platform/safety/`
- `platform/auth/`
- Any file matching `*crypto*`, `*auth*`, `*token*`, `*secret*`, `*webhook*`, `*billing*`

### 1d. Cache warming before spawns (≥2 same-role spawns)

If Review phase will fire critic(opus) **and** security-auditor (Case B), pre-warm both:
```bash
# Call warm_chain if claude-subsession.sh is sourced, else call warmer directly:
warm_chain "critic:opus" "security-auditor:sonnet"
# Or directly:
bash .claude/scripts/lv2 leadv2-cache-warm.sh --role critic --model opus &
bash .claude/scripts/lv2 leadv2-cache-warm.sh --role security-auditor --model sonnet &
# Proceed immediately (max 3s wait enforced by warm_chain)
```

Skip if single-spawn phase (only Codex + hack-detection, no critic/security-auditor).

### 1e. Compress Build outputs before reading

Before reading developer.md / diff.md produced by the Build phase, compress them if large:

```bash
source .claude/scripts/lv2 leadv2-helpers.sh
leadv2_compress_handoff "docs/handoff/${TASK_ID}/developer.md"
leadv2_compress_handoff "docs/handoff/${TASK_ID}/diff.md"
# Then read via helper (falls back to original when no twin exists)
dev_output=$(leadv2_read_handoff "docs/handoff/${TASK_ID}/developer.md")
```

Files ≤8KB or YAML → no-op. Saves ~50-70% Opus tokens on large developer deliverables.

### 2. Round 1 — Agent tool, NOT claude-subsession

Reviewers spawn via **Agent tool** (shared session) — their `.claude/agents/<role>.md` frontmatter activates skills (code-review-patterns, devils-advocate, codex-review, leadv2-subagent-protocol). claude-subsession loses these in headless mode.

Hack-detection runs in parallel with Codex/critic in ALL cases (see `leadv2-hack-detection` skill).

**Env flag:** `LEADV2_WORKFLOW_ENABLED=1` enables the dynamic-Workflow fan-out path for the Review phase (requires Max/Team plan with `Workflow` tool). Default (unset) uses the manual Cases A/B/C below.
>
> **Self-enable (orchestrator-judged):** you MAY set `LEADV2_WORKFLOW_ENABLED=1` for the session yourself — without a founder prompt — when Review meets the fan-out test (multi-dimension review / adversarial verify). See `docs/goal-workflow-autonomy.md`.

**Codex invocation discipline:** `codex-task.sh adversarial-review` MUST be passed
`--wait` and run as a `run_in_background=true` Bash tool call. `--wait` makes
codex-companion run synchronously; the Bash tool's background flag is the only async
layer. Never use a bare `--background` codex flag without `--wait` — codex-companion
then returns immediately, the job runs detached, and the captured output file gets
only the start banner (findings stay stranded in the plugin job-log). With `--wait`
the full review lands in the Bash output file and `cx-tail.sh` reads it directly.

> **If `LEADV2_WORKFLOW_ENABLED=1` (and `Workflow` tool is available):**
>

### Step 0 — Bandit model selection (MANDATORY when `LEADV2_ROUTE_BANDIT=1`)

**Before invoking `Workflow()`, you MUST run `select-for-workflow` when the bandit is active.**
Skipping this step freezes arm posteriors — the bandit never learns from this task.

1. Check flag: `if [[ "${LEADV2_ROUTE_BANDIT:-0}" == "1" ]]`
2. Run selection — writes `docs/handoff/${TASK_ID}/route-decisions.yaml`:
   ```bash
   MODELS=$(bash .claude/scripts/lv2 leadv2-route-bandit.sh select-for-workflow \
     --phase review \
     --class "${TASK_CLASS}" \
     --safety "${SAFETY_TOUCHED:-false}" \
     --task-id "${TASK_ID}")
   ```
3. Pass result as `args.models` to the Workflow call:
   ```
   Workflow({name:"leadv2-review", args:{taskId, base, safetyTouched, ..., models: JSON.parse(MODELS)}})
   ```

The workflow JS consumes `args.models.critic` / `args.models.verify` with fallback to pinned defaults.
**Flag-off (`LEADV2_ROUTE_BANDIT != 1`):** skip the shell call entirely — behavior is byte-identical to pre-BANDIT-WIRE-01.
The bandit writes `docs/handoff/<id>/route-decisions.yaml`; scorecard-write.sh reads it at Phase 8 close.

> **PREFERRED — invoke the saved workflow (ships at `~/.claude/workflows/leadv2-review.js`, all repos):**
> ```
> Workflow({ name: "leadv2-review", args: { taskId: "<id>", base: "main",
>            safetyTouched: <bool>, codexEnabled: <bool>, missionPath: "docs/handoff/<id>/review-mission.md" } })
> ```
> It returns ONE synthesized verdict `{verdict, blocking_count, blocking[], followups[]}` — lead context stays clean.
> blocking_count==0 → ACCEPT → Phase 6. blocking_count>=1 → developer fix → re-run (max 2 rounds) → judge.
> The workflow is **model-pinned** (critic sonnet / opus-on-safety, hack+codex haiku, verify sonnet) — never Opus-by-inheritance.
> `m3-market`: set `codexEnabled:false` if managed settings disable Codex/workflows; fall back to manual Cases A/B/C.
>
> The inline draft below is the REFERENCE SHAPE only (the saved .js is canonical). Do NOT hand-inline a fresh script:
>
> ```js
> // Workflow script — review fan-out
> const DIFF_PATH = `/tmp/leadv2-review-<id>.diff`;
>
> const round1 = await parallel([
>   agent("critic", {
>     model: safetyTouched ? "claude-opus-4-5" : "claude-sonnet-4-5",
>     prompt: `Adversarial code review. Diff: ${DIFF_PATH}. Brief: /tmp/review-mission-<id>.md.
>              Output CHALLENGE blocks per critic role format with severity tags.`,
>     outputSchema: {
>       type: "object",
>       properties: {
>         findings: {
>           type: "array",
>           items: {
>             type: "object",
>             properties: {
>               severity: { type: "string", enum: ["critical", "high", "medium", "low", "nit"] },
>               dimension: { type: "string" },
>               description: { type: "string" },
>               suggested_fix: { type: "string" }
>             },
>             required: ["severity", "dimension", "description"]
>           }
>         },
>         max_severity: { type: "string" }
>       },
>       required: ["findings", "max_severity"]
>     }
>   }),
>   // security-auditor fires only when safety-touched (same gate as manual Cases B/C)
>   ...(safetyTouched ? [agent("security-auditor", {
>     model: "claude-sonnet-4-5",
>     prompt: `Security review. Diff: ${DIFF_PATH}. Full-file read allowed for security-sensitive paths.`,
>     outputSchema: {
>       type: "object",
>       properties: {
>         findings: { type: "array", items: { type: "object" } },
>         has_critical: { type: "boolean" }
>       },
>       required: ["findings", "has_critical"]
>     }
>   })] : []),
>   agent("developer", {
>     model: "claude-sonnet-4-5",
>     prompt: `Run hack-detection per .claude/skills/leadv2-hack-detection/SKILL.md on diff ${DIFF_PATH}.
>              Output findings YAML with block_count/warn_count/has_block summary.`,
>     outputSchema: {
>       type: "object",
>       properties: {
>         findings: { type: "array" },
>         summary: {
>           type: "object",
>           properties: {
>             block_count: { type: "number" },
>             warn_count: { type: "number" },
>             has_block: { type: "boolean" }
>           },
>           required: ["block_count", "warn_count", "has_block"]
>         }
>       },
>       required: ["findings", "summary"]
>     }
>   })
> ]);
>
> // Adversarial-verify stage — per-finding 3-vote majority kill
> // Each finding is put to 3 independent review dimensions; ≥2 refutations kill it.
> const verified = await pipeline(round1, {
>   agent: "critic",
>   model: "claude-sonnet-4-5",
>   prompt: `For each Critical/High finding from round1, apply 3-vote majority-kill:
>            vote on (correctness, risk, actionability). If ≥2 votes refute → kill finding.
>            Output: verified_findings[], killed_findings[] with kill_reasons.`,
>   outputSchema: {
>     type: "object",
>     properties: {
>       verified_findings: { type: "array" },
>       killed_findings: { type: "array" },
>       kill_reasons: { type: "object" }
>     },
>     required: ["verified_findings", "killed_findings"]
>   }
> });
> ```
>
> The Workflow returns structured JSON findings directly — no Monitor polling, no manual deliverable-file reads. Write the JSON results to `docs/handoff/<id>/reviews/round1-findings.json` and proceed to §3 using the structured output (no `cx-tail.sh` needed). Codex review (`codex-task.sh adversarial-review`) stays orthogonal: fire it as an optional background Bash call outside the Workflow if available.
>
> **Note:** `Workflow` requires Max or Team plan. If the tool is not available in the current session, fall through to the manual Cases A/B/C below.

```bash
# Manual path (default — LEADV2_WORKFLOW_ENABLED unset or ≠ 1):
#
# Case A: Codex OK, non-safety → Codex + hack-detection, parallel
if $CODEX_OK && ! safety_touched; then
  # ONE message, two calls:
  Bash(codex-task.sh adversarial-review --wait --base main, run_in_background=true)
  Agent(subagent_type=developer, model=sonnet, prompt="run hack-detection per .claude/skills/leadv2-hack-detection/SKILL.md on diff /tmp/leadv2-review-<id>.diff; write findings YAML to docs/handoff/<id>/hack-findings.yaml and summary to docs/handoff/<id>/hack-detection.summary.md")
fi

# Case B: Codex OK, safety-touched → Codex + critic(opus) + security-auditor + hack-detection, parallel
if $CODEX_OK && safety_touched; then
  # ONE message, four calls:
  Bash(codex-task.sh adversarial-review --wait --base main, run_in_background=true)
  Agent(subagent_type=critic, model=opus, prompt="review diff /tmp/leadv2-review-<id>.diff per critic role frontmatter; brief /tmp/review-mission-<id>.md; write to docs/handoff/<id>/critic.summary.md + critic.full.md with DELIVERABLE_COMPLETE")
  Agent(subagent_type=security-auditor, model=sonnet, prompt="security review diff /tmp/leadv2-review-<id>.diff per role frontmatter; always-read-full for security-sensitive paths; write to docs/handoff/<id>/security-auditor.summary.md + security-auditor.full.md with DELIVERABLE_COMPLETE")
  Agent(subagent_type=developer, model=sonnet, prompt="run hack-detection per .claude/skills/leadv2-hack-detection/SKILL.md on diff /tmp/leadv2-review-<id>.diff; write findings YAML to docs/handoff/<id>/hack-findings.yaml and summary to docs/handoff/<id>/hack-detection.summary.md")
fi

# Case C: Codex down → critic(opus) via Agent promoted to primary + hack-detection
if ! $CODEX_OK; then
  Agent(subagent_type=critic, model=opus, prompt="primary adversarial review — full-coverage (Codex unavailable); diff /tmp/leadv2-review-<id>.diff; brief /tmp/review-mission-<id>.md; write to docs/handoff/<id>/critic.full.md + critic.summary.md")
  Agent(subagent_type=developer, model=sonnet, prompt="run hack-detection per .claude/skills/leadv2-hack-detection/SKILL.md on diff /tmp/leadv2-review-<id>.diff; write findings to docs/handoff/<id>/hack-findings.yaml")
  # If safety-touched, also Agent(security-auditor, sonnet) parallel
fi
```

Mission file for critic:
```
Review the diff in docs/handoff/<id>/diff.md for:
- Architecture violations of context.yaml decisions
- Missed off_limits
- Second-order effects
- Hidden assumptions
Output: CHALLENGE blocks per devils-advocate skill format.
```

### 3. Read Round 1 findings — adapt to which reviewers ran

```
# If Codex ran:
~/.claude/scripts/cx-tail.sh <codex output path>

# If critic(opus) ran:
Read docs/handoff/<id>/critic.md

# If security-auditor ran:
<wait for Agent task-notification, read summary>
```

**Codex mid-run failure detection** (rate-limit after spawn but before completion):
- cx-tail shows `429` / `rate limit` / `timeout` / empty body → treat as Case C mid-flight
- Immediately spawn `critic(opus)` as fallback primary
- Do NOT retry Codex — rate limit means burst is over budget

Read and fold in hack-detection results — **mandatory, not optional**:

```bash
# Read hack findings (written by the parallel Agent(developer) hack-detection run)
# If file missing: treat as has_block=false, warn_count=0 (don't block on tooling absence)
HACK_FILE="docs/handoff/<id>/hack-findings.yaml"
```

Parse the file and extract counts. Then **immediately execute** the following logic:

```python
# Pseudocode — execute inline or via a python3 -c call:
import yaml, os
hack_file = f"docs/handoff/{task_id}/hack-findings.yaml"
if os.path.exists(hack_file):
    findings = yaml.safe_load(open(hack_file)) or {}
    summary = findings.get("summary", {})
else:
    summary = {"block_count": 0, "warn_count": 0, "has_block": False}
block_count = summary.get("block_count", 0)
warn_count  = summary.get("warn_count", 0)
has_block   = summary.get("has_block", False)
```

Write to context.yaml **now** (before reading other reviewer outputs):
```yaml
context.yaml.reviews.codex_round_1: {critical: N, high: N, medium: N}
context.yaml.reviews.hack_findings:
  block_count: N      # findings with severity=block
  warn_count: N       # findings with severity=warn
  info_count: N       # findings with severity=info
  has_block: true/false
```

**Gate — execute before proceeding to §4 decision tree:**

```bash
# Fold hack-detection summary into round1-findings (concrete append, not optional):
HACK_SUMMARY="docs/handoff/<id>/hack-detection.summary.md"
ROUND1_FINDINGS="docs/handoff/<id>/reviews/round1-findings.md"
mkdir -p "docs/handoff/<id>/reviews"
if [[ -f "$HACK_SUMMARY" ]]; then
  printf -- '\n## hack-detection\n' >> "$ROUND1_FINDINGS"
  cat "$HACK_SUMMARY"              >> "$ROUND1_FINDINGS"
fi

# If has_block=true: HARD GATE — must get founder approval before disposition=resolved
# Extract block snippets for the question:
block_snippets=$(python3 -c "
import yaml, sys, os
f = 'docs/handoff/$TASK_ID/hack-findings.yaml'
if not os.path.exists(f): sys.exit(0)
d = yaml.safe_load(open(f)) or {}
blocks = [x for x in d.get('findings',[]) if x.get('severity')=='block']
for b in blocks[:3]: print(f\"  {b.get('type')}: {b.get('snippet','')[:80]}\")
" 2>/dev/null || true)
```

If `has_block == true`:
```
AskUserQuestion: "Hack-detection found ${block_count} block-severity signal(s) in this diff:
${block_snippets}
Options: (A) accept with band-aid (appended to followups.md as tech debt), (B) fix now before deploy. Default: B."
```
- Do NOT set `disposition: resolved` until founder answers.
- If (B): spawn `Agent(developer, sonnet)` to fix the flagged patterns, then re-run hack-detection once.
- If (A): append to `docs/handoff/<id>/followups.md`: `"- [ ] HACK-BANDAID-<type>: <snippet>"` for each block finding, then proceed.

If `has_block == false` → no gate. Incorporate warn-count into round_1 findings summary and proceed normally to §4.

### 3b. Negative-memory diff scan (after gathering Round 1 findings)

After combining findings from all reviewers:

1. For each Critical/High finding, extract the affected change approach (file path + change type + brief description from diff hunk).
2. Run `leadv2-negative-memory` skill match filter with `current_phase: review` and the finding's approach as `approach_description`.
3. If match found AND `disposition: blocked` → **auto-elevate that finding's severity to Critical** regardless of original severity. Annotate: `"negative-memory: NM-XX — known failure pattern"`.
4. Append under `docs/handoff/<task-id>/negative-memory-matches.yaml` key `review_phase_matches:`.
5. Reflect in `context.yaml.reviews.round_1.negative_memory_hits: N`.

If `docs/leadv2-negative-memory.yaml` missing → skip, no error.

### 4. Decision tree

| State | Action |
|---|---|
| Round 1: 0 Critical, 0 High | **CX-01** pattern — skip Round 2 → Phase 6 Deploy |
| Round 1: only nit/style | **CX-02** — skip Round 2 → Deploy |
| Round 1: Critical / High present | Fix round — spawn `Agent(developer, sonnet)` with findings → Codex round 2 |
| Round 2: new High introduced (not in Round 1) | **Judge escalation** — `Skill(leadv2-judge)` mode=review; use verdict directly |
| Round 2: Critical still present | **Escape hatch** — spawn `architect(opus)` with full history → alt approach |
| After architect alt: Critical still | **Circuit break** — PushNotification + AskUserQuestion with 2 options |
| Any round: workflow returns `stall:true` | **Skip further REVISE** — go straight to Judge (`Skill(leadv2-judge)` mode=review); do NOT spawn another developer fix round |

**Stall detection — lead persistence contract:**
- Workflow returns `signature` (string) and `stall` (boolean) in every call.
- Lead MUST persist `signature` from the returned object and pass the accumulated list as `priorSignatures` in the next round's Workflow args.
- Example: round 1 returns `{signature:"codex:high|security:critical"}` → lead passes `{priorSignatures:["codex:high|security:critical"]}` to round 2.
- When `stall:true`, workflow has already forced `verdict:"ESCALATE"` — lead acts on that verdict directly.

### 5. Round 2 — if needed

```
Agent(developer, sonnet, prompt="Read docs/handoff/<id>/critic.md + codex findings. Fix Critical and High. Write revised diff to diff.md#step_N_rev2.")

# Then (parallel, one message):
Bash(codex-task.sh adversarial-review --wait --effort medium --base main, run_in_background=true)
(critic re-spawn only if its Round 1 flagged Critical)
```

Update `reviews.codex_round_2: {...}`.

### 6. Escape hatch — architect alt approach

When max 2 rounds exhausted and Critical still:

```bash
# Compose full history mission file:
cat > /tmp/alt-approach-<id>.md <<EOF
Task: <id>
Mission: <original>
Round 1 findings: <summary>
Round 1 fix: <what was done>
Round 2 findings: <summary>
Remaining Critical: <list>

Propose alternative approach that bypasses this class of issue. 
If no alt exists, explain why and recommend escalate-to-founder with what decision is needed.
Max 300 words.
EOF

~/.claude/scripts/claude-subsession.sh --role architect --model opus \
  --task-id <id> --mission-file /tmp/alt-approach-<id>.md --effort max
```

- Architect proposes alt → re-run Plan phase (context.yaml revised) → re-Build → re-Review Round 3 (final).
- Architect says "no alt" → circuit break.

### 7. Circuit break

```
PushNotification: "leadv2 stuck on <task-id>: <N Critical after 2 rounds + architect alt>. needs direction."
AskUserQuestion: "2 rounds done, architect had no alt. Options: (A) accept risk with TODO, (B) abandon task, (C) redesign scope. Which?"
```

Write LEAD_V2_STATE: status: paused, note: "review circuit break, awaiting founder".

### 8. Pass through to Deploy

When all Critical/High resolved:
- Update `reviews.disposition: "all resolved in rev N"`
- `LEAD_V2_STATE.md phase: review, step: complete`
- Write `docs/handoff/<task-id>/reviews/disposition.yaml` and validate its schema before proceeding:

```bash
source .claude/scripts/lv2 leadv2-helpers.sh
if ! leadv2_validate_handoff "docs/handoff/<task-id>/reviews/disposition.yaml" review_disposition 2>/tmp/hv-err.txt; then
  err=$(</tmp/hv-err.txt)
  # Fix the disposition.yaml once (call back to the Review phase writer with the error):
  .claude/scripts/ask-lead.sh "<task-id>" "disposition.yaml schema invalid: $err — fix and re-write"
  # Re-validate; if still invalid, escalate via ask-lead.sh (Tier B decision)
  leadv2_validate_handoff "docs/handoff/<task-id>/reviews/disposition.yaml" review_disposition \
    || { .claude/scripts/ask-lead.sh "<task-id>" "disposition.yaml still invalid: $err"; exit 1; }
fi
```
- ```bash
  source .claude/scripts/lv2 leadv2-helpers.sh && leadv2_active_update_phase deploy
  ```
- Proceed to Phase 6 Deploy.

## Rules

- **Round count is hard cap.** 2 rounds + 1 architect alt + 1 final round = max 3 dev cycles per task.
- **Parallel reviewers in Round 1.** Codex + critic + security-auditor — ONE message.
- **Codex Round 2 uses default model with `--effort medium`.** Faster than `--effort high`, enough for delta-review. Spark is banned project-wide.
- **Never merge with Critical open.** TODO filing requires founder AskUserQuestion approval via circuit break.
- **Security-auditor runs in parallel with Codex** — do NOT sequence them.

## Anti-patterns

- Running Codex Round 2 after 0 Critical — burns tokens for nothing (CX-01).
- Spawning critic(opus) on every task regardless of safety touch — Opus is for risk-heavy only.
- Merging "just style nits" after Round 1 clean — don't over-engineer; skip to deploy.
- Calling architect(opus) for alt approach on Round 1 failures — that's Round 2's job first.
- Passing full file paths to reviewers without the diff — diff-first saves >50% reviewer tokens.
- Skipping hack-detection — it runs in parallel and is always cheap.
- Skipping the low-risk pre-check — Light+low-risk tasks should never hit review overhead.
