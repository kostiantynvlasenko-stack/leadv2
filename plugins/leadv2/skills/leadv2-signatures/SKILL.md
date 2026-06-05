---
name: leadv2-signatures
description: "[internal] Closed-vocab schema for lead-reflect signatures; aggregates phase/failure_class tuples,…"
allowed-tools:
  - Read
  - Write
  - Edit
  - Bash
---

# Lead v2 Signatures — Closed Vocab + Aggregation

## When: after lead-reflect writes a signature block, or when running aggregation at close
## When NOT: mid-task; during plan/build phases; do not write aggregation results during active tasks

---

## Closed Vocabularies (authoritative)

All `signature:` fields in `lead-reflect` history entries MUST use values from these lists. No free-text allowed.

### phase
```
intake | plan | build | review | deploy | verify | recovery | close
```
- `intake`: first triage, classification, gate-1 decision
- `plan`: architect/codex plan drafting
- `build`: developer/postgres-pro implementation
- `review`: codex review, critic review
- `deploy`: devops, VPS, migration apply
- `verify`: outcome-watch, acceptance test
- `recovery`: rollback, hotfix, incident-postmortem
- `close`: lead-reflect, log update, state → idle

### task_class
```
Light | Standard | Heavy | Strategic
```
As classified by `lead-classify`. Use the final forced class if overridden.

### failure_class
```
timeout | wrong-file | env-missing | api-4xx | api-5xx | logic-bug | scope-creep | stale-state | none
```
- `timeout`: agent or external call timed out
- `wrong-file`: subagent edited incorrect file/path
- `env-missing`: required env var / credential absent
- `api-4xx`: external API client error (bad request, auth)
- `api-5xx`: external API server error
- `logic-bug`: implementation defect found in review/verify
- `scope-creep`: subagent exceeded mission boundaries
- `stale-state`: local state / cache was stale, caused wrong decision
- `none`: no failure this task

### recovery_decision
```
retry | rollback | hotfix | escalate | none
```
- `retry`: re-ran the same step with minor adjustment
- `rollback`: reverted code or DB change
- `hotfix`: patched live without full cycle
- `escalate`: stopped and pinged founder
- `none`: no recovery needed

### outcome
```
success | rolled_back | paused | failed
```
- `success`: task completed, accepted by verify
- `rolled_back`: changes reverted, system restored
- `paused`: founder asked to pause mid-task
- `failed`: task terminated without deliverable

### involved_agents
Any subset of:
```
architect | developer | frontend-developer | postgres-pro | devops-engineer |
critic | security-auditor | product-owner
```

### change_kind
Structural footprint classification produced by `leadv2-graph-reflect`. Sourced into `signature.change_kind` and `graph_footprint.change_kind`.
```
new-route | new-migration | refactor-internal | bugfix-pure | cross-service | ui-only | config-only | docs-only
```
- `new-route`: a new HTTP/API route was added (Route node in graph)
- `new-migration`: a Supabase migration file was added
- `refactor-internal`: internal restructure, no new external surface
- `bugfix-pure`: defect fix with no new symbols added
- `cross-service`: change introduces cross-service edges (HTTP_CALLS, ASYNC_CALLS)
- `ui-only`: changes confined to `web/` or frontend files
- `config-only`: changes confined to config files (json/yaml/env)
- `docs-only`: changes confined to docs, prompts, or `.claude/` skill files

### fix_quality
Derived from hack-detection findings in Review phase (see `leadv2-hack-detection` skill and `lead-reflect` §6).
```
band-aid | reasonable | durable
```
- `band-aid`: block hack findings present, OR > 3 warn findings
- `reasonable`: 1-3 warn findings, OR no hack data (default)
- `durable`: 0 hack findings AND test-synthesis coverage ≥ 80%

---

## Aggregation Logic

Run after each close phase (or via `leadv2-signatures-aggregate.sh`).

### Step 1 — Extract signatures

Scan `docs/LEAD_V2_STATE.md` history + `docs/ops/LEAD_HISTORY.md` for all `signature:` blocks.

### Step 2 — Compute weighted counts with 90-day half-life decay

For each signature entry with `first_seen` / `last_seen` / `usage_count`:

```
age_days = (today - last_seen).days
count_weighted = usage_count * 0.5^(age_days / 90)
```

Aggregate by `(phase, failure_class, change_kind, fix_quality)` quadruple: sum `count_weighted` across all entries matching that quadruple. Entries lacking `change_kind` contribute to a `change_kind=null` bucket; entries lacking `fix_quality` contribute to a `fix_quality=null` bucket. Both null-field entries still count toward `(phase, failure_class)` totals for promotion thresholds.

### Step 3 — Promotion threshold

A `(phase, failure_class, change_kind, fix_quality)` quadruple — or `(phase, failure_class)` for legacy null-field entries — with **raw count ≥3** (not weighted) AND at least 2 distinct tasks → emit as a promotion candidate.

Write candidates to `.claude/ref/lead-patterns.md` under `## #signature-promotion-candidates` section:

```
| (phase, failure_class, change_kind, fix_quality) | raw_count | weighted_count | task_ids | candidate_rule |
```

**Candidate rule format:** `"when phase=<X> and failure=<Y> and change_kind=<Z> and fix_quality=<Q> → [specific guard/action]"`. Omit null-field clauses.

**Band-aid alert rule:** after aggregation, compute `band_aid_ratio_30d`:
```
band_aid_ratio_30d = (count of tasks in last 30 days where fix_quality=band-aid) /
                     (count of all tasks in last 30 days)
```
If `band_aid_ratio_30d > 0.30` → write alert to `.claude/ref/lead-patterns.md` under `## #signature-promotion-candidates`:
```
| band-aid-ratio-alert | — | band_aid_ratio=<N%> | <task_ids> | "band-aid ratio rising in last 30d (>30%), review engineering discipline" |
```

Orchestrator drafts rule text; human reviews before moving to active rules.

Actual promotion to the active tables (Classification forcing rules / Opus spawn rules) remains **manual review** — never auto-promote to active section.

### Step 3b — Induced regression aggregation

After Step 3, scan `docs/leadv2-causal-log.yaml` (if it exists) for the 30-day window:

```
induced_regression_rate per cause_task type =
  (count of causal log entries in last 30 days where cause_task matches task pattern X) /
  (count of all tasks of pattern X closed in last 30 days)
```

Compute per `change_kind` (derived from cause_task's signature in history):
```
induced_regression_rate_by_change_kind[change_kind] =
  count(causal log entries last 30d with cause task of change_kind X) /
  count(closed tasks last 30d with change_kind X)
```

If `induced_regression_rate_by_change_kind[X] > 0.20` (20%):
- Write candidate to `.claude/ref/lead-patterns.md` under `## #signature-promotion-candidates`:

```
| induced-regression-rate | — | change_kind=<X>, rate=<N%> | <cause_task_ids> |
  "Task pattern change_kind=<X> induced regressions at <N%> in 30d — add pre-emptive check to Review phase" |
```

This candidate requires human review before promotion to an active rule. Do not auto-promote.

Also compute `induced_regression_total_30d` — the raw count of RECOVERY-/REGRESSION- tasks
with a known cause in the last 30 days. Report this in the aggregation summary alongside
`band_aid_ratio_30d`.

### Step 4 — Decay-based retirement

For each active rule in `.claude/ref/lead-patterns.md` that has an associated signature tuple:
- If `count_weighted < 1.0` → move rule to `## #retired` section with reason `"decay: weighted_count=<N> on <date>"`.
- Do NOT delete — retired rules are evidence of patterns that faded.

---

## Signature Entry Schema (in LEAD_V2_STATE history)

Each signature block also tracks temporal metadata for decay:

```yaml
signature:
  phase: build
  task_class: Heavy
  failure_class: logic-bug
  recovery_decision: hotfix
  outcome: success
  involved_agents: [developer, critic]
  change_kind: bugfix-pure
  fix_quality: reasonable    # band-aid | reasonable | durable
  approach: ""               # optional free-text; captured from developer deliverable summary; used by negative-memory-compile
  negative_memory_hit: false # true if negative-memory skill blocked/flagged this task's approach at any phase
  first_seen: "2026-04-24"
  last_seen: "2026-04-24"
  usage_count: 1
```

**`approach` field:** Free-text description of the specific approach taken (e.g., "added index on messages.created_at"). Captured in `lead-reflect` when the developer-agent logged the approach in their deliverable. No closed vocab — leave empty string if not described. Used by `leadv2-negative-memory-compile.sh` to match repeated failures across history.

**`negative_memory_hit` field:** Set to `true` by lead when `leadv2-negative-memory` produced a `disposition: blocked` match during any phase of this task. Used for aggregation: high hit rates signal that the negative-memory store is catching real patterns, or that unblock criteria need refinement.

On subsequent tasks with same `(phase, failure_class)`:
- Do NOT add duplicate entries — update the existing entry: bump `usage_count`, set `last_seen`.
- When deduplicating, match on `(phase, failure_class, recovery_decision, outcome, change_kind, fix_quality)` six-tuple. Treat missing fields as `null` for matching purposes.

---

## Rules

- Closed vocab is the single source of truth — `lead-reflect` cites this file.
- Never invent new vocab values inline in a reflection entry — add to this skill first if genuinely needed.
- Promotion candidates are for human review; do not auto-move to active rule tables.
- Retirement applies only to rules backed by signature tuples — manually authored rules (PS-XX, CX-XX) are never auto-retired.
- `usage_count` increments on each task confirmation, not on each mention in a history entry.

## Anti-patterns

- Adding free-text `failure_class: "database error"` — must map to `api-5xx` or `logic-bug` from closed vocab.
- Promoting a candidate rule to active without human review — the candidate section is a queue, not an inbox.
- Running aggregation during an active task phase — signatures are written at close, aggregate at close.
- Treating weighted_count=0.9 as "basically retired" — the threshold is strictly < 1.0.
