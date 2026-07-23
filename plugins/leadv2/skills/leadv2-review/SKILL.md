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

### 0a. Trajectory pre-check (cheap structural gate)

Run BEFORE §1 for Standard and Heavy tasks only. Skip for Light class when the §0 skip-review
gate has already passed (do not double-gate Light tasks). Full script + branch-by-branch
handling: **`ref/trajectory-gate.md`**.

Quick reference:

| Exit | Meaning | Action |
|---|---|---|
| 0 | trajectory ok | proceed to §1 |
| 1, `missing_events` non-empty | responsible role's artifact absent | re-spawn that role (max 1 retry: developer/architect/critic per missing artifact), re-run check; still failing → escalate via `ask-lead.sh` |
| 1, only `out_of_order` | timing skew, nothing missing | log warning to LEAD_V2_STATE.md, proceed to §1 (not a blocker) |
| 2 | script/config error | escalate via `ask-lead.sh`; do NOT proceed until resolved |

Result auto-saved to `docs/handoff/<task-id>/trajectory.yaml`.

### 1. Determine reviewers

Codex availability check: `bash ~/.claude/scripts/codex-task.sh status` (exit 0 = OK, requires active
ChatGPT login). **Do NOT route this through `.claude/scripts/lv2`** — it always fails with
"cannot resolve script" (exit 127) regardless of real Codex availability. Full history/rationale
(FIX-FANOUT-MODEL-ROUTING-01): **`REFERENCE.md`**.

**Always fire (primary, one of):** Codex adversarial-review (background) if OK; else `Agent(critic, sonnet, run_in_background=true)` as fallback primary — equally valid.

**Extra reviewers — HARD GATES:**

| Reviewer | Fires when |
|---|---|
| critic(opus) | ALL of: (a) diff touches safety-sensitive surface (safety gate, RLS policies, auth, publish path, webhook verification, billing/Paddle); (b) hack-detection OR Codex/critic Round 1 flagged a High severity finding; (c) the finding is structural (design/correctness), not style/naming |
| security-auditor(sonnet) | diff touches `*crypto*`, `*auth*`, `*token*`, `*secret*`, `*webhook*`, `*billing*`, or RLS migrations |
| **Auto-upgrade** (forces critic=opus AND spawns security-auditor, overriding the two gates above) | ANY of: context.yaml lists ≥2 persona ids in `applies_to`; diff touches `personas/_shared/**` or `agent/**` AND the brief mentions 'across personas' / 'all personas' / 'multi-tenant' / 'RLS'; a new/changed GRANT/REVOKE/CREATE POLICY in a `*.sql` migration with a USING clause on `auth.uid()`/`persona_id`. Reason: 2026-05-12 FEAT-OBS-BATCH-1 — architect proposed an RLS cross-tenant grant hole; only opus critic + security-auditor parallel caught it. |

If neither extra reviewer fires → the primary reviewer output (Codex or critic-sonnet) IS the review; proceed to Phase 6 Deploy on `disposition == resolved`.

### 1b–1e. Setup before spawning reviewers

Full commands: **`ref/reviewer-setup-steps.md`**.

- **Question-proxy Monitor** — start it now if not already running from Phase 2 (mailbox that surfaces subagent questions to the lead).
- **Diff prep** — generate `git diff <task-start-sha>..HEAD`, save to `/tmp/leadv2-review-<id>.diff` + `docs/handoff/<id>/diff.patch`. Every reviewer mission file MUST embed the diff path and a "<15% tokens on file-context lookups" budget. **Exception:** security-auditor may always read full files in security-sensitive paths (`platform/safety/`, `platform/auth/`, `*crypto*|*auth*|*token*|*secret*|*webhook*|*billing*`) without that budget constraint.
- **Cache warming** — if Review will fire ≥2 same-role spawns (critic(opus) + security-auditor, Case B), pre-warm both before spawning (max 3s wait enforced). Skip for single-spawn phases.
- **Compress Build outputs** — before reading developer.md/diff.md, run `leadv2_compress_handoff` (no-op on files ≤8KB or YAML; saves ~50-70% Opus tokens on large deliverables).

### 2. Round 1 — spawn reviewers

Reviewers spawn via **Agent tool** (shared session) — their `.claude/agents/<role>.md` frontmatter activates skills (code-review-patterns, devils-advocate, codex-review, leadv2-subagent-protocol). claude-subsession loses these in headless mode. Hack-detection always runs in parallel with Codex/critic (see `leadv2-hack-detection` skill).

**Codex invocation discipline (hard rule):** `codex-task.sh adversarial-review` MUST be passed
`--wait` and run as a `run_in_background=true` Bash tool call. `--wait` makes codex-companion run
synchronously; the Bash tool's background flag is the only async layer. Never use a bare
`--background` codex flag without `--wait` — codex-companion then returns immediately, the job
runs detached, and the captured output file gets only the start banner (findings stay stranded in
the plugin job-log). With `--wait` the full review lands in the Bash output file and
`cx-tail.sh` reads it directly.

**Step 0 — Bandit model selection, MANDATORY when `LEADV2_ROUTE_BANDIT=1`:** run
`leadv2-route-bandit.sh select-for-workflow --phase review ...` BEFORE calling `Workflow()`
and pass the result as `args.models`. Skipping this step freezes arm posteriors — the bandit
never learns from this task. Flag-off → skip entirely (byte-identical to pre-BANDIT-WIRE-01).
Full command + Workflow args wiring: **`ref/route-bandit-step0.md`**.

**Opt-in Workflow-based path** (preferred when `LEADV2_WORKFLOW_ENABLED=1` and the `Workflow`
tool is available): full invocation, args, and fallback rules → **`WORKFLOW-PATH.md`**.

**Manual path (Cases A/B/C, default when `LEADV2_WORKFLOW_ENABLED` unset or ≠ 1)** — exact spawn
commands + critic mission file: **`ref/manual-dispatch-cases.md`**.

| Case | Condition | Spawns (ONE message, parallel) |
|---|---|---|
| A | Codex OK, not safety-touched | Codex adversarial-review (bg) + hack-detection (`Agent(developer, sonnet)`) |
| B | Codex OK, safety-touched | Codex + `Agent(critic, opus)` + `Agent(security-auditor, sonnet)` + hack-detection |
| C | Codex down | `Agent(critic, opus)` promoted to primary + hack-detection (+ security-auditor if safety-touched) |

### 3. Read Round 1 findings — adapt to which reviewers ran

- Codex ran → `~/.claude/scripts/cx-tail.sh <codex output path>`
- critic(opus) ran → `Read docs/handoff/<id>/critic.md`
- security-auditor ran → wait for Agent task-notification, read its summary

**Codex mid-run failure detection** (rate-limit after spawn but before completion): if cx-tail
shows `429` / `rate limit` / `timeout` / empty body → treat as Case C mid-flight, immediately spawn
`critic(opus)` as fallback primary. Do NOT retry Codex — a rate limit means the burst is over budget.

**Hack-detection fold-in — mandatory, not optional.** Read `docs/handoff/<id>/hack-findings.yaml`
(missing file → treat as `has_block=false, warn_count=0`; don't block on tooling absence). Parse
`summary.block_count` / `warn_count` / `has_block`. Full parsing + round1-findings fold-in script:
**`ref/hack-detection-processing.md`**.

Write to context.yaml **now** (before reading other reviewer outputs):
```yaml
context.yaml.reviews.codex_round_1: {critical: N, high: N, medium: N}
context.yaml.reviews.hack_findings: {block_count: N, warn_count: N, info_count: N, has_block: true/false}
```

**Gate — execute before proceeding to §4 decision tree:**

If `has_block == true`:
```
AskUserQuestion: "Hack-detection found ${block_count} block-severity signal(s) in this diff:
${block_snippets}
Options: (A) accept with band-aid (appended to followups.md as tech debt), (B) fix now before deploy. Default: B."
```
- Do NOT set `disposition: resolved` until founder answers.
- If (B): spawn `Agent(developer, sonnet)` to fix the flagged patterns, then re-run hack-detection once.
- If (A): append `"- [ ] HACK-BANDAID-<type>: <snippet>"` to `docs/handoff/<id>/followups.md` for each block finding, then proceed.

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

When max 2 rounds exhausted and Critical still present: compose a full-history mission file
(template + exact invocation: **`ref/architect-escape-mission.md`** — task/mission/Round 1+2
findings/fixes/remaining Critical, max 300 words, propose an alt approach that bypasses this
class of issue, or explain why and recommend escalate-to-founder) and run it via
`claude-subsession.sh --role architect --model opus --effort max`.

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

Common mistakes to avoid (CX-01 token burn, over-escalating to opus, skipping gates, etc.):
see **`EXAMPLES.md`**.
