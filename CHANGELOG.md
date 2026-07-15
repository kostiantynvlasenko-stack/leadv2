# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- **Pulse hook gagged the supervisor (LEAD-ANCHOR-01)** — `leadv2-lead-prose-guard.sh`
  (Stop hook) hard-blocked status reports and child-question forwards with `continue:false`
  because it had no notion of supervisor mode. Fixed: (a) skip entirely when
  `>=2` live-pid sessions are registered in `active.yaml` (fan-out/supervise) or
  `LEADV2_SUPERVISOR_MODE=1`; (b)/(c) skip when the turn is prefixed `[STATUS]` or
  `[QUESTION-FWD]`; base caps raised 80->120 words everywhere (founder must actually
  receive statuses, not just terse ones). Same exemptions mirrored into the advisory
  `leadv2-pulse-enforcer.sh` (UserPromptSubmit) to stop noisy false-positive warnings.
  Lesson: any hard word-cap enforcement on the lead needs an explicit supervisor/forward
  escape hatch from day one — silence protocols and human-in-the-loop reporting are in
  direct tension and the silence protocol will always win by default.
- **Fanned-out child session showed the greeting picker instead of claiming its task
  (LEAD-ANCHOR-01)** — `/leadv2 <task-id>` (used verbatim by `leadv2-fanout.sh` headless
  launch: `claude -p "/leadv2 ${tid}"`) fell through to the same `AskUserQuestion` greeting
  picker as a bare `/leadv2`, so a headless child with no human to answer it sat stalled
  indefinitely (`f83037a57907`, 2.5h). Fixed: `commands/leadv2.md` session-startup section
  now states explicitly that an explicit task-id argument (or `LEADV2_ASYNC_QUESTIONS=1`)
  must claim Phase 0 immediately and skip the picker; `leadv2-fanout.sh`'s headless launch
  now also sets `LEADV2_ASYNC_QUESTIONS=1` so the behavior is structural, not just prompt-level.
  Lesson: any invocation path a human never sees (headless/background) must be structurally
  exempted from every interactive-choice affordance, not just "well-behaved by convention."

- **Route-bandit never learned (PLUGIN-MONITOR-20260614)** — `leadv2-phase8-close.sh`
  spawned the bandit `update` with a trailing `&` that raced ahead of the
  `flock`-protected scorecard append, so `update` found no row and skipped every
  time (`total_updates` stuck at 0 since seeding). Update now runs synchronously
  under `timeout 30`, non-blocking to close. Inline `bandit_reward_composite` in
  `leadv2-scorecard-write.sh` made byte-equivalent to canonical
  `compute_reward()` (the `ce==0 → cost_eff=1.0` branch was dropped, drifting
  arm priors under `PE_BANDIT_VALUE_WEIGHT`). NOTE: bandit still won't learn
  until `select-for-workflow` (writes `route-decisions.yaml`) is actually invoked
  before `Workflow()` — currently documented but unenforced (follow-on).
- **`leadv2-loop-detect-hook.sh` null-byte noise** — embedded python emitted
  NUL-separated fields that bash command-substitution silently strips, spamming
  "ignored null byte" + "cut: bad delimiter" on every tool call. Now emits
  newline-separated fields (args as single-line `json.dumps`), parsed in one
  capture with no extra subprocess.
- **`leadv2-compact-trigger.sh` missing helper** — sourced
  `leadv2-active-cache.sh` from a hard-coded `$HOME/.claude/hooks/` path that
  doesn't exist in the plugin layout; now resolves relative to the hook's own
  dir with `$HOME` fallback and a `declare -f` guard, logging the skip.
- **`cost_actual_usd` always null** — added a `cost-actual.yaml` fallback read in
  scorecard-write for Workflow-tool runs (which bypass `claude-subsession.sh`
  cost markers); writer hook is a documented TODO follow-on.

### Added

- **PLUGIN-EXPAND-20260614 — 3-pillar self-improvement program** (all flag-gated, default-off, flag-off byte-identical):
  - *Routing/self-learning:* new PreToolUse:Workflow hook `leadv2-bandit-preflight.sh` auto-runs
    `select-for-workflow` (writes route-decisions.yaml) when `LEADV2_ROUTE_BANDIT=1` and it's
    absent — closes the gap that left the bandit frozen at seed (it was documented-not-enforced).
    `select-for-workflow` also promoted to a mandatory numbered step in leadv2-plan/review SKILL.md.
    Scorecard-write emits a WARN when bandit is active but `route_phases_captured=0`. `leadv2-learn`
    auto-triggers every 10 closes (`LEADV2_LEARN_ON_CLOSE=1`) and now reads `reflect-history.yaml`.
  - *Agent/skill selection:* `leadv2-plan.js` emits a deterministic `plan.steps[i].agent_hint`
    (writes-path + keywords → agent type; zero extra LLM calls), consumed by the Build skill as the
    default subagent_type — first agent-TYPE selection (the bandit only routes models). New scorecard
    field `security_auditor_fired`. Three zero-signal skills deprecated (frontend-feature-deliver,
    frontend-screenshot-audit, modern-web-guidance) — frontmatter-only, reversible.
  - *Native primitives:* `LEADV2_GOAL_INTERACTIVE=1` (+60-turn cap) fires `/goal` in Phase 4 for
    interactive Standard+/Heavy; `leadv2-router.sh` emits `USE_WORKFLOW=1` and phases.md §Phase-2/5
    now describe workflow-dispatch with a schema-death inline fallback instead of the hand-rolled triad.
- **Unrecognized-entity rule (UE, §6.5)** — subagent protocol now requires a
  one-probe existence check for any table / column / env flag / script path /
  library method / API endpoint not present in `context.yaml`, the mission
  file, or the Graph context block, BEFORE writing code or plans that depend
  on it. Missing entity → `DELIVERABLE_BLOCKED`, never a near-name substitute.
  New self-check MD-05. Inspired by the "unrecognized entity → search" trigger
  in Anthropic's Fable 5 system prompt; targets the recurring
  UUID-vs-slug-query, library-method-drift, and phantom-table incident classes.
- **Mid-session hard-bans re-injection** — new PostToolUse hook
  `leadv2-hardbans-reinject.sh`: every `LEADV2_REINJECT_EVERY` (default 25)
  lead tool-calls, injects a 5-line digest of the hard bans (no code by lead,
  silence protocol, background spawns, bounded reads) plus the active
  task/phase. Lead-only (skips when `agent_type` present), fail-open,
  `LEADV2_REINJECT_EVERY=0` disables. Counters long-context drift between
  /compact runs.
- **Workflow-first orchestration** — Plan / Review / Diverge / Learn /
  Diagnose / Audit / PO-feedback-loop ship as deterministic `Workflow` scripts
  (`workflows/leadv2-*.js`) with pinned per-agent models; gated by
  `LEADV2_WORKFLOW_ENABLED=1`.
- **Route bandit (BANDIT-01)** — Thompson-sampling model router
  (`LEADV2_ROUTE_BANDIT=1`) picks within the heuristic allowed-set per
  phase/step; flag-off is byte-identical to heuristic routing.
- **Nested-spawn policy + escalation budgets** — subagents may spawn cheap
  discovery probes (Explore / general-purpose, haiku/sonnet, explicit
  `model=`); anything stronger requires a lead-issued
  `escalation-budget.yaml` token, enforced by `leadv2-routing-guard.sh`.

- **Phase 1.5 DIVERGE** — optional divergent-ideation phase before Plan. Spawns
  N isolated frame-shifted generator agents (zero cross-talk), then a separate
  critic scores / clusters / flags traps / deepens top-K, surfacing a
  non-obvious-but-viable candidate set that Phase 2 converges on. Ported from
  ADHD (UditAkhourii/adhd, MIT) — isolation + mechanical generator/critic split
  are load-bearing. New skill `leadv2-diverge`, 15 default frames at
  `data/leadv2-frames.yaml`, per-repo frame-pack override via
  `docs/leadv2-frames.yaml`. Gated: explicit `/leadv2 diverge` (unconditional)
  or auto on Heavy/Strategic passing an open-ended self-judge; Standard prompts;
  Trivial/Light/emergency/dry-run skip. ~10 Agent spawns/run.

## [0.1.0] — 2026-05-15

Initial public release.

### Added

- Phased orchestration: intake → classify → plan → build → review → deploy → verify → reflect → close
- 4 specialist agents: architect, critic, security-auditor, SCHEMA
- 23 skills: build, plan, review, recovery, iterative-recovery, emergency-mode, judge, judge-question, judge-recovery, judge-review, init, loop-detection, subagent-protocol, token-discipline, verify, deploy, close, correction-detect, founder-input, founder-question-router, question-proxy, lead-reflect, plus init/scaffolding
- 35 lifecycle hooks (token discipline, bash linting, env audit, edit guards, read deduplication, loop detection)
- 60+ helper scripts (state-compact, cost-estimate, immune memory aggregation, pattern clustering, etc.)
- Multi-stack support via `.claude/leadv2-overrides/` scaffolded by `leadv2-init`
- Optional Codex CLI 2nd-brain integration (GPT-5.5)
- Self-learning immune memory: corrections capture, negative-memory filter
- Recovery patterns: timeout/negative-signal handling, iterative recovery (max 5 iterations), emergency mode
- MIT license

### Origin

`leadv2` was developed inside the Timbre / Persona Engine project. v0.1.0 is the result of stripping all project-specific behavior (deploy commands, state-file paths, third-party integrations) out of the orchestration core. The public plugin is fully project-agnostic — projects describe their specifics via `.claude/leadv2-overrides/`.
