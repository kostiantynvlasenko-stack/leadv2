---
name: leadv2-build
description: "Phase 4 — parallel Sonnet code writers per plan.parallel_groups; escalates to claude-subsession for long-context tasks. Triggers: Gate 1 approved, class >= Light."
allowed-tools:
  - Read
  - Write
  - Edit
  - Bash
  - Grep
  - Glob
---

# Lead v2 Build — Parallel Code

## Mission completeness check (BEFORE spawning developer/architect)
Lead's mission file MUST contain:
- `## Mission` — 1-2 sentences, action verb
- `## Reads` — explicit list of files (≤5) the subagent may read
- `## Writes` — explicit list of files/paths the subagent will modify
- `## Acceptance` — 1-3 bullet test/verification steps
- `## Graph context` — pre-populated MCP results (search_graph/trace_path) so subagent doesn't re-discover
- `## Output budget` — always: `Write full detail to docs/handoff/<id>/developer.md. Chat reply: ≤50 words + file pointer. Bash calls: ≤3 for discovery. File reads: ≤5.`
- `## Turn cap` — always: `Hard limit: 30 tool calls. At call 30 without reaching Acceptance → write DELIVERABLE_BLOCKED and stop.`

Missing any section = mission incomplete = spawn FAILS prep. Founder rule: "incomplete specs → 47-turn discovery loops in subagent." (avg observed: 53 turns; cap saves ~23 turns × ~$0.03/turn per overflow subagent)

## When: Phase 4, after Gate 1. Trivial tasks skip to Close.
## When NOT: Plan not synthesized (no context.yaml).

## Bot-mode caps (LEADV2_BOT_MODE=1)
When running headless via Telegram bot (no human steering):
- Max 3 subagent spawns per phase (build/review/deploy each capped)
- Max 50 turns per parent session before forced /compact
- Class >= Heavy → escalate to founder via leadv2-question-proxy, do NOT autopilot
- If subagent returns DELIVERABLE_BLOCKED twice for same step → escalate, do NOT third-attempt

## Protocol

### 1. Read plan

```
Read docs/handoff/<task-id>/context.yaml
```

Extract `plan.steps` and `plan.parallel_groups`.

### 1b. Negative-memory pre-check (before spawning any developer)

Run `leadv2-negative-memory` skill with `current_phase: build` and each step's `mission` as `approach_description`:

1. Load `docs/handoff/<task-id>/negative-memory-matches.yaml` if Plan already ran — reuse existing matches rather than re-running.
2. If Plan phase did NOT run (Light/Trivial tasks), run the filter now against `docs/leadv2-negative-memory.yaml`.
3. For any match with `disposition: blocked` → **do not spawn the developer for that step**. Raise Tier B decision first.
4. For any match with `disposition: unblocked` → append to developer mission brief:
   ```
   ## Negative memory (pre-checked by lead)
   docs/handoff/<task-id>/negative-memory-matches.yaml has unblocked entries. Read it.
   Approach is allowed; log the unblock reason in your deliverable summary.
   ```

### 1c. Codex critical findings injection

Before generating developer mission prompts, check if `docs/handoff/<task-id>/codex-plan-result.md` exists:

```bash
CODEX_RESULT="docs/handoff/<task-id>/codex-plan-result.md"
```

If it exists, extract all lines matching CRITICAL or HIGH severity (grep for "C[0-9]" or "H[0-9]" or "CRITICAL" or "HIGH"). Format as:

```
## ⚠️ Critical findings from plan review (must address)
<findings — each on one line, max 10 items, CRITICAL first then HIGH>
```

Append this block to EVERY developer mission prompt in step 2. If no CRITICAL/HIGH findings → skip (no empty section).

### 1d-hint. Agent-hint pre-spawn lookup (MANDATORY when context.yaml has agent_hint fields)

**Before spawning each step**, read `plan.steps[i].agent_hint` from context.yaml. Map to `subagent_type`:

| agent_hint | subagent_type | Auto-inject skill_hints |
|---|---|---|
| `postgres-pro` | `postgres-pro` | `supabase-ops,database-patterns` |
| `frontend-developer` | `frontend-developer` | `modern-web-guidance` |
| `security-auditor` | `security-auditor` | _(none extra)_ |
| `devops-engineer` | `devops-engineer` | `bash-scripting,error-handling` |
| `developer` | `developer` | _(context-dependent)_ |
| _(absent)_ | `developer` | log WARN: `agent_hint missing for step N` |

Append the `skill_hints` value to the developer mission's `Skills:` line, e.g.:
```
Skills: codebase-memory, supabase-ops, database-patterns
```

**Override rule:** lead may override `agent_hint` by writing `agent_hint_override: <type>` in the per-step mission file. Include a one-line justification comment. Always either use the hint or document the override explicitly — it must never be silently ignored.

### 1d. Prompt-cache discipline for parallel developer spawns

Do **not** run a standalone API cache-warmer. Its system prefix does not match
Claude Code's system/tool prefix, so it spends tokens without guaranteeing a
hit. Claude Code manages prompt caching automatically. Keep the same model,
cwd, MCP set, and stable role prompt; verify savings from
`cache_read_input_tokens` in `costs.yaml`.

### 1e. Graph pre-injection for Build (MANDATORY, same as Plan §1a)

**Run BEFORE writing any developer mission file.** Subagents cannot call MCP — lead provides pre-cooked graph context so developer spends 0 tokens on re-discovery.

For EACH plan step, run in the lead session (max 2 calls per step):

```
# 1. Structural lookup for the symbols the step will touch:
mcp__codebase-memory-mcp__search_graph(
  query="<step mission keywords>",
  limit=8,
  project="${LEADV2_CODEBASE_PROJECT}"
)

# 2. Call chain if step modifies a known function:
mcp__codebase-memory-mcp__trace_path(
  function_name="<primary symbol from step.writes>",
  depth=2,
  direction="both",
  project="${LEADV2_CODEBASE_PROJECT}"
)
```

Embed output into the mission file under `## Graph context (pre-loaded — do NOT re-discover)`.

**Budget rule:** if `plan.steps[i].reads` already covers a symbol → skip trace_path for it. Max 4 MCP calls total across all steps in one parallel group.

### 2. For each parallel_group — spawn in ONE message

**Model routing per step (cost discipline 2026-04-25):**

| Step kind | Model | Trigger |
|---|---|---|
| Mechanical rename / formatting / doc-only typo | `haiku` | single file, ≤30 LOC change, no new logic |
| Routine code write (module, schema, test) | `sonnet` | default |
| Multi-file refactor touching cross-cutting concerns | `sonnet` | default |
| Design-space exploration, novel algorithm | Opus only via explicit founder override | never auto-spawn Opus in Build |

**Subagent type is FIXED, not a creative choice:**
- Trivial step → `subagent_type: general-purpose, model: haiku`
- Routine / refactor / multi-file code-write → `subagent_type: developer, model: sonnet`
- **`Explore` is FORBIDDEN as a builder in Phase 4.** Explore is read-only (no Edit/Write tools) and lacks developer skills (async-python, supabase-ops, verification-before-completion). Lead choosing Explore for a code-write step is a routing bug: the agent falls back to Bash hacks (`cat > file`) and bypasses verification. If a step needs only reads/research, it belongs in Phase 0 graph-warm or Phase 2 Plan — not in `plan.steps[i]`.

Haiku is ~15× cheaper than Opus and 3-5× cheaper than Sonnet. Use liberally for trivial steps. Sonnet stays default for anything with real logic.

For the exact `Agent(...)` call shapes (trivial-haiku, developer-sonnet with embedded graph context, postgres-pro) — see [EXAMPLES.md](./EXAMPLES.md). Spawn every item in a parallel group in ONE message; the group `[3]` that depends on group `[1, 2]` runs only after both of those complete.

### 2b. Worktree isolation — when and how

**Use `isolation: "worktree"` when ANY of:**
- `parallel_groups` group has ≥2 developer spawns running concurrently
- Single step touches ≥2 files OR shared modules (`platform/`, `agent/`, `web/`)
- Task class ≥ Heavy (large diff surface)

**Skip isolation (faster, no overhead) when:**
- Trivial single-file edit (haiku tier)
- Doc-only or config-only change
- Sequential group of 1

**Why:** Parallel agents in shared workdir collide on git index, half-written files cause readback corruption (CR-08 in `lead-patterns.md`). Worktrees give each agent its own checkout + branch; cleanup automatic when agent makes no changes.

**After all isolated agents in a group complete**, run the merge protocol — the exact commands, the 3-way-patch fallback, and the conflict policy (clean merge vs soft 3-way vs `.rej`-present escalation) are in [WORKTREE-MERGE.md](./WORKTREE-MERGE.md). Conflicted branches stay on disk for recovery; never auto-cleanup or re-spawn on a conflict.

### 2c. Handoff-file compression before reading plan inputs

Before reading any handoff file produced by the Plan phase (architect.md, critic.md), compress it if large:

```bash
source .claude/scripts/lv2 leadv2-helpers.sh
# Compress plan outputs; leadv2_read_handoff picks compressed twin automatically
leadv2_compress_handoff "docs/handoff/${TASK_ID}/architect.md"
leadv2_compress_handoff "docs/handoff/${TASK_ID}/critic.md"
# Then read via helper (falls back to original when no twin)
architect_plan=$(leadv2_read_handoff "docs/handoff/${TASK_ID}/architect.md")
```

Files ≤8KB or YAML → no-op. Compressed twin is `<stem>.compressed.md` in the same dir.

### 3. Monitor completion

Task notifications arrive async. When all in a group complete → verify diffs:

```bash
git status -sb
git diff --stat
```

### 3b. Validate subagent deliverables (if they wrote YAML)

For any subagent that produces structured YAML output beyond context.yaml:

```bash
source .claude/scripts/lv2 leadv2-helpers.sh
for f in docs/handoff/<task-id>/*.yaml; do
  leadv2_validate_yaml "$f" || echo "[build] invalid YAML: $f"
done
```

Invalid YAML → re-spawn the subagent with explicit "output must be valid YAML" constraint.

For the three typed handoff files, run the stricter semantic validator after
the generic check passes, including the callback-to-producer and Tier-B
escalation path if it's still invalid after one fix attempt — see
[RECOVERY.md](./RECOVERY.md) §3b.

### 3c. Diff-only build-feedback (failed round re-prompt)

When a build round fails and the next round needs a re-prompt, use the
compact diff-based re-prompt protocol (script call, target compression ratio,
fallback behavior) in [RECOVERY.md](./RECOVERY.md) §3c — do not replay full context.

### 3d. Pre-review lint gate (before Codex)

After all agents complete and worktree merges are done, run applicable static checks:

```bash
source .claude/scripts/lv2 leadv2-helpers.sh

# TypeScript check (if any .ts/.tsx files changed)
if git diff --name-only HEAD~1 2>/dev/null | grep -qE '\.(ts|tsx)$'; then
  cd web && npx tsc --noEmit 2>&1 | tail -20 && cd ..
fi

# Python type check (if any .py files changed)
if git diff --name-only HEAD~1 2>/dev/null | grep -qE '\.py$'; then
  python3 -m mypy --ignore-missing-imports $(git diff --name-only HEAD~1 | grep '\.py$' | tr '\n' ' ') 2>&1 | tail -20 || true
fi
```

If tsc or mypy finds errors → do NOT proceed to Codex review. Fix inline (lead may directly edit the output file for mechanical errors — missing imports, wrong types) or spawn a targeted haiku developer for the fix. Log to pulse: `lint-gate: N errors found, fixing before review`.

Skip entirely if no .ts/.tsx/.py files changed.

### 3e. Test-synthesis coverage gate (MANDATORY — runs after 3d, before Review)

**Gate condition:** only run when the build diff touches Python files under `platform/` or `agent/`. Skip silently for docs, UI-only, bash-only, and schema-only tasks.

```bash
# Gate: check for Python changes in platform/ or agent/
_PY_CHANGED=$(git diff --name-only "${TASK_START_SHA}..HEAD" \
  | grep -E '^(platform|agent)/.*\.py$' || true)

if [[ -n "$_PY_CHANGED" ]]; then
  bash .claude/scripts/lv2 leadv2-coverage-gate.sh \
    --start-sha "${TASK_START_SHA}" \
    --task-id "${TASK_ID}" \
    --threshold 50
  _COV_RC=$?
  # coverage.yaml is now at docs/handoff/<task-id>/coverage.yaml
  # Exit 0 = passed, 1 = failed (below threshold), 2 = error

  if [[ $_COV_RC -eq 1 ]]; then
    # Coverage below threshold — surface uncovered functions into review context
    # but do NOT block: reviewer will flag them as findings
    echo "[build] coverage-gate FAILED — uncovered functions will be surfaced in review" >&2
  elif [[ $_COV_RC -eq 2 ]]; then
    echo "[build] coverage-gate ERROR — proceeding without coverage data" >&2
  else
    echo "[build] coverage-gate PASSED" >&2
  fi
fi
```

After this runs, the coverage report at `docs/handoff/${TASK_ID}/coverage.yaml` is injected into the reviewer mission brief under `## Coverage gate`:

```
## Coverage gate
File: docs/handoff/<task-id>/coverage.yaml
If passed=false: the uncovered[] list contains functions added in this diff that have no test.
Reviewer must flag each uncovered function as a finding (severity: medium unless it touches safety/publish paths — then high).
```

**When to inject:** always include this block in the Codex / critic mission file when `coverage.yaml` exists and `synthesis_attempted: false`. If `coverage.yaml` is absent (gate skipped — no Python changes), omit the block entirely.

### 3f. Codex micro-verify on sensitive paths

Advisory, background, non-blocking check for migration/RLS/safety-eval file
changes — fires for Light-class tasks that skip Plan, and per-step for any
class touching `supabase/migrations/` or `contracts/`. Full trigger
conditions + the bash call: [REFERENCE.md](./REFERENCE.md) §3f.

### 4. Mission-drift check (MD-XX from lead-patterns)

For each subagent deliverable:
- Read `docs/handoff/<id>/<role>.md` (or `diff.md#<anchor>`)
- Apply MD-01..MD-04:
  - MD-01: Summary <200 words despite multi-step? → ask re-expand
  - MD-02: No reference to decisions: from context.yaml? → drift risk, re-spawn
  - MD-03: Pastes prompt verbatim? → didn't work, re-spawn
  - MD-04: Claims success but `git diff` empty for expected files? → confabulation, re-spawn
- If any trigger → re-spawn same agent with specific correction

### 5. Escalation — when Sonnet Agent isn't enough

Signals that warrant upgrading from `Agent(sonnet)` to `claude-subsession.sh --role developer --model sonnet`:
- Subagent hit context limit mid-task (saw "context compacted" in its summary)
- Task needs to read 10+ files and reason across them
- Subagent returned partial diff + "need more turns"
- **Proactive trigger:** plan.steps.reads has >3 files AND estimated LOC change >150 — escalate to claude-subsession.sh before spawning, do not wait for context_limit signal

Upgrade:
```bash
~/.claude/scripts/claude-subsession.sh --role developer --model sonnet \
  --task-id <id> --mission-file /tmp/mission-build-<id>.md \
  --session-id <role>-<id>-build
# Has --resume capability if needed later
```

### 6. Group completion — proceed to next group

When all parallel items in group K complete AND no drift re-spawn pending → start group K+1 (which may have deps on K outputs).

### 7. After last group

State update:
```
LEAD_V2_STATE.md:
  phase: build
  step: complete
  note: "N diffs in files [...], commits pending"
```

```bash
source .claude/scripts/lv2 leadv2-helpers.sh && leadv2_active_update_phase review
```

## Phase 4.5 — PO Feedback Loop (auto-trigger for UI features)

**Before proceeding to Phase 5 Review**, check if the diff is UI-heavy (grep for changed `.tsx` files under `apps/*/page.tsx`, `apps/*/components/`, `packages/features/`, `packages/ui/`). If `ui_diff ≥ 2` AND `CLASS` is Standard/Heavy/Strategic AND not emergency mode → invoke `leadv2-po-feedback-loop` skill (4-phase Audit → Build → Verify → Iterate orchestration). Full detection script, trigger/anti-trigger conditions, and the 4-phase breakdown: [PO-FEEDBACK-LOOP.md](./PO-FEEDBACK-LOOP.md).

Skill returns `passed` / `partial` (proceed to Phase 5) or `escalate` (invoke `Skill(leadv2-judge) mode=review`). Proceed to Phase 5 Review either way once the check (and loop, if triggered) completes.

## Rules

- **Always parallel within a group.** Sequential inside a `parallel_groups: [...]` entry is a bug.
- **Never paste context.yaml content into prompts** — give the path, subagent reads.
- **git diff is the ground truth.** Subagent "DONE" is aspirational until verified.
- **Budget: no Opus in Phase 4.** Code writing is Sonnet domain. Opus is for Plan/Review/Recovery.
- **Off_limits violations = immediate stop.** Check every diff against context.yaml off_limits before proceeding.
- **Lead-direct-verify rule (LOCAL-9 retro):** if a fix candidate is ≤5 lines AND in 1 file AND clearly localized (e.g. "is `hidden sm:inline-flex` present on span X line N?"), lead reads directly with `Read offset=N limit=5`. Do NOT spawn a developer agent. Burning a Sonnet spawn for a 5-line check that's likely a stale-cache false-positive is pure cost.
- **Format/numeric UI changes require visual signoff:** Playwright PASS is necessary but not sufficient for axis labels, currency formats, truncation, color-by-sign, dual-axis layouts. For these scenarios the verify agent MUST save `/tmp/v-<n>.png` and lead MUST offer founder visual signoff. See `leadv2-po-feedback-loop` Lessons codified §2.
- **Baseline-for-comparisons (LOCAL-9 retro):** any new UI column / badge showing delta / percentage / vs / change MUST specify baseline + time-semantics + API contract in context.yaml. Critic-Opus in Phase 3 must verify all 3 answered before Build. See `leadv2-po-feedback-loop` Lessons codified §1.

## Anti-patterns

- Spawning same-group subagents in separate messages — serial = wasted wall time.
- Trusting "DELIVERABLE_COMPLETE" marker without `git diff` check — MD-04.
- Adding new steps mid-Build because "would be nice" — scope creep, park as follow-up.
- Using claude-subsession by default for every developer task — 5-10x cost for no benefit on short tasks.
