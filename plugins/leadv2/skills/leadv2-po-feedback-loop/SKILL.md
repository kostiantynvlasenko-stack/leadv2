---
name: leadv2-po-feedback-loop
description: Product-Owner feedback loop — full 4-phase orchestration (Audit → Build → Verify → Iterate) for UI-heavy features. Architect-Opus audits the deployed feature against best-in-class benchmarks (industry leaders for the domain) + local design baseline (m3-nft-design / emil-design-engineering / etc.), writes prioritized P0/P1/P2 fix list, then parallel Sonnet developers ship fixes split by file ownership, then Playwright auto-verification (PASS/FAIL/PARTIAL). Max 2 iteration rounds before shipping with TODO. Auto-invoked after Build for class ≥ Standard when diff touches UI files.
when_to_invoke: |
  Auto-trigger after Phase 4 (Build) if ALL conditions:
  - class is Standard, Heavy, or Strategic (not Trivial/Light)
  - diff touches ≥2 files matching: apps/main/app/**/*.tsx, packages/features/*/src/**/*.tsx, packages/ui/**/*.tsx
  - feature is user-facing (page, modal, grid, sidebar, table, form, drawer, chart)
  - first version of the feature is deployed to preprod (Vercel preview ready)

  DO NOT invoke for:
  - Pure backend changes (no .tsx touched)
  - Trivial fixes (typo, single-line CSS tweak)
  - Hotfix mode (emergency_mode=true)
  - Infrastructure / k8s overlays
  - Tests, configs, package.json
allowed-tools:
  - Read
  - Write
  - Edit
  - Bash
  - Grep
  - Glob
  - Task
---

# Lead v2 PO Feedback Loop

Closes the loop between "feature deployed" and "feature is great". Codifies the workflow proven on LOCAL-9-collections-sidebar (2026-05-23): one Audit → parallel Build → auto-Verify → optional Iterate produced 27 UX improvements in one session.

## The 4 phases

### Phase A — Audit (Architect-Opus + Playwright + benchmarks)

Spawn `Agent(subagent_type="07-architect" OR "18-fe-architect", model="opus")` with mission `po-audit-mission.md` (see `templates/po-audit-mission.md` in this skill dir). The architect:

1. Sets cookie bypass + visits deployed preprod URL via Playwright (`@playwright/test`)
2. Captures **all states** of the feature: loaded, empty, error, loading, mobile (375×812)
3. Walks key user flows (entry → primary CTA → outcome)
4. Compares against:
   - **Industry benchmarks** for the product domain (NFT marketplace → OpenSea/Blur/Magic Eden; SaaS dashboard → Linear/Stripe/Vercel; consumer app → top 3 in App Store category)
   - **Local design baseline**: detect via Glob — if `m3-nft-design/QUICKREF.md` exists use that, else `emil-design-engineering/SKILL.md`, else `frontend-design/QUICKREF.md`, else generic MWG
   - **Modern Web Guidance** (`leadv2:modern-web-guidance`): contrast, touch targets ≥44px, dvh viewport, loading states, ARIA
5. Writes structured report to `<task-dir>/po-audit-<feature>.md`:
   ```markdown
   # PO Audit — <Feature Name>
   ## Date: YYYY-MM-DD
   ## What's working ✅ (keep, don't break)
   ## Critical gaps 🔴 P0 (max 5, with fix + effort S/M/L)
   ## High-value improvements 🟡 P1 (max 6, specific)
   ## Nice-to-haves 🟢 P2 (max 4)
   ## Screenshots (list paths)
   ```

Quality bar: each finding cites a specific UI element + concrete fix + effort estimate. No vague "improve cards".

### Phase B — Build (parallel Sonnet developers, split by file ownership)

Lead reads the audit (`Read limit=70`), groups findings by which file/component they touch, then spawns parallel `Agent(subagent_type="09-nextjs-pro" OR "02-react-developer", model="sonnet")` — one agent per file-ownership group.

**Split rule:** each agent owns DISJOINT files. Pattern from LOCAL-9 that worked:
- Agent A: header/stats/tabs files (CollectionDetailPage, CollectionHeader, StatsRow, DetailTabs)
- Agent B: actions/listings/chart files (ActionPanels, CollectionListings, PriceVolumeChart)

Each agent mission file (≤100 lines, mission-lint enforced) lists:
- Specific P0/P1/P2 items from the audit assigned to this agent
- Concrete fix code patterns or pseudocode per item
- Files allowed to touch + files in OTHER agent's scope (off_limits)
- Verification command for that subset (`pnpm --filter=... type-check`)
- "Do NOT commit" instruction (lead commits batched)

After both agents return DELIVERABLE_COMPLETE, lead:
1. Reads `git diff --stat` to confirm changes match scope
2. Runs `pnpm --filter=main --filter=<affected packages> build`
3. Commits + pushes to preprod branch

### Phase C — Verify (Playwright auto-script)

Spawn `Agent(subagent_type="09-nextjs-pro", model="sonnet")` with mission `po-verify-mission.md`. Agent:

1. Waits 60-90s for Vercel build of the new commit
2. Cookie bypass + navigates to the feature
3. Programmatically verifies EACH P0+P1 fix (one assertion per item):
   - DOM presence check (`page.locator(...)`)
   - Behavior check (click → expected response/state)
   - Visual check (screenshot to `/tmp/v-<n>.png`)
4. Reports as table:
   ```
   | # | Check | Status | Note |
   ...
   SUMMARY: X/N PASS, K FAIL, M PARTIAL, P INCONCLUSIVE
   ```

PASS = element + behavior verified. FAIL = missing or broken. PARTIAL = present but degraded. INCONCLUSIVE = can't programmatically verify (canvas charts, JS animations).

### Phase D — Iterate (only if FAIL exists)

If verify reports FAIL count ≥1:
- Round 1: spawn fix-round developer with ONLY the failed items, re-verify
- Round 2 (if still FAIL): spawn fix-round with deeper investigation hints
- After Round 2: stop iterating. Log remaining issues to `<task-dir>/po-followups.md`. Mention to founder; offer to address in follow-up PR.

**Hard cap: 2 iteration rounds.** Then ship.

## Trigger detection (auto-invoke from leadv2-build)

In `leadv2-build/SKILL.md`, after build commit + push success, lead runs:

```bash
# Detect UI-heavy diff
ui_files=$(git diff --name-only HEAD~1 HEAD | grep -E "\.tsx$" | grep -E "(apps/.*/page\.tsx|packages/features/.*\.tsx|packages/ui/.*\.tsx)" | wc -l)
if [ "$ui_files" -ge 2 ] && [ "$class" != "Trivial" ] && [ "$class" != "Light" ]; then
  echo "FE-UI feature shipped → invoking po-feedback-loop"
  # Lead then invokes this skill
fi
```

The skill is invoked **after** the initial build push (so preprod is live), BEFORE Phase 5 review. Review can then read the audit + verify results.

## When NOT to invoke (anti-triggers)

- **Bugfixes** that don't add new UI surface — fixing a specific defect doesn't need full PO audit
- **Refactors** that preserve UI identical — no UX delta
- **Backend-only** even if FE was touched for type updates only
- **Hotfixes** under emergency_mode=true (`leadv2-emergency-mode` skill active)
- **Mission specs that already include** `skip_po_audit: true` in context.yaml

## Cost discipline

- Audit phase: 1 Opus call, ~80-120K tokens, ~5-7 min
- Build phase: 2-3 parallel Sonnet, ~50K tokens each, ~5 min
- Verify phase: 1 Sonnet + Playwright, ~30K tokens, ~5-8 min
- Iterate: ~50K tokens per round, max 2 rounds

**Total budget: ~300-400K tokens, ~20-30 min wall time.** Founder unblocked throughout.

## Founder communication

Lead reports compactly between phases:
- After Audit: P0 count + 1-line per P0 + ask to proceed
- After Build: file count + commit SHA + Vercel URL
- After Verify: PASS/FAIL summary + screenshot dir
- After Iterate: final delta + offer follow-up audit if needed

**No narration between phases.** Pulse-mode silent per leadv2 spec.

## Templates

- `templates/po-audit-mission.md` — Architect mission for Phase A
- `templates/po-verify-mission.md` — Verify agent mission for Phase C
- `templates/po-build-split-pattern.md` — How to split work between parallel devs

## Lessons codified (LOCAL-9 retro, 2026-05-23)

These are MANDATORY checks that fold into the existing phases. Don't skip.

### 1. Baseline-for-comparisons check (Phase A — audit prompt addition)

Any UI column / badge / value that shows a **delta, percentage, ratio, or comparison** (Floor Δ, % change, vs market, since last…) MUST specify in the audit:
- **Baseline** — what value are we comparing against? `current_floor` vs `floor_at_time_of_event`? `7d_high` vs `all_time_high`?
- **Time semantics** — is the baseline live OR snapshotted at event-time?
- **API contract** — does the API expose a per-row snapshot field, or only the live aggregate?

If the audit produces a delta column without answering all 3 — that's a P0 finding, not a P2. Reason: LOCAL-9 shipped a `Floor Δ` column in Recent Sales using *current* floor against *historical* sale price — semantically wrong, founder caught visually, required Round 2 fix-and-revert. Add this question to `templates/po-audit-mission.md`.

### 2. Playwright PASS ≠ visual OK for numeric/format UI

Playwright "PASS" is necessary but not sufficient for:
- Number formatting (axis labels, currency, percentages)
- Truncation / ellipsis behavior
- Color-coding by value sign
- Y-axis dual-axis layouts

Reason: LOCAL-9 verify reported "Y-axis fix PASS" while UI actually showed `$0/$1/$1/$1` (bars used wrong data key). Selector existed → PASS, but render was wrong.

**Rule for Phase C:** if the verify scenario covers a numeric/format/visual concern, the agent MUST save a `/tmp/v-<n>.png` screenshot for that scenario and reference it in the report. Lead then offers founder visual signoff ("see /tmp/v-3.png") before declaring done. Don't merge on Playwright PASS alone for format-class fixes.

### 3. Lead-direct-verify rule (≤5-line single-file)

When a verify reports a FAIL that requires checking a SINGLE line in a SINGLE file (e.g. "is `hidden sm:inline-flex` on the BETA span?"), lead reads the file directly with `Read offset=N limit=5`. Do NOT spawn a developer agent.

Reason: LOCAL-9 spent 80s on an A1-was-actually-correct re-check of `Header.tsx` line 35 because the QA report's FAIL was a stale Vercel cache, not a real bug. One `Read` call would have closed it instantly.

**Threshold:** if the fix candidate is ≤5 lines AND in 1 file AND clearly localized — lead reads, then either confirms no fix needed OR writes the patch instruction inline into a single agent prompt. Skip a dedicated agent.

### 4. Don't skip Phase 3 (Plan triad) for "obviously well-defined" UI work

LOCAL-9 went audit→build without architect+critic, betting the audit IS the spec. It worked, but the FloorΔ semantic miss is exactly what a critic-Opus pass would have flagged BEFORE writing code. Rule: even if work feels "well-defined P2 polish", run a 30-line `critic-mission.md` over the audit findings, async, parallel with Build. Cost: one Opus call. Saves one round of revert-and-fix.

---

## Per-repo overrides

If `<repo>/.claude/leadv2-overrides/po-audit-policy.yaml` exists, lead reads it for:
- `industry_benchmarks: [list of competitor URLs / product types]`
- `local_design_baseline: <skill-name>`
- `max_iteration_rounds: N` (default 2)
- `disabled: true` to opt out entirely

## Reference implementation

See `~/MythicalGames/m3-market/.claude/leadv2-tasks/LOCAL-9-collections-sidebar/` for:
- `po-audit.md` — collections grid audit (first proof of concept)
- `po-audit-detail.md` — detail page audit
- `po-audit-tabs.md` — Recent Sales + Price & Volume audit
- Commits `90d3a7a9`, `078ff5d5`, `bc670694` — 27 fixes across 3 commits
