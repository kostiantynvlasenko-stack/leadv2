# PO Build Split Pattern

Pattern for splitting Phase B (Build) work between parallel Sonnet developers to avoid file conflicts and maximize throughput.

## Rule

**Each agent owns DISJOINT files.** No agent edits a file another agent is editing in the same round. Verified by `git diff --name-only` after both return.

## How to split

Group P0+P1 findings from the audit by **file affinity**, not by priority. Goal: minimize cross-agent file dependencies.

### Pattern from LOCAL-9 (proven 2026-05-23, 12 fixes in one round)

**Agent A — Layout & Header** (header/stats/tabs/cards)
- `CollectionDetailPage.tsx` — page-level structure, breadcrumb, hero layout
- `CollectionHeader.tsx` — title, image, contract, share button
- `CollectionStatsRow.tsx` — stats display, tooltips on stat labels
- `CollectionDetailTabs.tsx` — tab orchestration

**Agent B — Interactive surfaces** (forms/tables/charts/CTAs)
- `CollectionActionPanels.tsx` — Buy/Sell/Bid CTAs + disabled states
- `tabs/CollectionListings.tsx` — table columns, sort, hover
- `tabs/PriceVolumeChart.tsx` — chart Y-axis, period selector
- `tabs/CollectionRecentTrades.tsx` — sales feed

This split works because:
- Layout and interactive surfaces touch different files
- No overlap on shared components
- Both agents can run in parallel without race conditions

### General splits for other features

- **Grid feature** (cards/sidebar): Agent A = card/grid components, Agent B = sidebar/filter components
- **Form flow** (multi-step): Agent A = step UI + validation, Agent B = state machine + submit handler
- **Dashboard**: Agent A = header/nav/topbar, Agent B = panels/charts/widgets

## Mission file structure per agent

Each mission file (`<feature>-<group-id>-mission.md`, ≤100 lines) MUST contain:

```markdown
## Context
Branch <name> in <repo path>. **Uncommitted changes exist** from sibling agent — do NOT stash. Your scope is <X>.

## Skills to load
- leadv2:modern-web-guidance (for UI patterns)
- (local design baseline skill)

## Your files (DISJOINT — no conflict with other agent)
- file1.tsx
- file2.tsx

## Off-limits (other agent owns)
- file3.tsx
- file4.tsx

## Fixes
### Fix 1 — P0.N: <description>
Investigation: <where to look>
Fix: <concrete code pattern>

### Fix 2 — P1.M: <description>
...

## Verification
```bash
cd <repo> && pnpm --filter=<scope> type-check 2>&1 | grep "error TS" | grep -v "<pre-existing noise>" | head -5
```

Zero errors in OUR files = pass. Report per-fix one-liner + file. **Do NOT commit.**
```

## Lead post-build sequence

After both agents return DELIVERABLE_COMPLETE:

```bash
cd <repo>
git diff --stat HEAD                            # confirm both agents' work present
pnpm --filter=main --filter=<affected> build    # cross-package build check
git add apps/ packages/
git commit -m "fix(<area>): PO audit fixes — <comma-separated short titles> [<TASK>]"
git push origin <preprod-branch>
```

Then invoke Phase C (verify).

## Common pitfalls

- **File overlap** — if two agents touch the same file, second agent's `git status` will show "modified" on file they didn't intend. Mitigation: pre-check audit findings, group by file before spawning.
- **Sibling-aware messaging** — each mission MUST mention "uncommitted changes exist, do NOT stash". Otherwise sibling work gets discarded.
- **Off-limits list** — explicitly list which files belong to OTHER agent. Prevents accidental edits.
- **Type-check noise** — strip pre-existing errors with `grep -v "<known-noisy-paths>"`. Don't fail on errors that existed pre-change.
