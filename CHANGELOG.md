# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

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
