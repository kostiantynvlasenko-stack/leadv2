---
name: leadv2-signatures
description: "[internal] Validate and aggregate closed-vocabulary reflection signatures at task close; never mid-task."
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

| Field | Allowed values |
|---|---|
| `phase` | `intake \| plan \| build \| review \| deploy \| verify \| recovery \| close` |
| `task_class` | `Light \| Standard \| Heavy \| Strategic` (final forced class if overridden) |
| `failure_class` | `timeout \| wrong-file \| env-missing \| api-4xx \| api-5xx \| logic-bug \| scope-creep \| stale-state \| none` |
| `recovery_decision` | `retry \| rollback \| hotfix \| escalate \| none` |
| `outcome` | `success \| rolled_back \| paused \| failed` |
| `involved_agents` | subset of `architect \| developer \| frontend-developer \| postgres-pro \| devops-engineer \| critic \| security-auditor \| product-owner` |
| `change_kind` | `new-route \| new-migration \| refactor-internal \| bugfix-pure \| cross-service \| ui-only \| config-only \| docs-only` |
| `fix_quality` | `band-aid \| reasonable \| durable` |

For the meaning of each individual value, see [SCHEMAS.md](./SCHEMAS.md). If a value you need isn't in these lists, add it to SCHEMAS.md first — never invent free-text inline.

---

## Aggregation Logic

Run after each close phase (or via `leadv2-signatures-aggregate.sh`). Full formulas, write-templates, and worked thresholds: [AGGREGATION.md](./AGGREGATION.md).

1. **Extract signatures** — scan `docs/LEAD_V2_STATE.md` history + `docs/ops/LEAD_HISTORY.md` for all `signature:` blocks.
2. **Compute weighted counts** — 90-day half-life decay per entry, aggregated by `(phase, failure_class, change_kind, fix_quality)`.
3. **Promotion threshold** — quadruple with raw count ≥3 AND ≥2 distinct tasks → write candidate to `.claude/ref/lead-patterns.md` under `## #signature-promotion-candidates`. Also computes `band_aid_ratio_30d`; alert if >0.30.
3b. **Induced regression aggregation** — scan `docs/leadv2-causal-log.yaml` for 30-day induced-regression rate per `change_kind`; alert if >0.20.
4. **Decay-based retirement** — active rule with `count_weighted < 1.0` → move to `## #retired` section (never delete).

Promotion/retirement to active tables is always **manual review** — never auto-promote, never auto-delete.

---

## Signature Entry Schema

Each signature block in `LEAD_V2_STATE` history carries the fields above plus temporal-decay metadata (`first_seen`, `last_seen`, `usage_count`), a free-text `approach` field, and `negative_memory_hit`. Full YAML example + field-by-field notes and the dedup match rule: [EXAMPLES.md](./EXAMPLES.md).

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
