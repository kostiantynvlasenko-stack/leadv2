# Negative Memory — Matching Algorithm & Tuning

**See [SKILL.md](./SKILL.md) for the main protocol and control flow.**

This document covers threshold tuning, semantic recall details, and deep-dive algorithm explanation for the match filter (Step 3).

---

## Match Filter Algorithm (Step 3 detail)

The match filter in SKILL.md Step 3 checks three conditions in AND logic:

```
MATCH if ALL of:
  A. entry.signature.phase == current_phase
     OR entry.signature.phase is null (matches any phase)
  B. entry.signature.change_kind == current change_kind
     OR entry.signature.change_kind is null
     OR current change_kind is null (unknown footprint — still check approach)
  C. keyword_overlap(entry.signature.approach, approach_description) >= threshold
     OR semantic_similarity >= semantic_threshold [optional]
```

Keyword overlap is the primary match path and fires on every run. Semantic similarity is an optional OR-path that only activates when the helper is enabled.

---

## Keyword Overlap — Tuning & Formula

### Formula

```
keyword_overlap(entry_approach, description) = 
    (count of shared significant words) / (count of unique significant words across both)
```

"Significant" means: alphanumeric tokens, ≥3 characters, excluding common stop-words (the, and, or, a, an, etc.).

Example:
```
entry_approach: "add new endpoint without adding to OpenAPI contract"
description: "new HTTP endpoint missing from OpenAPI spec"

Significant words:
  entry: {add, endpoint, adding, openapi, contract}
  desc: {new, http, endpoint, missing, openapi, spec}
  shared: {endpoint, openapi}
  unique: {add, adding, contract, new, http, missing, spec}
  
  overlap = 2 / 8 = 0.25  (does NOT match at threshold 0.55)
```

### Threshold (default: 0.55)

The balance at 0.55:
- **0.55 is medium-sensitive:** catches near-identical phrasing + clearly related approaches
- **Too high (0.7+):** misses differently-phrased failures; blocks only exact repeats
- **Too low (0.3):** over-blocks unrelated tasks; founder fatigue from false Tier B questions

### Tuning by codebase

| Codebase characteristics | Recommended threshold |
|---|---|
| Large, diverse (many subsystems, varied phrasing) | 0.65–0.70 |
| Medium (persona-engine size) | **0.55** (default) |
| Small, tight (few codepaths, consistent language) | 0.45–0.50 |

Override with env var:
```bash
LEADV2_NM_THRESHOLD=0.60
```

### Observed behavior

From persona-engine post-launch (2026-07):
- **0.55:** 1–2 false-positives per week (founder overrides); **zero false-negatives** (missed blocks); sweet spot.
- **0.4:** over-blocks unrelated tasks, ~1 false-positive per day.
- **0.65+:** occasional miss of differently-phrased but actually-same failure.

---

## Semantic Recall (MEM-SEMANTIC-RECALL-01)

### When enabled

Requires both:
1. `LEADV2_SEMANTIC_RECALL_ENABLED=1` (flag in `context.yaml` or env)
2. `LEADV2_RECALL_HELPER` set to the path of `scripts/leadv2-semantic-recall.sh` or equivalent

When either is missing or the helper fails (e.g., Qdrant down, network error) → semantic path silently disabled (fail-open); keyword overlap continues unaffected.

### Mechanism

Semantic recall uses **cosine similarity** to catch approaches phrased very differently but semantically equivalent:

```
Example:
  entry_approach: "PGRST102 partial-index upsert"
  description: "upsert conflict target could not be resolved on a partial unique index"
  
  keyword_overlap: 0.23 (misses due to different vocabulary)
  cosine_similarity: 0.78 (matches! semantic cosine >= 0.35 fires)
  
  Result: BLOCKED (caught by semantic path, not keyword)
```

### Call pattern

```bash
scripts/leadv2-semantic-recall.sh negmem "<approach_description>"
```

Returns top-3 matches: `<nm_id>:<cosine_score>` sorted by score (descending).

Example output:
```
NM-07:0.78
NM-14:0.62
NM-02:0.41
```

### Threshold

Semantic threshold is **0.35** (tuned for recall over precision). Any match >= 0.35 fires. At 0.35:
- Catches truly related failures despite vocabulary differences
- False-positive rate is low (~1 per 100 semantic-recall runs on persona-engine data)

### Ranking & tie-breaking

When both keyword AND semantic match fire:
- **Keyword overlap >= 0.55** is the primary signal (higher confidence).
- **Semantic >= 0.35** is the secondary signal (catches edge cases).
- No rank merging needed; either signal alone is sufficient to block.

If founder needs to distinguish which signal fired, the output file `docs/handoff/<task-id>/negative-memory-matches.yaml` logs both scores in each match entry.

---

## Algorithm Correctness & Edge Cases

### Phase matching

- `null` phase in the entry signature matches ANY phase. Useful for approach-only blocks that apply universally.
- `null` phase in current context is allowed (graph-reflect not run yet); filter still proceeds on change_kind and approach.

### Change-kind matching

- `null` change_kind in entry matches ANY change_kind.
- `null` change_kind in current context (unknown footprint) does not block C (approach check still fires).

### AND vs OR in unblock_criteria

Unblock criteria default to AND: all must be true to unblock.

Criteria with `OR:` prefix (e.g., `OR: ["openapi_updated", "spec_generated"]`) are an OR-group: at least one in the group must be true.

Example:
```yaml
unblock_criteria:
  - "openapi_updated: true"       # AND: must be true
  - "OR: ['spec_v1', 'spec_v2']"  # OR: at least one true
```

All conditions pass → unblock. Any AND-condition or any OR-group fails → block.

### Missing or malformed YAML

- Missing `docs/leadv2-negative-memory.yaml` → empty `entries` list, skill returns no matches, no error.
- Malformed YAML in an entry → skip that entry, log warning, proceed with others.
- Missing unblock_criteria → assume empty list; entry always blocks (no path to unblock).

---

## Monitoring & Maintenance

### TTL (Time-to-Live)

Entries have a `ttl_expires` date. Archive (move to `docs/leadv2-negative-memory-archive.yaml`) once past:

```bash
scripts/leadv2-negative-memory-compile.sh archive
```

Expired entries still in main file are treated as inactive (not loaded by Step 1).

### Candidate approval workflow

1. Failure observed in production → lead drafts candidate entry in `docs/leadv2-negative-memory.yaml` with `status: candidate`.
2. Skill skips candidate entries (only loads `status: active`).
3. Founder reviews candidate at next Tier B or reflection checkpoint.
4. Founder approves → founder calls `leadv2-negative-memory-compile.sh approve <nm_id>` (sets `status: active`).
5. Skill now blocks that entry.

### Semantic helper health

If semantic recall is enabled but the helper dies (Qdrant down, network error, script missing):
- First call to `leadv2-semantic-recall.sh` fails → error logged, but skill continues (keyword overlap still fires).
- Set `LEADV2_SEMANTIC_RECALL_ENABLED=0` if you want to skip the helper checks entirely.

---

## FAQ

**Q: Why 0.55 and not 0.5?**  
A: 0.5 is the crossover (50% match). 0.55 is slightly stricter, catching clear majority-match while avoiding the noisy boundary.

**Q: Can I disable semantic recall?**  
A: Yes. Set `LEADV2_SEMANTIC_RECALL_ENABLED=0` or don't set `LEADV2_RECALL_HELPER`. The filter will skip the semantic path.

**Q: What if keyword overlap is 0.54 but semantic is 0.36?**  
A: **MATCH** — semantic fires (>= 0.35), so the entry blocks. Either signal is sufficient.

**Q: If an entry has no phase, does it match recovery?**  
A: **Yes** — `null` phase matches any phase, including recovery.

**Q: What's the difference between `disposition: blocked` and `disposition: unblocked`?**  
A: `blocked` = unblock criteria not all met, approach should not be used. `unblocked` = criteria satisfied, approach is allowed but should log the rationale.
