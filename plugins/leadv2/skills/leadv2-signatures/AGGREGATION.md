# Aggregation Logic — full detail

Referenced from SKILL.md. Run after each close phase (or via `leadv2-signatures-aggregate.sh`).

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
