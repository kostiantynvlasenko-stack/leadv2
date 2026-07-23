---
name: leadv2-plan
description: "Phase 2 — Codex (GPT-5.6, tiered) is the PRIMARY plan author; architect(sonnet, never opus) cross-checks + critic synthesized into context.yaml decisions/off_limits/plan.steps. Triggers: classify produces Standard/Heavy/Strategic."
allowed-tools:
  - Read
  - Write
  - Edit
  - Bash
  - Grep
  - Glob
---

# Lead v2 Plan — Triad Brain

## When: Phase 2, class ≥ Standard. When NOT: Trivial / Light (skip to build).

## Phase-2 steps at a glance (map only — numbered steps below carry the detail)

| Step | Fires when | Action | Output |
|---|---|---|---|
| 0 | `LEADV2_ROUTE_BANDIT=1` | select-for-workflow model picks | route-decisions.yaml |
| 1a/1a-2/1a-3 | codebase-memory-mcp available / always / ≥2 personas touched | graph discovery, agent priors, persona-config audit | mission Graph-context block |
| 1c (divergence) | Phase 1.5 ran | inject divergence shortlist + non_obvious_pick into architect mission | context.yaml.divergence |
| 1b | always | write mission file (graph context + constraints) | /tmp/mission-<id>.md |
| 1c (aggregates) | architect needs a number/count/delta | pre-compute in bash, embed result, not raw rows | mission's Pre-computed aggregates |
| 2a | always, before spawns | start question-proxy Monitor | mailbox watch |
| 2b (Stage 1) | class ≥ Standard | Codex (primary plan) + architect(sonnet) cross-check (incl. mandatory capability-search — reuse lib/CLI/MCP/Skill before custom code), parallel | architect.md, codex-plan-result.md |
| 3 | after Stage 1 spawns | Monitor until both deliverables exist | STAGE1_READY |
| 4 | after 3 | read Stage-1 outputs, draft critic brief | /tmp/critic-brief-<id>.md |
| 4b (Stage 2) | class ≥ Standard | critic(opus) adversarial review of synthesis | critic.md |
| 4c/4d | after 4b | read critic output; negative-memory pre-check on candidate steps | negative-memory-matches.yaml |
| 2.5 | always, before writing context.yaml | apply per-repo toolset overrides | context.yaml.allowed_tools |
| 5 | after 4d | synthesize decisions/off_limits/plan.steps, schema-validate | context.yaml |
| 6 | 3-way disagreement | arbitration table → Codex round 2 → AskUserQuestion | decisions cite arbitration |
| 7 | after context.yaml written | premortem.sh --phase build | proceed / caution / redesign |
| 8 | after 7 | update LEAD_V2_STATE, hand off | → Phase 3 Gate 1 |

architect is ALWAYS sonnet (never opus, CODEX-56-ROUTING) — Codex is the primary plan author, architect cross-checks.

## Protocol

### Step 0 — Bandit model selection (MANDATORY when `LEADV2_ROUTE_BANDIT=1`)

**Before invoking `Workflow()`, you MUST run `select-for-workflow` when the bandit is active.**
Skipping this step freezes arm posteriors — the bandit never learns from this task.

1. Check flag: `if [[ "${LEADV2_ROUTE_BANDIT:-0}" == "1" ]]`
2. Run selection — writes `docs/handoff/${TASK_ID}/route-decisions.yaml`:
   ```bash
   MODELS=$(bash .claude/scripts/lv2 leadv2-route-bandit.sh select-for-workflow \
     --phase plan \
     --class "${TASK_CLASS}" \
     --safety "${SAFETY_TOUCHED:-false}" \
     --task-id "${TASK_ID}")
   ```
3. Pass result as `args.models` to the Workflow call:
   ```
   Workflow({name:"leadv2-plan", args:{taskId, taskBrief, heavy, ..., models: JSON.parse(MODELS)}})
   ```

The workflow JS consumes `args.models.architect` / `args.models.critic` with fallback to pinned defaults.
**Flag-off (`LEADV2_ROUTE_BANDIT != 1`):** skip the shell call entirely — behavior is byte-identical to pre-BANDIT-WIRE-01.
The bandit writes `docs/handoff/<id>/route-decisions.yaml`; scorecard-write.sh reads it at Phase 8 close.

> **PREFERRED — saved workflow (offload, model-pinned, 2026-06-09):** when the `Workflow` tool is available, issue
> `Workflow({name:"leadv2-plan", args:{taskId, taskBrief, heavy, archKeyword, codexEnabled, missionPath}})`.
> It runs Codex (PRIMARY plan author, `--tier top` Heavy/arch else `--tier standard`) + architect (sonnet
> cross-check) + critic in parallel, synthesizes context.yaml to disk, and returns
> `{decisions_count, steps_count, blocking_concerns, context_path, needs_founder_decision}`. Retires the manual
> triad + Codex Monitor-polling; lead context stays clean. architect=sonnet ALWAYS (never opus, CODEX-56-ROUTING).
> The manual protocol below is the FALLBACK when the `Workflow` tool is unavailable.

### 1a. Graph discovery — lead pre-populates (recommended)

**Only lead (main session) has MCP access.** Subagents in `claude -p` cannot call `search_graph` / `trace_path` / `get_code_snippet`. If they try, they fall back to Grep (slow, expensive, incomplete).

If `codebase-memory-mcp` is registered, before writing mission file, lead runs from main session:

```
mcp__codebase-memory-mcp__search_graph(
  query="<mission keywords — natural language>",
  limit=10,
  project="${LEADV2_CODEBASE_PROJECT}"
)

# If there's a clear central symbol:
mcp__codebase-memory-mcp__trace_path(
  function_name="<symbol>",
  depth=2,
  project="${LEADV2_CODEBASE_PROJECT}"
)

# For Heavy tasks only:
mcp__codebase-memory-mcp__get_architecture(
  project="${LEADV2_CODEBASE_PROJECT}"
)
```

Pack results into `/tmp/mission-<id>.md` under `## Graph context` section.

**Fallback when MCP is not installed:** use `Grep`/`Glob` for the top mission keywords, build a manual symbol map (~5-10 functions/classes most relevant), and put that in `## Graph context` instead. Quality drops noticeably for cross-file architectural analysis; consider installing `codebase-memory-mcp` for Heavy tasks (see docs/INSTALLATION.md).

### 1a-2. Agent priors (read before writing mission)

Load `docs/leadv2-priors.yaml` → `agent_priors[<agent>]` for each agent you intend to spawn.
Use `best_on` / `avoid_on` to confirm agent assignment; use `model_recommendation[change_kind]`
to set the `--model` flag in the mission (priors inform defaults, founder decisions override).
When `priors.yaml` is present, extract just the relevant agent slice; when it's absent, fall back
to class-based model selection (silent, no error). Full read snippet: see
[REFERENCE.md](./REFERENCE.md) § Agent Priors Read Snippet.

### 1a-3. Persona-config audit (multi-persona only)

Fire when ANY of:
- `context.yaml.applies_to` lists ≥2 persona ids
- planned `touched_paths` include `agent/**` or `personas/_shared/**`
- task brief mentions ≥2 persona ids (`nik`, `respiro`, `marco`, `cascina`)

Run the hardcode + magic-number-threshold detection scan (full bash script): see
[REFERENCE.md](./REFERENCE.md) § Persona Config Audit Scan.

If hits → write `docs/handoff/${LEADV2_TASK_ID}/persona-config-candidates.yaml` (list `file/line/pattern/proposed_key`) and inject one decision into context.yaml.decisions:

```yaml
- key: persona_config_audit_run
  value: persona-config-candidates.yaml
  applies_to: ['developer', 'critic']
  rule: 'If diff touches a flagged line, propose per-persona override path. critic blocks if hardcode survives.'
```

When there are no hits, proceed silently — no file written, and this never blocks Plan progression. Pattern reference: `skills/leadv2-persona-config-audit/SKILL.md`.

### 1c. Divergence intake (if Phase 1.5 ran)

If `docs/handoff/<id>/context.yaml` has a `divergence:` block (Phase 1.5 DIVERGE
ran), the planning triad does NOT start from a blank slate — it converges on the
divergence output:
- Inject `shortlist[]` (each entry = `{id, text, score:{novelty,viability,fit}}`)
  into the **architect** mission as the candidate solution space ("evaluate these
  N candidates; you may synthesize/hybridize, but justify departing from all of
  them"). Pass the `score` map so the architect sees why each ranked.
- `non_obvious_pick` is the **id** of one shortlist entry (resolve it to that
  entry's text before injecting). It is **must-evaluate** — the architect
  explicitly argues for or against it; it cannot be silently dropped (it's the
  highest-novelty viable bet, exactly the option a single-pass plan would skip).
- Seed `context.yaml.off_limits` from `divergence.traps[]` (each trap's reason
  becomes an off-limit with provenance `from: divergence`).
- The architect reads the full `divergence.md` (path in the block) on demand;
  the mission carries only the compact block.

Proceed normally whether or not a `divergence:` block exists — divergence is optional.

### 1b. Write mission file

```
/tmp/mission-<task-id>.md:

Task: <task-id>
Class: <from lead-classify>
Mission: <one-sentence goal>
Constraints (from lead-classify):
  - keywords matched: <list>
  - off_limits candidates: <list from architect STATE if exists>
  - surfaces touched: <list>
Context pointers:
  - BOARD HEAD: <relevant line>
  - RECOVERY open: <relevant items or "none">
  - Architect STATE decisions: <cite existing D1-D5 if any>

## Graph context (pre-loaded by lead — do NOT re-discover)

**search_graph results for "<keywords>":**
- <qualified_name>  file:line  (structural role: function/class/route)
- ...

**trace_path from <symbol> (depth 2):**
- caller → <symbol>: <file>:<line>
- <symbol> → callee: <file>:<line>
- ...

**Architecture summary (Heavy only):**
<get_architecture output, trimmed to mission-relevant sections>

---

**Rules for subagents:**
- Use the Graph context block above INSTEAD of Grep. It's already the best view.
- If you need MORE graph info, call: `.claude/scripts/ask-lead.sh <task-id> "graph: search_graph query=\"<q>\""` — lead will run MCP and reply.
- Only Grep for config files, JSON, migrations where graph has no coverage.

Deliverable format: see subagent role file.
```

### 1c. Pre-compute heavy aggregates BEFORE the architect spawn

**Why:** an Opus subagent reading raw rows of `action_log` / `metrics_daily` / `safety_events` to compute a fingerprint burns 30-100k tokens of expensive context. Lead can do the aggregation in bash/jq in seconds and embed the *result* (a single line or small JSON object) in the mission file.

**Rule of thumb:** if the architect needs a *number*, *count*, *delta*, or *fingerprint* — compute it in lead (cheap) and pass it as a literal. If it needs *examples* or *structural reasoning* — pass IDs and let it pull a single row when needed.

Worked recipe (action_log fingerprint per persona, full bash script): see
[EXAMPLES.md](./EXAMPLES.md) § Precomputed Aggregate Recipe.

Then in the mission file, embed the *output* under `## Pre-computed aggregates`, NOT the raw rows. Architect sees one block of text, not 200 JSON rows.

**Forbidden:** instructing a subagent to "query action_log for the last 200 rows and aggregate" when you can pre-compute the aggregate in lead. That's `feedback_token_burn_orchestration` waiting to happen.

### 2a. Start question-proxy Monitor FIRST (before spawns)

Subagents may call `ask-lead.sh` during their run. Lead MUST be watching the mailbox signal BEFORE subagents spawn, otherwise subagents block 10 min then timeout with default assumptions.

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

On any QUESTION_PENDING notification → run `leadv2-question-proxy` skill.

### 2b. Stage 1 — planning spawns (parallel)

**Rationale:** critic must see a concrete plan to review it. Running critic in parallel with architect wastes tokens on "I don't have plan yet, here's some generic framing concerns". Two stages are cheaper AND better: architect+Codex produce plans in parallel, then critic reviews the synthesis.

**Spawn mechanism:** `Agent` tool (NOT claude-subsession). Agent tool gives architect/critic full MCP access + skills from their frontmatter in `.claude/agents/<role>.md`. claude-subsession is reserved for persona meetings (PO/strategist/architect weekly) where persistent conversation memory is needed.

**Env flag:** `LEADV2_WORKFLOW_ENABLED=1` enables the dynamic-Workflow fan-out path for the Plan phase (requires Max/Team plan with `Workflow` tool). Default (unset) uses the manual path below.
>
> **Self-enable (orchestrator-judged):** you MAY set `LEADV2_WORKFLOW_ENABLED=1` for the session yourself — without a founder prompt — when Plan meets the fan-out test (≥4 independent units / needs independent perspectives). See `docs/goal-workflow-autonomy.md`.

**Stage 1 — ONE message, parallel spawns:**

> **If `LEADV2_WORKFLOW_ENABLED=1` (and `Workflow` tool is available):** issue ONE `Workflow` call
> — parallel architect(sonnet, cross-check) + critic(initial framing review), piped into a lead
> synthesis stage, then (class ≥ Standard) an adversarial-verify stage where critic refutes/confirms
> each decision (2-of-3 dimensions kill a finding) — instead of manual parallel `Agent` spawns +
> `Monitor`. Full script (agent configs, outputSchemas, all four pipeline stages): see
> [EXAMPLES.md](./EXAMPLES.md) § Workflow Enabled Fan Out. The Workflow returns structured JSON
> results directly — no Monitor polling, no manual deliverable-file reads. Codex
> (`leadv2-codex-planner.sh`) stays orthogonal: fire it as an optional background Bash call outside
> the Workflow if available. Requires Max or Team plan — when the tool is not available in the
> current session, fall through to the manual path below (the default).

```
# Manual path (default — LEADV2_WORKFLOW_ENABLED unset or ≠ 1):
#
# Codex (optional, cheap 2nd brain) — fire ONLY if available:
# Check: bash ~/.claude/scripts/codex-task.sh status >/dev/null 2>&1 && echo "codex_ok"
# If codex_ok → fire Codex in background. If unavailable → skip, Agent(critic) is sufficient.
Bash(
  command: bash .claude/scripts/lv2 leadv2-codex-planner.sh --task-id <id> --mission-file /tmp/mission-<id>.md --effort <high|xhigh>
  run_in_background: true
)  # ← only when codex_ok

# Architect(sonnet, CODEX-56-ROUTING: never opus) — spawn if Heavy OR arch keyword OR complex
# multi-service change, as a cross-check on Codex's plan (fired above). Standard class: optional.
# If skipping → Agent(critic, sonnet) covers Stage 1 alone.
Agent(
  subagent_type: architect,
  model: sonnet,
  prompt: "
Mission: <one-sentence goal from classify>

Full mission context + Graph context: read /tmp/mission-<id>.md

Read docs/handoff/<id>/context.yaml FIRST (if exists).
Respect existing \`decisions\` and \`off_limits\` absolutely.

Produce design per your role frontmatter's output format.
Write to: docs/handoff/<id>/architect.md
Last line: DELIVERABLE_COMPLETE
Chat summary back: ≤50 words + pointer to file.

Skills active: plan-review, devils-advocate, systematic-debugging, leadv2-subagent-protocol, etc. Use them.
Codebase graph project: ${LEADV2_CODEBASE_PROJECT}
",
  run_in_background: true
)
```

Agent spawns use `Agent` tool — **NOT** `claude-subsession.sh`. claude-subsession is for persona meetings only.

**For Standard class:** fire `Agent(critic, sonnet, run_in_background=true)` as 2nd brain if Codex unavailable. If Codex ran → critic reviews synthesis in Stage 2 only.

### 3. Wait for Stage 1 completion

Monitor on deliverable files:
```
Monitor:
  command: while true; do
    arch_ok=1
    [[ "<architect spawned?>" == "yes" ]] && arch_ok=0 && [[ -f docs/handoff/<id>/architect.md ]] && arch_ok=1
    [[ -f docs/handoff/<id>/codex-plan-result.md ]] && codex_ok=1
    [[ $arch_ok -eq 1 && ${codex_ok:-0} -eq 1 ]] && echo STAGE1_READY && exit 0
    sleep 10
  done
  description: "Stage 1 planning complete"
  timeout_ms: 1800000
```

### 4. Read Stage 1 deliverables + first-pass synthesis

```
# If architect spawned:
Read docs/handoff/<id>/architect.md
# Always:
.claude/scripts/cx-tail.sh /path/to/codex/output
```

Write preliminary `/tmp/critic-brief-<id>.md`:
```
Task: <id>
Mission: <original>

Architect's recommended approach: <quote 3 lines from architect.md recommendation>
(or: "no architect spawned, class=Standard")

Codex's recommended approach: <quote from codex output>

Where they agree: <list>
Where they disagree: <list — this is prime target for critic>

Your job (critic):
- Review the agreed-upon path for failure modes
- Arbitrate the disagreements (pick one or flag as unresolved)
- Apply devils-advocate 5-step protocol
- Deliverable to docs/handoff/<id>/critic.md
```

### 4b. Stage 2 — critic (sequential, after Stage 1)

```
# If class ≥ Standard:
Agent(
  subagent_type: critic,
  model: opus,
  prompt: "
Mission + brief: read /tmp/critic-brief-<id>.md

Apply devils-advocate 5-step protocol AND the codex-review / code-review-patterns skills.
Produce CHALLENGE blocks per critic role format.
Write to: docs/handoff/<id>/critic.md ending with DELIVERABLE_COMPLETE.
Chat summary: ≤50 words — just severity counts + pointer.

Skills active: code-review-patterns, codex-review, devils-advocate, systematic-debugging, leadv2-subagent-protocol.
Codebase graph project: ${LEADV2_CODEBASE_PROJECT}
"
)
```

Lead blocks on critic completion (foreground Agent). Trivial/Light skip critic entirely.

### 4c. Read critic output

```
Read docs/handoff/<id>/critic.md
```

Critical-severity CHALLENGEs → these become hard inputs to the next step's synthesis (decisions + off_limits MUST address them).

### 4d. Negative-memory pre-check (before emitting plan.steps)

Run `leadv2-negative-memory` skill before writing `plan.steps`:

1. Parse each candidate plan step's `mission` text as `approach_description`.
2. Set `current_phase: plan`, `change_kind` from `graph_footprint.change_kind` (or null).
3. Run filter against active entries in `docs/leadv2-negative-memory.yaml`.
4. Write `docs/handoff/<task-id>/negative-memory-matches.yaml`.
5. For any step with `disposition: blocked` → **do not include that step** in `plan.steps`. Replace with:
   - A Tier B decision (see `leadv2-negative-memory` skill §4) asking founder to redesign or override.
   - Or, if an obvious alternative exists, swap the approach and log `negative-memory-redesign: <NM-id>` in `decisions`.
6. For any step with `disposition: unblocked` → proceed, log `negative-memory-unblock(<NM-id>)` in context.yaml under `reviews.negative_memory`.

When `docs/leadv2-negative-memory.yaml` exists, run the filter as above; when it's absent, proceed with empty matches (no error).

### 2.5 F4 tool hints — read override before writing context.yaml

Before writing `context.yaml`, check `.claude/leadv2-overrides/toolsets.yaml` for per-repo
toolset overrides; where a phase has no override, fall back to that phase's default tool list
(intake/classify/plan are read-only incl. codebase-memory-mcp; build and review additionally
get Edit/Write/Bash or Bash; deploy is Bash+Read; close is Read+Write). Emit the merged result as
`context.yaml.allowed_tools`. Full python read snippet + the complete phase-default table: see
[REFERENCE.md](./REFERENCE.md) § F4 Tool Hints.

These hints are advisory only — subagents see them in context.yaml and use them as
preferences, not hard constraints. See subagent-preamble.md §1.1.

### 5. Synthesis → context.yaml (with YAML validation)

Write context.yaml atomically, validate schema on write (PO-057):

```bash
source "$(bash .claude/scripts/lv2 --path leadv2-helpers.sh)"
# Preferred: atomic write + schema validation in one step.
_atomic_write_yaml "docs/handoff/<task-id>/context.yaml" "$context_yaml_content" "context" || {
  echo "context.yaml schema invalid — rewrite synthesis"; exit 1
}
# If writing via Write tool (LLM session), validate immediately after:
leadv2_validate_handoff docs/handoff/<task-id>/context.yaml context || {
  echo "context.yaml schema invalid — rewrite synthesis"; exit 1
}
```

Top-level keys required in the synthesized file: `task` (id/class/mission/started_at),
`decisions` (union of all three sources, each with `id`/`topic`/`choice`/`rejected`/`source`,
plus a mandatory `capability-search` entry per step 2b — reuse-vs-build check before custom
code), `off_limits` (union of all three sources), `research` (one pointer per source —
architect/critic/codex — each with a `summary` + `file` anchor into their deliverable),
`plan.steps` + `plan.parallel_groups`, `reviews` (empty, filled in Phase 5), `allowed_tools`
(from step 2.5), and `verification` (`live_signal`, `probe`, `timeout`, plus an optional
additive `criteria[]` of programmatic/judge/human checks — schema at
`contracts/context.verification.schema.json`).

Full field-by-field YAML template with inline comments for every key above: see
[SCHEMAS.md](./SCHEMAS.md) § context.yaml Schema.

### Plan schema (mandatory for every step)

Each `plan.steps[i]` MUST contain:
- `id` — int
- `mission` — concrete description, ≥30 words, no «developer decides» / «figure out»
- `reads` — list of file paths to read FIRST (≥1 entry; pure-new-file steps may use `[]` with explicit comment)
- `writes` — list of files to create/modify
- `acceptance` — ≥1 verifiable check: shell command, grep pattern, mypy/pytest invocation
- `tests` — optional, expected for new logic

A step missing any required field is invalid. Lead must reject the plan and re-prompt the planner.

### Validation before writing context.yaml

Run this snippet immediately after drafting `plan.steps` and before calling `_atomic_write_yaml`:

```bash
python3 -c "
import yaml, sys
d = yaml.safe_load(open('docs/handoff/<task-id>/context.yaml'))
required = {'id','mission','reads','writes','acceptance'}
for i, s in enumerate(d.get('plan',{}).get('steps', []) or []):
    missing = required - set(s.keys())
    if missing:
        print(f'STEP {i} missing: {missing}', file=sys.stderr); sys.exit(1)
    if len(str(s.get('mission','')).split()) < 30:
        print(f'STEP {i} mission too short (<30 words)', file=sys.stderr); sys.exit(1)
print('plan schema OK')
"
```

If validation fails → rewrite the offending steps before proceeding to Gate 1.

### 6. Arbitration — when the three disagree

| Disagreement | Action |
|---|---|
| architect chose A, codex chose B, critic agrees with architect | Go with A. Cite in decisions: "arbitration: 2-of-3 for A". |
| All three chose different | Round 2: `codex-task.sh task --effort medium` (default model) with summary of all 3 → tie-break. |
| architect and codex still disagree after R2 | `AskUserQuestion` to founder with both options + recommendation (lead's pick with rationale). |
| Critic flags the recommended approach with Critical risk | Re-spawn architect(opus) with critic's concern → single revision round → re-read. |

### 7. Pre-mortem — build phase check

After context.yaml is written but BEFORE proceeding to Gate 1 / Build:

```bash
bash .claude/scripts/lv2 leadv2-premortem.sh \
  --task-id <task-id> \
  --phase build
pm_rc=$?
```

| Exit | Verdict | Action |
|---|---|---|
| 0 | proceed | Normal flow to Gate 1 |
| 1 | proceed_with_caution | Spawn extra critic pass reviewing plan complexity (Stage 2b re-run with focus on failure modes) |
| 2 | skip_recommended | Tier B pause — "Premortem says &lt;pct&gt;% build success — skip / continue / redesign?" (default=redesign via architect) |

Record `premortem_build_verdict` in `LEAD_V2_STATE.md` step note.

### 7.5. Founder-alignment check (before Gate 1)

If `class==Heavy` AND `LEADV2_DAEMON!=1`: invoke the `grilling` skill to align requirements with the founder before Gate 1.

### 8. State update

```
LEAD_V2_STATE.md:
  phase: plan
  step: synthesis_complete
  note: "context.yaml written, decisions: N, off_limits: M, premortem_build: <verdict>"
```

```bash
source "$(bash .claude/scripts/lv2 --path leadv2-helpers.sh)" && leadv2_active_update_phase build
```

Proceed to Phase 3 Gate 1.

## Rules

- **Parallel in ONE message.** Serial triad wastes wall time.
- **Synthesis is lead's job.** Do not paste subagent output into context.yaml verbatim.
- **decisions and off_limits are union** with arbitration — when two conflict on same topic, only one wins (cite).
- **Codex round 2** only for arbitration — not for depth. Use default model with `--effort medium` for speed (spark banned).
- **Budget: max 2 Opus subsessions in Plan phase.** More → AskUserQuestion.

## Code-quality checks (architect must enforce in plan.steps)

- Functions ≥10 LOC must be exported from their module (not inlined inside route handlers / class bodies). Test files must IMPORT the production function, not redefine a local copy. If a test-local copy is intentional (e.g. fixture builder), mark it with header comment `# LOCAL COPY — keep in sync with <file>:<line>`.

## Anti-patterns

- Spawning one-by-one "to see what each says" — kills parallelism, burns wall time.
- Writing context.yaml without reading all three deliverables — guaranteed missing off-limits.
- Treating codex as tie-breaker when architect+critic agree — that's re-work for nothing.
- Adding new `decisions` later in Build phase — violates append-only rule. Re-open Gate 1 instead.
