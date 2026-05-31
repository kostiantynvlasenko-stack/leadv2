# leadv2 Phase Detail Reference

Phase names are the contract with commands/leadv2.md — rename in lockstep.

This file is **lazy-loaded** — never auto-injected into Messages. Lead reads `§Phase N` slices on demand via `Read offset/limit`. Do not preload the whole file.

---

## §Routing

Agent tool is the default. claude-subsession ONLY for task-queue meetings (PO/architect/strategist) where persistent memory across turns is needed. Prompt-cache mechanics → `docs/leadv2-guide.md §Caching`.

---

## §Startup

**Never read .sh / .py / .ts / .sql files directly** — use `Agent(subagent_type=Explore, model=haiku)` or MCP `get_code_snippet` instead. Direct code reads are blocked by `leadv2-lead-read-guard` hook. For OPS tasks needing deploy script context: delegate to Explore before Phase 1.

**Explorer output → developer mission directly.** After Explore returns file paths + line numbers, write the developer mission immediately using those coordinates. Do NOT `Read` the files Explore found — developer reads its own context. Orchestrator `Read` calls are only allowed for: `STATE.md`, mission templates, `MEMORY.md`, `context.yaml` — not for source code files that will be passed to a developer subagent.

**Lazy reads — load ONLY when triggered:**
- Full LEAD_V2_STATE: `Read docs/LEAD_V2_STATE.md` (file is now <40 lines, safe to read whole). Only if compact helper missed a field you need.
- Full task list: `source ${CLAUDE_PLUGIN_ROOT}/scripts/leadv2-tasks-lib.sh && leadv2_tasks_top_n 20`. Only if top-5 isn't enough to choose.
- Closed-task lookup: `Read docs/leadv2/queue/_archive/QUEUE-archive-<DATE>.md` — when user asks about a shipped task.
- `.claude/ref/lead-patterns.md limit=50` — when entering Phase 1 Classify
- `docs/agents/architect/STATE.md limit=30` — when classification == Heavy OR arch keyword matched
- `docs/ops/RECOVERY_TRACKER.md limit=15` — when LEAD_V2_STATE `note:` mentions open RECOVERY items

**Queue staleness compute:** `(today - last_queue_sync) > 14d` OR `sessions_since > 10` → trigger queue-meeting before propose.

---

## §Invocation

**Reply mode** (`/leadv2 reply <q-id> <option>`): Detect if args start with `reply`. Extract `<q-id>` and `<option>`. Resolve task-id via content-based grep: `grep -rl "qid:.*${qid}" docs/handoff/*/questions-async/*-pending.yaml | head -1`. If ambiguous (multiple matches) or not found, hard-fail with Russian error. Call `bash "${CLAUDE_PLUGIN_ROOT}/scripts/leadv2-reply.sh" --task-id <task_id> <q-id> <option>`. Exit immediately — do NOT enter 9-phase loop.

**Pulse-mode** (`LEADV2_PULSE_MODE=1`): **On by default** (project env sets `LEADV2_PULSE_MODE=1`). Disable with `LEADV2_PULSE_MODE=0`.

Each phase entry calls `leadv2_pulse_log "<phase>" "<one-line summary>"` — emits ≤80-byte line to `docs/leadv2/tasks/<task_id>/pulse.md` AND to chat. Subagent deliverables stay on disk; lead reads ONLY `summary_for_lead:` field via `Read limit=10`.

**SILENCE PROTOCOL (enforced when LEADV2_PULSE_MODE=1):**
- **ZERO free-form text to chat.** No explanations. No "I'm now doing X". No thinking out loud. No status updates. No summaries between phases.
- Permitted chat output: (1) pulse lines ≤80 chars, (2) Gate 1 single-line prompt + wait, (3) Phase 8 close: max 3 lines total, (4) async question prompt when founder input required.
- Every additional sentence is a protocol violation. Silence between phases is correct behavior.
- Protocol details → `docs/leadv2-guide.md §Pulse-mode`.

**Env:**
- `LEADV2_DRY_RUN=1` — phases run, spawns/deploys are echoed not executed
- `LEADV2_DAEMON=1` — daemon mode: Gate 1 auto-accepts, self-spawn after Phase 8 close
- `LEADV2_GATE1_AUTO_ACCEPT_SEC=N` — Gate 1 timeout in daemon mode (default 5s; Heavy always blocks)
- `LEADV2_GATE1_HEAVY_TIMEOUT_SEC=N` — Gate 1 timeout for Heavy tasks in daemon mode (default 60s; 0 = immediate auto-accept). Only applies when LEADV2_DAEMON=1.
- `LEADV2_MAX_SELF_SPAWNS_PER_DAY=N` — daily self-spawn cap (default 4)
- `FORCE_OPUS_LEAD=1` — force orchestrator to Opus model
- Note: `LEAD_V2_DAEMON` is a deprecated alias for `LEADV2_DAEMON` — use `LEADV2_DAEMON`


---

## §Phase 0: INTAKE

- **Pre-flight git-log check (BEFORE worktree create):** `bash "${CLAUDE_PLUGIN_ROOT}/scripts/leadv2-preflight-gitlog.sh" "$LEADV2_TASK_ID"`. Exit 2 → surface oneline commits to founder via single AskUserQuestion (`already-shipped → admin-close` vs `continue anyway`). Saves the entire setup cycle on already-landed tasks.
- **Parallel-session collision sniff:** `bash "${CLAUDE_PLUGIN_ROOT}/scripts/leadv2-collision-check.sh"`. Exit 2 → log warning into pulse + plan rebase-flow vs ff-merge BEFORE EnterWorktree.
- **Immediately after user picks a task** (before any other work): write provisional entry to `docs/leadv2/active.yaml` so other sessions see it claimed:
  ```bash
  python3 -c "
  import yaml, datetime, os, sys
  f='docs/leadv2/active.yaml'
  d=yaml.safe_load(open(f)) if os.path.exists(f) else {'meta':{},'sessions':[]}
  tid=sys.argv[1]
  if not any(s.get('task_id')==tid for s in d.get('sessions',[])):
    d.setdefault('sessions',[]).append({'task_id':tid,'phase':'intake','pid':os.getpid(),'started_at':datetime.datetime.utcnow().isoformat()+'Z','status':'claimed'})
    yaml.dump(d,open(f,'w'))
  " "$LEADV2_TASK_ID"
  ```
- `LEADV2_MAIN_MODEL=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/leadv2-main-model-check.sh")` — pick orchestrator model
- `source "${CLAUDE_PLUGIN_ROOT}/scripts/leadv2-helpers.sh" && leadv2_lock_acquire || exit` — per-task lock (delegates to `leadv2_active_register` in active.yaml)
- `bash "${CLAUDE_PLUGIN_ROOT}/scripts/leadv2-stale-sweeper.sh"` — surface stale sessions at startup; ghost-spawn reconciliation
- `leadv2_threshold_warn_if_inverted || true` — sanity check
- `leadv2_live_update intake startup` — LIVE tracker
- `export LEADV2_TASK_ID=<id> && "${CLAUDE_PLUGIN_ROOT}/scripts/leadv2-mcp-cache.sh" warm <id>` — warm MCP cache, then dispatch standard queries (detect_changes, get_architecture) and write results via `leadv2-mcp-cache.sh set`
- Determine task source (user / task-queue / RECOVERY)
- If queue cache stale → `leadv2-subsession` skill
> **Optimization:** Run `lead-classify` skill FIRST (Phase 1), then execute EnterWorktree + MCP warm only if class ≥ Standard. This avoids ~2K tokens of worktree setup for Trivial/Light tasks. If classify returns Trivial/Light → jump directly to Phase 4 Build without worktree.

- **Enter worktree:** `EnterWorktree(name="<task-id>")` — creates `.claude/worktrees/<task-id>` on branch `task/<task-id>` off current HEAD. Session cwd switches into it. ALL Phase 1-5 edits and commits happen here. Skip for `Trivial/Light` tasks where deploy isn't expected (worktree adds friction). Skip if user's invocation is `/leadv2 status`/`help`/`meeting`/`questions`/`sessions`.
- Write per-task state: `docs/leadv2/tasks/<id>/STATE.md` — `status: active, phase: intake`. `docs/LEAD_V2_STATE.md` is auto-regenerated via `leadv2_active_render_index` (DO NOT EDIT directly).
  **STATE.md schema (required fields):**
  ```
  status: active
  phase: intake          # updated at every phase boundary
  class: <Trivial|Light|Standard|Heavy>
  goal: <goal condition string>   # e.g. "docs/handoff/<id>/phase8-passed.flag exists"
                                  # stored so PostCompact hook can re-inject it after /compact
  ```
  Write `goal:` at intake time. The PostCompact hook (`leadv2-postcompact-goal-reinject.sh`) reads this field and re-injects phase + goal into model context after every compaction, preventing mid-pipeline disorientation.


---

## §Phase 1: CLASSIFY

- **Classify task inline** (no separate skill in v0.1): assign one of `Trivial` (≤1 line / typo / comment), `Light` (≤30 lines, single file, no migrations), `Standard` (multi-file or schema-adjacent), `Heavy` (architectural / cross-cutting / risky). Write `class:` to `docs/leadv2/tasks/<id>/STATE.md`.
- Trivial/Light → skip to Phase 4 Build directly. Standard+/Heavy → continue.
- **Scope-creep regex check (inline, Standard+ only).** Scan brief text for: `\b(across|all)\s+personas\b`, `layer\s*[123]`, `strategic\s+(and|\+)\s+tactical`, plus project-specific noun count ≥2 (nouns sourced from `scope_terms` in `.claude/leadv2-overrides/stack.yaml`; fallback: empty list — generic repos add nothing). Load extra nouns via: `source "${CLAUDE_PLUGIN_ROOT}/scripts/leadv2-helpers.sh" && SCOPE_TERMS=$(_lv2_stack_list scope_terms "")`. Build per-noun patterns dynamically: for each term in `$SCOPE_TERMS`, add `affects?\s+<term>\s+too` and count bare occurrences. If ≥1 generic hit OR ≥2 project-noun hits → ONE `AskUserQuestion` with options [split per axis (recommended) / collapse — single task / downscope]. Record outcome to STATE.md `scope_decision:` and continue. 60s timeout → pick first option. Skip for `bug:` prefix. Pattern reference: `skills/leadv2-scope-creep-detector/SKILL.md`.
- (v0.2: RAG intake skill — currently inline. For now: skim `docs/leadv2/immune-memory/` for similar past failures and inject 1-3 relevant entries into `context.yaml.prior_art`.)
- Run pre-cost estimate: `bash "${CLAUDE_PLUGIN_ROOT}/scripts/leadv2-cost-estimate.sh" --task-id <id> --main-model "$LEADV2_MAIN_MODEL"`. If `within_cap: false` → escalate Tier B before Plan.


---

## §Phase 1.5: DIVERGE (optional, gated — runs before Plan)

Divergent ideation: widen the solution space with isolated frame-shifted
generators BEFORE the convergent Plan triad commits. Ported from ADHD
(UditAkhourii/adhd, MIT). Full operating contract: `Skill(skill="leadv2-diverge")`.

**Gate (evaluate in THIS order — explicit overrides class+judge but NOT Step 0):**
- **Step 0 — environment guards (block EVERYTHING, incl. explicit):** `LEADV2_DRY_RUN=1`; cost-estimate `within_cap: false`; `emergency_mode=true` / "no approvals". → no spawns; write+say `diverge: skipped (<reason>)` loudly.
- **Step 1 — explicit** `/leadv2 diverge` → run regardless of class (even Trivial/Light) and skip the self-judge.
- **Step 2 — class hard-skip (auto path):** `Trivial`/`Light`, or `bug:` WITH a known root cause → skip to Phase 2 (fuzzy bug w/o root cause is a valid use case — keep).
- **Step 3 — self-judge (auto path):** run only if ALL hold — (a) open-ended answer space, (b) high-stakes (architecture / public API / schema / migration / product naming / fuzzy bug w/o root cause / positioning), (c) open phrasing (no "quick/standard/canonical/just/one-line").
- **Step 4 — auto-fire (auto path, Step 3 passed):** `Heavy` (or `Strategic` if the repo classifier emits it) → run. `Standard` → if `LEADV2_DAEMON=1`/`LEADV2_BOT_MODE` skip without prompting, else ONE `AskUserQuestion` (default = skip, 60s). NOTE: naming/positioning/pricing often classify `Standard` and won't auto-fire — use explicit `/leadv2 diverge`. On any skip: write `diverge: skipped (<reason>)` to STATE.md, proceed to Phase 2.

**Execution (mechanical generator/critic split — isolation is load-bearing):**
1. Load frames: `${CLAUDE_PLUGIN_ROOT}/data/leadv2-frames.yaml` (+ optional repo `docs/leadv2-frames.yaml`, merged by id). Lead picks `frames_per_run` (default 5): 4 code/design + ≥1 wild for code-shaped problems; vary vs recent runs.
2. **Diverge** — ONE message, N parallel `Agent(subagent_type=general-purpose, model=sonnet, run_in_background=true)`, one per frame. Each gets ONLY: a ≤200-word problem statement + that one frame's vantage + the DIVERGENT-mode instruction (forbid evaluation, JSON array of `ideas_per_frame` ideas, first-3-obvious banned). **FORBIDDEN in a branch:** other branches' output, full/partial `context.yaml`, `prior_art`/immune/negative-memory, architect `decisions[]`, the graph-context block, BOARD/RECOVERY. Isolation is the mechanism, not a slogan. Deliverable: `docs/handoff/<id>/diverge-<frame.id>.json`.
3. **Focus** — one `Agent(subagent_type=critic, model=<opus if Heavy/Strategic else sonnet>)`: score novelty/viability/fit (weights from frames.yaml `scoring:` — 0.35/0.40/0.25), flag traps with mechanistic reasons, cluster by underlying angle. Deliverable: `diverge-focus.json`.
4. **Deepen** — top_k (default 3) parallel `Agent(general-purpose, sonnet)` on ranked non-trap leaders: sketch + load-bearing risk + first step + 3–5 child ideas. Provocation = highest-novelty leaf (no spawn).
5. **Cost banner + hard ceiling** to STATE.md before spawning: `diverge: running — ~<N+1+K> Agent spawns`. Clamp AFTER any repo override: `frames_per_run ≤ 8`, `ideas_per_frame ≤ 12`, `top_k ≤ 5`, total `frames+1+top_k ≤ 14`. If near budget, drop to 3×4 (~7 spawns) and note reduced breadth.

**Exit:** `docs/handoff/<id>/divergence.md` (wide-set clustered + ★shortlist + traps + deepened + provocation) AND a compact `divergence:` block in `context.yaml` (`shortlist[]`, `non_obvious_pick`, `traps[]`, `artifact:` path, ≤40 lines). Phase 2 architect consumes it (see leadv2-plan §1c).


---

## §Phase 2: PLAN

**Route first:** `eval "$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/leadv2-router.sh" --phase plan --step <step> --task-id <id> --class <class> --signals '{...}' 2>/dev/null)" || true` (exit 2 = fall through to class-based default).

**Single message, parallel spawns:**
1. `${CLAUDE_PLUGIN_ROOT}/scripts/leadv2-codex-planner.sh --task-id <id> --mission-file /tmp/mission-<id>.md --effort <high|xhigh>` — background, **only if** `command -v codex-task.sh >/dev/null 2>&1 && codex-task.sh status >/dev/null 2>&1` exits 0 (requires Codex CLI installed; see docs/INSTALLATION.md). If unavailable → skip, Agent(critic) covers Stage 1.
2. `Agent(subagent_type=architect, model=opus, run_in_background=true)` — if Heavy or arch keyword (NOT claude-subsession)
3. `Agent(subagent_type=critic, model=opus, run_in_background=true)` — if class ≥ Standard; use `model=sonnet` when Codex already fired and task is Standard (not Heavy)

**MANDATORY after Codex launch (step 1):** Codex does NOT send task-notifications. Capture the task ID printed by `leadv2-codex-planner.sh` (first token on stdout, e.g. `task-abc123`), then immediately spawn a Monitor using the real ID:
```bash
# CODEX_PLAN_ID = actual task-id printed by leadv2-codex-planner.sh
Monitor(
  command="for i in $(seq 1 20); do codex-task.sh status \"$CODEX_PLAN_ID\" 2>/dev/null | grep -q 'Phase: done' && { echo \"CODEX_PLAN_DONE: $CODEX_PLAN_ID\"; exit 0; }; sleep 30; done; echo \"CODEX_MONITOR_TIMEOUT: $CODEX_PLAN_ID\"; exit 1",
  description="Codex planner $CODEX_PLAN_ID completion",
  timeout_ms=600000,
  persistent=false
)
```
On `CODEX_PLAN_DONE`: read `cx-tail.sh` on the log file and proceed to Stage 2 critic **in the same turn**.
On `CODEX_MONITOR_ERROR` or timeout: read the log file directly with `Read offset=-100` to extract whatever findings exist; proceed anyway — do not block.

Wait via Monitor on output files. When complete: read deliverables via `bash "${CLAUDE_PLUGIN_ROOT}/scripts/critic-tail.sh" <file>` (Verdict + summary_for_lead + severity counts only). Full read ONLY if verdict signals REVISE/no-ship. Synthesize into `docs/handoff/<id>/context.yaml`.

**Disagreement / multi-decision flow:** when synthesizing requires founder input on ≥2 decisions, batch them into ONE `AskUserQuestion` call (up to 4 questions) — never serial questions in separate turns. Material disagreement → 2nd Codex round (default model, `--effort medium`).

**Mission file builder rule (MANDATORY before each spawn):**
- Each subagent gets a per-role mission file scoped to its slice — `decisions[]` relevant to role + `off_limits` for role + `plan.steps` owned by role. Do NOT inject the full context.yaml.
- Hard cap ≤100 lines: `bash "${CLAUDE_PLUGIN_ROOT}/scripts/leadv2-mission-lint.sh" <file>` exit 0 required.
- Lead's spawn prompt ≤300 words: pipe the prompt body through `bash "${CLAUDE_PLUGIN_ROOT}/scripts/leadv2-prompt-lint.sh"` before invoking Agent. Lead orients (worktree path, branch, project hint, deliverable path, word cap); the subagent reads context.yaml + mission itself.
- Mission template: `.claude/templates/mission-template.md`. Always includes `No extended thinking unless context.yaml.explicit_reason_required=true` and `Output: minimal-diff sections only — never full-file rewrites`.

**Auto-compact before Phase 4 (Heavy/Standard tasks):**
After Gate 1 accepted and context.yaml written, trigger compaction if ctx > 120K:
```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/leadv2-compact-trigger.sh" --phase post-plan --task-id "$LEADV2_TASK_ID" || true
```
All plan artifacts are on disk (architect.md, context.yaml, codex-plan-result.md). Safe to compact — Phase 4 reads from files, not from context.


---

## §Phase 3: GATE 1

**Verify plan completeness inline** (no separate skill in v0.1): `context.yaml` must have `decisions[]` non-empty, `off_limits[]` populated (even if empty list is intentional), `plan.steps[]` with ≥1 step, and a risk summary. Block Gate 1 if any are missing.

**Gate 1 mechanism** (uses `leadv2-gate1-prompt.sh`):
- Non-Heavy: auto-accept after LEADV2_GATE1_AUTO_ACCEPT_SEC (default 5s)
- Heavy: auto-accept after LEADV2_GATE1_HEAVY_TIMEOUT_SEC (default 60s) when LEADV2_DAEMON=1; blocks indefinitely when DAEMON=0
- Standard interactive: one terse line + 60s timeout → auto-accept.
- `LEADV2_DRY_RUN=1`: immediate auto-accept, print plan only.

`bash "${CLAUDE_PLUGIN_ROOT}/scripts/leadv2-gate1-prompt.sh" "$LEADV2_TASK_ID" "$CLASS" "$PLAN_SUMMARY"`
Exit 0 = accepted, 1 = declined → iterate plan once or pivot, 2 = auto-accepted.

Update `docs/leadv2/tasks/<id>/STATE.md` gate_1.status=confirmed. `leadv2_active_update_phase <id> build`.

---

## §Phase 4: BUILD

**Route first:** `eval "$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/leadv2-router.sh" --phase build --step <step> --task-id <id> --class <class> --signals '{"total_lines":<N>,"change_kind":"<kind>"}' 2>/dev/null)" || true`. Honor `ceiling_status`: `warn_60pct` log warning, `hard_stop_95pct` exit 1.

**Autonomous completion loop (`LEADV2_DAEMON=1` only):**
After Gate 1 is confirmed, set the `/goal` loop:
```
/goal docs/handoff/$LEADV2_TASK_ID/phase8-passed.flag exists, or stop after 140 turns
```
Rationale:
- An independent Haiku evaluator checks the goal condition between every turn — catches mid-pipeline stalls that the orchestrator would otherwise miss.
- The goal survives compaction: if `/compact` fires, `leadv2-postcompact-goal-reinject.sh` (PostCompact hook) re-reads `goal:` from `docs/leadv2/tasks/<id>/STATE.md` and re-injects task id, phase, and goal condition into context.
- Scoped to `$LEADV2_TASK_ID` to prevent daemon self-spawn cross-talk (each task's flag path is unique).
- Set after Gate 1 to avoid `AskUserQuestion` sequencing conflict: `/goal` starts the evaluator loop; if set before Gate 1, the evaluator turn fires before the founder can respond to the plan prompt.
- Interactive mode: `/goal` is optional, BUT the orchestrator SHOULD self-set it (without asking the founder) for any Standard+/Heavy task it judges at stall-risk — same condition + turn cap. Full rubric: `docs/goal-workflow-autonomy.md`.

**Pre-spawn for parallel groups (≥2 groups in plan.parallel_groups):**
1. Lead writes `docs/handoff/<id>/groups-contract.md` per `.claude/templates/groups-contract.md`. Include producer/consumer signatures, output formats, and `external_callers_to_update` enumerated via ONE global grep before spawn. Catches the "Group A flags work for Group B" drift class.
2. Each group's mission must reference its slice of the contract. Lead lints with `leadv2-mission-lint.sh` + `leadv2-prompt-lint.sh` before each spawn.

Parallel Agent spawns per `context.yaml plan.parallel_groups:` — developer / postgres-pro / frontend-developer. **All spawns `run_in_background=true`.** Monitor via task-notification. **Verify diffs with `git diff` — don't trust DONE self-report.** Stuck Sonnet → escalate to claude-subsession or opus architect.

**Post-build (BEFORE Phase 5):**
- (v0.2: deliverable-routing-check script — currently manual. Read `docs/handoff/<id>/build-*-output.md` files and check `external_callers_to_update` from groups-contract for any "punted to Group B" items. Resolve before opening review.)
- `bash "${CLAUDE_PLUGIN_ROOT}/scripts/leadv2-negative-memory-trigger-scan.sh" --task-id "$LEADV2_TASK_ID"` — exit 2 → diff matched a regex-tagged negative memory entry; surface NM-id + run leadv2-negative-memory unblock check before commit.
- **After Build (class ≥ Standard, source files touched):** run the project's test suite (`pytest` / `go test` / `pnpm test` per `stack.yaml`). Coverage < 50% on changed lines → circuit break and add tests before Phase 5. (v0.2: dedicated `leadv2-test-synthesis` skill.)


---

## §Phase 5: REVIEW

**Route first:** `bash "${CLAUDE_PLUGIN_ROOT}/scripts/leadv2-router.sh" --phase review --step <step>`. `model=skip` → no review (CX-03 light_low_risk). `model=codex-adversarial` → Codex only. `model=codex+opus-critic+security-auditor` → full triad.

Parallel in one message:
- `codex-task.sh adversarial-review --wait --base main` — background, always when not skipped (requires Codex CLI on PATH)
- Agent(critic, opus) via claude-subsession — if safety/auth/RLS/publish touched
- Agent(security-auditor, sonnet) via Agent tool — if secrets/webhook/auth touched

**Reading review deliverables:** `bash "${CLAUDE_PLUGIN_ROOT}/scripts/critic-tail.sh" <file>` returns Verdict + summary_for_lead + Critical/High/Medium counts. Full body read ONLY when verdict signals REVISE/no-ship. Mirror cx-tail.sh discipline — never `Read` the whole review file by default.

**Severity gating — read before iterating:**

- Parse codex output for `[critical]` and `[high]` tags. Count blocking findings = `count([critical]) + count([high])`.
- **Blocking == 0** → ACCEPT regardless of verdict text. Append findings to `docs/handoff/<id>/followups.md` with severity tags. **Move to Phase 6 Deploy.** Do NOT spawn another developer round.
- **Blocking >= 1** → spawn developer fix → Codex round 2 (`--effort medium`).

**Round cap (HARD):**

- Max 2 codex rounds with developer iteration. Round 3+ is FORBIDDEN.
- After Round 2 still blocking → **mandatory** `Skill(skill="leadv2-judge-review")`. Judge returns one of: `accept-with-caveats` (move to Deploy with caveats logged) / `architect-alt-approach` (Phase 7 Recovery) / `abort-task` (circuit break + AskUserQuestion).
- Lead does NOT decide between these itself. Lead just dispatches the skill and reads its verdict.

If the lead has already produced `developer-r3.md` or `codex-review-r3.md` for this task, the cap was already missed — call `leadv2-judge-review` immediately and stop spawning developer.


---

## §Phase 6: DEPLOY

Preconditions (ALL must pass, all run from inside worktree):
- All Critical/High resolved or TODO-filed
- Tests pass (Agent(developer, sonnet, "run tests, quote output"))
- `git diff` non-empty matching expected files
- `bash "${CLAUDE_PLUGIN_ROOT}/scripts/leadv2-offlimits-check.sh"` — exit 0 OK; exit 2/3 → block deploy

**Devops mission injection:** before spawning devops-engineer, run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/leadv2-known-quirks-inject.sh"` and append the matched `instruction:` lines into the devops mission `§discipline` block.

If all pass — three steps:
1. **Commit in worktree:** `Agent(devops-engineer, sonnet, "commit conventional msg in current worktree directory")`. Worktree branch = `task/<task-id>`.
2. **Exit worktree (keep):** `ExitWorktree(action="keep")` — **lead calls this directly, never delegated to subagent.** Return to main repo dir, leave worktree on disk. Delegating ExitWorktree (or `git worktree remove`) to a subagent causes `ENOENT: posix_spawn '/bin/sh'` hook errors because the harness spawns hooks against a deleted CWD.
3. **Fast-forward main + push + deploy** (in main repo dir):
   ```bash
   git fetch origin main
   git checkout main 2>/dev/null || true
   git pull --ff-only origin main || { echo "main moved during task — manual rebase needed"; exit 1; }
   git merge --ff-only "task/$LEADV2_TASK_ID" || { echo "ff-only merge failed — rebase task branch first"; exit 1; }
   git push origin main
   COMMIT=$(git rev-parse HEAD)

   # Apply + register any new migrations introduced by this commit.
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/leadv2-migration-apply.sh" --commit "$COMMIT" || {
     echo "BLOCK: migration apply/register failed — manual /migrate repair before deploy" >&2
     exit 1
   }

   # Deploy via project override (required — configure in .claude/leadv2-overrides/deploy.sh)
   OVERRIDE="${CLAUDE_PROJECT_ROOT:-$PWD}/.claude/leadv2-overrides/deploy.sh"
   if [[ -f "$OVERRIDE" ]]; then
     LEAD_V2_TASK_ID="$LEADV2_TASK_ID" LEAD_V2_COMMIT="$COMMIT" bash "$OVERRIDE"
     deploy_rc=$?
   else
     echo "BLOCK: .claude/leadv2-overrides/deploy.sh not found — run leadv2-init or create it" >&2
     exit 1
   fi
   [[ $deploy_rc -eq 0 ]] || { echo "Deploy failed (exit $deploy_rc)" >&2; exit 1; }
   echo "Deploy complete (commit $COMMIT)"
   ```
   Run via `Agent(devops-engineer, sonnet)`. The ff-only failure surfaces parallel-session collisions. Project-specific deploy logic lives in `.claude/leadv2-overrides/deploy.sh`.

Any precondition or merge fail → circuit break. Worktree stays on disk for inspection.

---

## §Phase 7: LIVE VERIFY

`leadv2-verify` skill — invoke `verify-probe.sh` per `context.yaml verification.live_signal`. Heavy tasks → corroborate config (positive + ≥1 no-regression). Default timeout 30min.
- Exit 0 → Phase 8 Close
- Exit 1 (timeout) → `Skill(skill="leadv2-iterative-recovery")` (layer-peeling fix+verify loop, hard cap 5). On exhaustion → architect opus alt approach → execute → re-verify. Max 2 alt attempts → circuit break
- Exit 2 (negative signal) → immediate `leadv2-rollback.sh` → architect recovery loop


---

## §Phase 8: CLOSE


**Order matters.** Do the writes (per-task STATE, LEAD_V2_STATE history, BOARD HEAD,
DIALOGUE outcome, active.yaml unregister) **before** running the gate.
The gate is a verifier, not a doer — it asserts artifacts exist; if any are missing
it exits 1 with the list, and any close-commit push will be blocked by the hook.

### Writes (do these first)
- If project has `docs/BOARD.md` — rewrite HEAD; otherwise skip
- Run `lead-reflect` skill → append to `docs/leadv2/tasks/<id>/STATE.md` history (`status: closed`)
- If project has `docs/agents/product-owner/DIALOGUE.md` — append outcome; otherwise skip
- Update `docs/LEAD_V2_STATE.md` history with `<task_id> ✅ <date> — <summary>`
- `leadv2_active_unregister "$LEADV2_TASK_ID"` — remove from `docs/leadv2/active.yaml`

### Gate (mandatory before any close-commit push)
- **`bash "${CLAUDE_PLUGIN_ROOT}/scripts/leadv2-phase8-close.sh" "$LEADV2_TASK_ID"`** — runs `leadv2-render-close.sh`, then calls `leadv2-phase8-assert.sh` (G2) which asserts all 4 hard-gate close-phase artifacts exist:
  1. `docs/leadv2/closed/<task_id>.yaml` exists (the source-of-truth close record) — A1
  2. `docs/leadv2/tasks.yaml` has `status: closed` (or task absent) — A2
  3. `docs/leadv2/active.yaml` does NOT contain task_id (unregistered) — A3
  4. `docs/LEAD_V2_STATE.md` history has `<task_id> ✅` — A4

  Best-effort warnings (non-blocking): BOARD.md HEAD (if exists), DIALOGUE.md entry (if exists), per-task STATE.md status.
  Writes sentinel `docs/handoff/<task_id>/phase8-passed.flag` on PASS. Exits 1 with missing-item list on FAIL. Exit 2 = bad usage.
- **Two scripts, two roles** — do not confuse:
  - `"${CLAUDE_PLUGIN_ROOT}/scripts/leadv2-phase8-assert.sh"` — G2 assertion runner (the gate logic, 4 hard checks)
  - `.claude/hooks/leadv2-phase8-gate.sh` — PreToolUse push-blocker hook (blocks `git push` when sentinel missing/stale)
- The PreToolUse hook `leadv2-phase8-gate.sh` blocks `git push origin main` for any unpushed commit whose message contains both `leadv2` and `close` (or `Phase 8`) **unless** the sentinel for the matched `PO-XXX` exists and is < 1h old.
- If the gate fails: read the missing list, fix the artifact, re-run the gate. Don't bypass.

### Other close-phase tasks
- `leadv2_live_update close finalizing`
- `leadv2_active_render_index` — regenerate docs/LEAD_V2_STATE.md (or hand-edit acceptable; gate will catch missing entries)
- **Self-spawn next task (daemon mode only):**
  ```bash
  if [[ "${LEADV2_DAEMON:-0}" == "1" ]]; then
    SPAWNS=$(cat docs/leadv2/spawns-today.txt 2>/dev/null || echo 0)
    MAX="${LEADV2_MAX_SELF_SPAWNS_PER_DAY:-4}"
    if [[ $SPAWNS -lt $MAX ]]; then
      NEXT=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/leadv2-queue-claim.sh" --by "$LEADV2_TASK_ID" 2>/dev/null) && _claim_rc=0 || _claim_rc=$?
      if [[ "$_claim_rc" -eq 2 || -z "$NEXT" ]]; then
        # exit 2 = no work across all lanes — nothing to spawn
        true
      elif [[ "$_claim_rc" -ne 0 ]]; then
        # real error — skip self-spawn this cycle
        true
      else
        # NEXT = "lane:id" — pass the id portion to spawner
        _next_id="${NEXT#*:}"
        bash "${CLAUDE_PLUGIN_ROOT}/scripts/leadv2-session-spawner.sh" "$_next_id" \
          && echo $((SPAWNS+1)) > docs/leadv2/spawns-today.txt
      fi
    fi
  fi
  ```
- **Worktree cleanup (success path only):** call the hardened helper (path-escape guarded, `--force` aware):
  ```bash
  bash "${CLAUDE_PLUGIN_ROOT}/scripts/leadv2-worktree-cleanup.sh" --name "$LEADV2_TASK_ID"
  ```
  It runs `git worktree remove --force .claude/worktrees/<name>` + `git branch -d task/<name>` internally (branch delete is safe — already merged in Phase 6). Skip cleanup if recovery/rollback happened — leave worktree + branch for inspection.
- **Pattern promotion:** scan history. ≥`$PROMOTE_T` (default 3) → promote to `lead-patterns.md`. ≥`$SYNTH_T` (default 5) → `leadv2-skill-synthesize` (shadow → 5 silent uses → activate). Founder approves first-time activation.
- **Heavy tasks:** `bash "${CLAUDE_PLUGIN_ROOT}/scripts/leadv2-outcome-watch.sh" --task-id <id> --delay-hours 48 &`
- `bash "${CLAUDE_PLUGIN_ROOT}/scripts/leadv2-signatures-aggregate.sh"` — refresh promotion candidates
- Cost-accuracy feedback: full Python snippet → `docs/leadv2-guide.md §Cost accuracy`. Run it.


---

## §Phase 9: PROPOSE NEXT

**Interactive mode:** Read task queue top → propose → wait for confirmation.
**Daemon mode (`LEADV2_DAEMON=1`):** next task was already spawned in Phase 8. This phase is a no-op — the child session runs independently.
Nightly maintenance: signature decay + unanswered decisions surface.
`/leadv2 questions` — list all `docs/handoff/*/questions/*-pending.yaml` across active tasks.

**Stuck escalation (any phase):** `leadv2-founder-input` skill — writes decision YAML, blocks phase, AskUserQuestion to founder.


---

## §Spawn-hygiene

**Chat budget per spawn:** task-notification (≤100 words) + `Read limit=30` summary + synthesis = ~200 words. Without this rule: ~2000 words.
