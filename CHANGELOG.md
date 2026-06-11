# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

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
