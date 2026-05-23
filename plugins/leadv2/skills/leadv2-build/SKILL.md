---
name: leadv2-build
description: Phase 4 — parallel Sonnet code writers per plan.parallel_groups; escalates to claude-subsession for long-context tasks. Triggers: Gate 1 approved, class >= Light.
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

Missing any section = mission incomplete = spawn FAILS prep. Founder rule: "incomplete specs → 47-turn discovery loops in subagent."

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

### 1d. Cache warming before parallel developer spawns

If `plan.parallel_groups` has >1 developer in the same group → pre-warm before spawning:
```bash
# Warm developer/sonnet prefix if ≥2 developer spawns in first group
warm_chain "developer:sonnet"
# Or directly:
.claude/scripts/leadv2-cache-warm.sh --role developer --model sonnet &
# Proceed to spawn — warm runs in background, max 3s wait enforced
```

Skip if single-spawn phase (break-even only at N≥2 same-role spawns).

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

```
# Example: parallel_groups: [[1, 2], [3]]
# Group [1, 2] → parallel; group [3] runs after both complete.

# Trivial step → haiku, no isolation needed (single file, no collisions)
Agent(
  subagent_type: general-purpose,
  model: haiku,
  prompt="Mission: <plan.steps[2].mission — mechanical, ≤30 LOC>
  Reads: <...>
  Writes: <single file>"
)

# Normal step → sonnet, isolation:worktree if group has ≥2 spawns OR step touches >1 file
Agent(
  developer, sonnet,
  isolation: "worktree",   # ← parallel-safe checkout, see §2b
  prompt="Codebase graph project: ${LEADV2_CODEBASE_PROJECT}

  ## Graph context (pre-loaded — do NOT re-discover)
  <embed search_graph + trace_path output from §1e here>

  Mission: <plan.steps[1].mission>
  Read docs/handoff/<id>/context.yaml FIRST. Respect decisions and off_limits.
  Reads: <plan.steps[1].reads>
  **Reads budget: ≤5 files. No exploratory reads beyond the list above.**
  **Bash budget: ≤3 Bash calls for discovery. Use Graph context above instead of grep.**
  Writes: <plan.steps[1].writes>
  Skills: codebase-memory, <domain skills from /lead Skill injection table>

  Deliverable: <plan.steps[1].deliverable>
  **Output:** write full detail to docs/handoff/<id>/developer.md. Chat reply: ≤50 words + file pointer."
)

Agent(
  postgres-pro, sonnet,
  isolation: "worktree",
  prompt=... for step 2 ...
)
```

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

**After all isolated agents in a group complete — merge protocol:**

```bash
# Record the base SHA the lead session started from (do this ONCE before spawning agents,
# NOT mid-merge). The worktree's branch was forked off this commit, so it's the right diff base
# for any branch — even if `main` has moved or the lead is working off a feature branch.
TASK_START_SHA="${TASK_START_SHA:?must be set in Phase 0 intake}"   # e.g. $(git rev-parse HEAD)

# Each agent returns its worktree path + branch in the Agent result.
MERGED=()
CONFLICTED=()
for entry in "${WORKTREE_ENTRIES[@]}"; do
  branch="${entry%%::*}"
  worktree_path="${entry#*::}"
  patch_file="/tmp/leadv2-${TASK_ID}-$(echo "$branch" | tr '/' '_').patch"

  if git merge --no-ff --no-edit "$branch"; then
    MERGED+=("$entry")
    continue
  fi

  # Conflict → fall back to 3-way patch from the recorded base SHA, NOT `main..HEAD`
  (cd "$worktree_path" && git diff "$TASK_START_SHA"..HEAD) > "$patch_file"
  if git apply --3way --reject "$patch_file"; then
    MERGED+=("$entry")
    _leadv2_log "[build] soft 3-way merge ok for $branch"
  else
    # Reject files present — DO NOT touch worktree or branch yet, lead needs them for inspection
    CONFLICTED+=("$entry::$patch_file")
    _leadv2_log "[build] manual merge needed for $branch — patch=$patch_file, see *.rej"
  fi
done

# Cleanup ONLY for cleanly-merged branches. Conflicted ones stay on disk for recovery.
for entry in "${MERGED[@]}"; do
  branch="${entry%%::*}"
  worktree_path="${entry#*::}"
  git worktree remove "$worktree_path" --force 2>/dev/null
  git branch -D "$branch" 2>/dev/null
done

# Conflicted branches are passed to recovery as a structured list:
if (( ${#CONFLICTED[@]} > 0 )); then
  printf '%s\n' "${CONFLICTED[@]}" > "docs/handoff/${TASK_ID}/merge-rejects.md"
  # Recovery decides whether to keep worktrees, drop them, or hand-merge.
  # DO NOT auto-cleanup conflicted worktrees here.
fi
```

**Conflict policy:**
- Clean `git merge` → MERGED, cleanup worktree + branch
- `git apply --3way` succeeds (no `.rej`) → MERGED, cleanup, log soft conflict
- `.rej` files present → CONFLICTED, **keep worktree + branch on disk**, write `docs/handoff/<task-id>/merge-rejects.md` listing branch::patch_file pairs, escalate to recovery (do NOT re-spawn the same agent, do NOT cleanup until human or recovery decides)

**Token cost:** worktree creation is git-only, no LLM tokens. Agents in worktrees see exactly the same repo state — no extra context cost.

### 2c. Handoff-file compression before reading plan inputs

Before reading any handoff file produced by the Plan phase (architect.md, critic.md), compress it if large:

```bash
source .claude/scripts/leadv2-helpers.sh
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
source .claude/scripts/leadv2-helpers.sh
for f in docs/handoff/<task-id>/*.yaml; do
  leadv2_validate_yaml "$f" || echo "[build] invalid YAML: $f"
done
```

Invalid YAML → re-spawn the subagent with explicit "output must be valid YAML" constraint.

For the three typed handoff files, use the stricter semantic validator after generic YAML check passes:

```bash
source .claude/scripts/leadv2-helpers.sh
# Validate context.yaml schema before spawning build agents
if ! leadv2_validate_handoff "docs/handoff/<task-id>/context.yaml" context 2>/tmp/hv-err.txt; then
  err=$(</tmp/hv-err.txt)
  # Call back to the producing agent (Plan phase) ONCE with the error:
  .claude/scripts/ask-lead.sh "<task-id>" "context.yaml schema invalid: $err — please fix and re-write"
  # Re-validate; if still failing, escalate to Tier B via ask-lead.sh
  leadv2_validate_handoff "docs/handoff/<task-id>/context.yaml" context \
    || { .claude/scripts/ask-lead.sh "<task-id>" "context.yaml still invalid after fix attempt: $err"; exit 1; }
fi
```

### 3c. Diff-only build-feedback (failed round re-prompt)

When a build round fails and next round needs re-prompt, **do NOT re-send full context**.

**Protocol:**
1. Call `.claude/scripts/leadv2-build-feedback.sh --task-id <id> --previous-attempt <n>`
2. The script emits a compact prompt: `<previous-summary ≤80w>\n<diff-only>\n<failure reason>\n<fix request>`
3. Inject that output as the ONLY context in the next developer mission (not the full plan)
4. Target: 70-90% reduction vs full context replay

**Fallback:** if diff generation fails, the script falls back to the tail of the previous full deliverable. Never silently skip — compact tail context is better than no context.

**Save explicit diff file for later rounds:**
```bash
git diff "${TASK_START_SHA}..HEAD" > "docs/handoff/${TASK_ID}/build-attempt-${N}.diff"
```
This lets attempt N+1 diff precisely against what attempt N actually committed.

### 3d. Pre-review lint gate (before Codex)

After all agents complete and worktree merges are done, run applicable static checks:

```bash
source .claude/scripts/leadv2-helpers.sh

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
source .claude/scripts/leadv2-helpers.sh && leadv2_active_update_phase review
```

Proceed to Phase 5 Review.

## Rules

- **Always parallel within a group.** Sequential inside a `parallel_groups: [...]` entry is a bug.
- **Never paste context.yaml content into prompts** — give the path, subagent reads.
- **git diff is the ground truth.** Subagent "DONE" is aspirational until verified.
- **Budget: no Opus in Phase 4.** Code writing is Sonnet domain. Opus is for Plan/Review/Recovery.
- **Off_limits violations = immediate stop.** Check every diff against context.yaml off_limits before proceeding.

## Anti-patterns

- Spawning same-group subagents in separate messages — serial = wasted wall time.
- Trusting "DELIVERABLE_COMPLETE" marker without `git diff` check — MD-04.
- Adding new steps mid-Build because "would be nice" — scope creep, park as follow-up.
- Using claude-subsession by default for every developer task — 5-10x cost for no benefit on short tasks.

## Gemini developer mode (optional accelerator)

When agentic quota is available (`leadv2-gemini-check.sh` returns ok AND mode is `agent`):
- Caller writes a mission file with `Create file WORKSPACE/foo with exact content:` sections
- Invoke: `bash $CLAUDE_PLUGIN_ROOT/scripts/leadv2-gemini-developer.sh --mission-file <path> --workspace <scratch> --handoff-dir <handoff> --out <log> --timeout 120`
- Success: SCRIPT_EXIT=0, files in workspace, result in handoff/gemini-result.md
- Failure/quota exhausted (exit 2 or 3): fall back to Agent(subagent_type=developer)
- NEVER use for m3-market (see gemini-policy.yaml)
