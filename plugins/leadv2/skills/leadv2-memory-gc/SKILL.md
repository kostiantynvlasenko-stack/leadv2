---
name: leadv2-memory-gc
description: "[internal] Memory GC pass: finds stale paths, duplicate entries, and archive candidates in leadv2 memory stores."
allowed-tools:
  - Read
  - Bash
---

# Lead v2 Memory GC — Dream Pass

## Purpose

Periodically prune and validate the four leadv2 memory stores:

- `docs/leadv2/immune-patterns.yaml`
- `docs/leadv2-negative-memory.yaml`
- `docs/leadv2-priors.yaml`
- `.claude/ref/lead-patterns.md`

## Checks performed

| Check | Action |
|---|---|
| **Stale paths** — path tokens in store content that no longer exist on disk | Report-only; founder decides deletions |
| **Duplicates** — identical `pattern/regex` (immune) or `failure_mode+pattern` (negative-memory) | Removed on `--apply`; oldest entry archived |
| **Archive candidates** — `hits/uses==0` (or absent) AND older than `--max-age-days` | Report-only; founder reviews before archiving |

## Flags

```
leadv2-memory-gc.sh --project-root <path>   # defaults to $PWD
                    --apply                  # dedupes only; stale+archive = report-only always
                    --max-age-days N         # default 90
```

## Weekly Phase-8 trigger

`leadv2-phase8-close.sh` runs this script in report-only mode if
`docs/leadv2/.memory-gc-last` is absent or older than 7 days.
Prints: `memory-gc: report refreshed (weekly)`. Never blocks close.

## Report path

`docs/leadv2/memory-gc-report.md` — sections: Stale Paths / Duplicates /
Archive Candidates / Summary counts.

## Apply policy

`--apply` only deduplicates (keeps newest entry per key; removed entries go to
`docs/leadv2/memory-gc-archive.yaml` with `archived_at`).
Stale paths and archive-candidates are **always report-only** — founder reviews
the report and deletes entries manually.
