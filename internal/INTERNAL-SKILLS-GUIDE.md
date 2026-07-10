# leadv2 Internal Skills — Routing Matrix

One-page map of every `[internal]` leadv2 plugin skill: which phase it belongs to, what
fires it, and when the lead should NOT invoke it. Built from each skill's own SKILL.md
description (`plugins/leadv2/skills/<name>/SKILL.md`). Hidden from normal chat; surface
only when `LEADV2_DEBUG=1` or the lead is unsure which internal skill applies.

| Skill | Phase | Trigger condition | Skip condition |
|---|---|---|---|
| `leadv2-init` | Phase 0 (first run) | `stack.yaml` missing — first `/leadv2` run in a repo | `stack.yaml` already exists |
| `leadv2-rag-intake` | Phase 0 Intake | Immediately after `lead-classify` writes classification to LEAD_V2_STATE.md | Mid-build; during Recovery; bare `/leadv2 status`/`help` |
| `leadv2-priors` | Phase 0–5 (classify/plan/build/review/premortem) | Any of those phases needs contextual defaults from `docs/leadv2-priors.yaml` | Active code writes/mid-task edits; trivial tasks where the injection overhead outweighs the benefit |
| `leadv2-negative-memory` | Phase 2 / 4 / 5 / Recovery | Before Plan emits steps; before Build spawns developer; after Review findings land; before any Recovery retry | Trivial tasks (still runs once at build start); after a task is closed (use `leadv2-close`/`lead-reflect` instead) |
| `leadv2-hack-detection` | Phase 5 Review, Round 1 | Runs in parallel with Codex/critic, scans the review diff for band-aid patterns | Standalone code review outside `/leadv2`; security auditing (use `security-auditor`) |
| `leadv2-judge` | Phase 5 (mode=review) / any phase (mode=question) | `review`: ≥2 reviewers return conflicting verdicts. `question`: founder asks a judgment question mid-task | Specialized judges (`judge-review`/`judge-recovery`) already cover the case |
| `leadv2-founder-question-router` | Any phase, task in flight | Founder sends a free-form message (not a slash command) while `active.yaml` has a live session | No active session; message IS an explicit Gate-1/Gate-2 approval or rejection |
| `leadv2-founder-input` | Recovery / Plan / Review escalation | Recovery exhausted 2 retry rounds; off-limits warning fires; coverage gate <50% with no auto-fix path; plan-review disagreement lead can't arbitrate | Lead can resolve the fork internally without founder input |
| `leadv2-premortem` | Phase 4 (pre-build) / Phase 6 (pre-deploy) | `--phase build` before Build spawn, or `--phase deploy` before Deploy commit — bash+heuristic only, no LLM cost | N/A — cheap enough to always run when reachable |
| `leadv2-premortem-deploy` | Phase 6 Deploy, mandatory | Checks estimated tokens vs the class token ceiling before commit | `Trivial`/`Light` class with no prior cost signals, or `cost-estimate.yaml` absent |
| `leadv2-llm-judge` | Phase 6 Deploy, mandatory | After premortem (step 0.6), before the auto-Gate-2 check (step 0) | `class==Light` AND off-limits clean AND premortem verdict `proceed` AND zero hack-detection blocks |
| `leadv2-deploy` | Phase 6 | Build+Review passed, ready to commit/push/deploy via project override | Unresolved Critical/High findings — circuit-breaks to founder instead |
| `leadv2-verify` | Phase 7 | Runs after Deploy completes cleanly; blocks Close until a concrete production signal is captured | Deploy itself circuit-broke — that routes straight to Recovery, not Verify |
| `leadv2-recovery` | Phase 7 | Phase 7 verify fails — decides rollback vs architect alt-approach, capped at 2 attempts | During Plan/Build/Review — those phases use their own escalation paths |
| `leadv2-close` | Phase 8 | Task is closing — cost summary + `lead-reflect` entry + outcome-watch scheduling (Heavy tasks) | N/A — always runs at close |
| `lead-reflect` | Phase 8 Close §2, and pre-`/compact` | Task close, or context about to be compacted | N/A — always runs at those two triggers |
| `leadv2-correction-detect` | Phase 8 (`lead-reflect` §6.5) | Classifies the last N founder messages as correction/reinforcement/preference/context via haiku | Confidence too low to write — only high-confidence corrections land in `immune-patterns.yaml` |
| `leadv2-signatures` | Phase 8 / aggregation | After `lead-reflect` writes a signature block, or when running cross-task aggregation at close | Mid-task; during active Plan/Build — never write aggregation results while a task is open |
| `leadv2-memory-gc` | Maintenance, on-demand | Explicit memory-GC pass to find stale paths / duplicate entries / archive candidates | N/A — not phase-gated, run when memory hygiene is requested |
| `leadv2-question-proxy` | Phase 2 / 4 / 5 / 7 (**DORMANT** — zero production firings as of 2026-07-03) | An active `claude-subsession.sh` is in flight and writes a question to `docs/handoff/<id>/questions/` | No subsessions active; e2e-test before relying on it in production |

## Notes

- This table is generated from descriptions, not re-derived logic — if a skill's SKILL.md
  description changes, update the corresponding row here.
- "Mandatory" gates (`leadv2-premortem-deploy`, `leadv2-llm-judge`) still have a documented
  skip condition; they are not unconditional.
- `leadv2-question-proxy` is DORMANT — don't treat its row as a live routing guarantee until
  it has been e2e-tested per its own SKILL.md caveat.
