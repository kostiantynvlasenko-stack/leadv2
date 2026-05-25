---
name: audit-cluster
description: 3-role per-page audit (QA, PO, Designer) producing PASS/PARTIAL/FAIL punch list per page. Used by frontend-screenshot-audit and standalone.
triggers:
  - аудит страниц
  - punch list UI
  - review pages
  - audit cluster
allowed-tools:
  - Read
  - Write
---

# Audit Cluster

## When
Auditing a set of pages against quality criteria — visual, functional, copy, and state coverage.

## Inputs
- `pages[]` — list of page names or screenshot paths
- `roles` — default `[QA, PO, Designer]`; configurable
- `criteria` — default set below; override per task

## Default criteria
- **simple** — no clutter, clear hierarchy
- **clear** — customer language, no UUIDs/jargon, no raw JSON
- **beautiful** — consistent spacing, color, typography per design system
- **working** — no broken states, no blank sections, no spinner loops
- **informative** — data is meaningful, numbers make sense, labels explain units
- **no-tech-jargon** — no internal IDs, no snake_case labels on customer surfaces
- **all-states-wired** — loading, empty, error, populated states all render correctly

## Per-role lens

**QA** — working + all-states-wired: does every state render? Any broken API call, 404, console error?

**PO** — informative + no-tech-jargon + clear: does the page communicate value? Would a non-technical customer understand it?

**Designer** — simple + clear + beautiful: spacing, hierarchy, color consistency, typography, responsiveness.

## Output format (per page)

```
## Page: <name>

| Role     | Criterion          | Result  | Note                         |
|----------|--------------------|---------|------------------------------|
| QA       | working            | PASS    |                              |
| QA       | all-states-wired   | PARTIAL | empty state not implemented  |
| PO       | informative        | FAIL    | KPI cards show raw IDs       |
| Designer | beautiful          | PASS    |                              |
...

### Fix items
- [ ] [HIGH] KPI cards: replace IDs with human labels
- [ ] [MED]  Empty state: add zero-data illustration + CTA
```

## Deliverable
`docs/handoff/<task_id>/screenshots/vision-report.md` — all pages combined, fix items consolidated and de-duped at bottom, ordered HIGH → MED → LOW.
