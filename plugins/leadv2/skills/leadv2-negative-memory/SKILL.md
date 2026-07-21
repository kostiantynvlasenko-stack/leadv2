---
name: leadv2-negative-memory
description: "[internal] Match active negative-memory failures before Plan, Build, Review, and Recovery; block repeated failed approaches."
allowed-tools:
  - Read
  - Write
  - Edit
  - Bash
---

# Lead v2 Negative Memory — Don't-Retry Priors

## When
- **Plan phase:** before emitting `plan.steps` — run this skill; reject or gate any step matching active blocks.
- **Build phase:** before spawning developer — run this skill; add matches to developer mission brief.
- **Review phase:** after Codex/critic findings — if diff matches a negative pattern, auto-elevate severity to Critical.
- **Recovery phase:** before retry — check if the retry approach would reproduce a negative entry.

## When NOT
- Trivial tasks (skip to build) — still run at build start.
- After task is closed (use `leadv2-close` and `lead-reflect` instead).

---

## Protocol

### 1. Load negative memory

```python
import yaml
from pathlib import Path

nm_file = Path("docs/leadv2-negative-memory.yaml")
if not nm_file.exists():
    # Skill returns empty matches — no error
    entries = []
else:
    data = yaml.safe_load(nm_file.read_text()) or {}
    entries = [e for e in (data.get("entries") or []) if e.get("status") == "active"]
```

If `docs/leadv2-negative-memory.yaml` is missing → return empty matches, proceed normally.

### 2. Parse current task signal

From `context.yaml` (or intake signal if plan not yet synthesized):
- `current_phase`: one of `intake|plan|build|review|deploy|verify|recovery|close`
- `change_kind`: from `graph_footprint.change_kind` (may be null if graph-reflect not yet run)
- `approach_description`: free-text from the proposed plan step, developer mission, or recovery option being evaluated

### 3. Match filter

For each active entry in negative memory:

```
MATCH if ALL of:
  A. entry.signature.phase == current_phase
     OR entry.signature.phase is null (matches any phase)
  B. entry.signature.change_kind == current change_kind
     OR entry.signature.change_kind is null
     OR current change_kind is null (unknown footprint — still check approach)
  C. keyword_overlap(entry.signature.approach, approach_description) >= 0.55
     (count shared significant words / total unique words in entry.signature.approach)
     # Threshold is tunable via LEADV2_NM_THRESHOLD env var (default 0.55).
     # Lower = more sensitive (more blocks); 0.4 was over-blocking unrelated tasks.
     # Raise to 0.65+ for large diverse codebases; lower to 0.45 if misses are observed.
     OR fused-top-3(approach_description) includes this entry with cosine >= tau_sem (0.35)
     # MEM-SEMANTIC-RECALL-01: additive OR-path. Only active when
     # LEADV2_SEMANTIC_RECALL_ENABLED=1 and LEADV2_RECALL_HELPER is set — call
     # scripts/leadv2-semantic-recall.sh negmem "<approach_description>" and
     # RRF-fuse (k=60) with the keyword_overlap ranking, same rule as
     # leadv2-immune-lookup.sh §2. Flag off, or helper missing/Qdrant down
     # (fail-open empty semantic list) => this OR-term is never true; the
     # keyword_overlap>=0.55 check above is unaffected either way (semantic
     # only ADDS a match, never suppresses one).
```

Keyword overlap is approximate. At 0.55 the balance is: occasional unrelated block (ask founder) vs missed block (causes rollback). Tune if false-positive rate is high. Semantic OR-path catches the differently-phrased case (e.g. "PGRST102 partial-index upsert" vs "upsert conflict target could not be resolved on a partial unique index") that keyword_overlap alone misses.

### 4. For each match — enforce or allow

**Check unblock_criteria:**

For each criterion in `entry.unblock_criteria`:
- Regex check on plan text / diff / context.yaml fields.
- Explicit flags in `context.yaml` (e.g., `openapi_updated: true`).
- OR-prefixed criteria: at least one OR-group must be satisfied.

**Decision:**

| Unblock status | Action |
|---|---|
| All criteria satisfied | Allow. Log `negative-memory-unblock: <id>` in context.yaml under `reviews.negative_memory`. |
| Any criterion fails | **BLOCK:** Tier B decision — "this approach failed before (<NM-id>: <failure_mode>); unblock-criteria not all met. Proceed anyway? [default: redesign via architect in 10 min]" |
| No unblock_criteria defined | Always block — approach has no known path to being re-enabled. |

Tier B default-timeout question format (write to `docs/leadv2-decisions/<task-id>-nm-<NM-id>.yaml`):

```yaml
id: <task-id>-nm-<NM-id>
task_id: <task-id>
type: tier-b
trigger: negative-memory-block
question: "Negative memory NM-XX matched: '<approach>' previously caused '<failure_mode>'. Unblock criteria not all met. Proceed anyway?"
options:
  A:
    label: "Redesign — use architect(opus) to find alternative approach"
    description: "Spawn architect to propose alternative that avoids the failure mode"
    default: true
  B:
    label: "Override — proceed with original approach"
    description: "Accept the risk; lead documents rationale in context.yaml"
status: pending
expires_at: <now + 10min ISO>
default_option: A
nm_id: <NM-id>
```

### 5. Output — write matches file

Write `docs/handoff/<task-id>/negative-memory-matches.yaml`:

```yaml
task_id: <id>
checked_at: <ISO timestamp>
phase: <current_phase>
approach_description: "<text used for matching>"
matches:
  - nm_id: NM-01
    entry_approach: "add new endpoint without adding to OpenAPI contract"
    failure_mode: "endpoint works but dashboard can't discover it; user-facing invisible"
    ttl_expires: 2026-07-15
    unblock_criteria_met: 2
    unblock_criteria_total: 2
    disposition: unblocked   # unblocked | blocked | no-match
    log: "negative-memory-unblock(NM-01): OpenAPI contract updated in same PR"
no_matches: false   # true if entries list was empty
```

### 6. Inject into subagent missions

When spawning developer or recovery architect, append to their mission brief:

```
## Negative memory (pre-checked by lead)
Read docs/handoff/<task-id>/negative-memory-matches.yaml.
- Any entry with disposition=blocked → DO NOT use that approach. Redesign required.
- Any entry with disposition=unblocked → approach allowed; log the unblock reason in your deliverable.
```

---

## Review phase integration

After Codex/critic findings arrive:

1. For each finding in the review, extract: affected file path, change type, approach description from the diff hunk.
2. Run match filter (Step 3) against active negative-memory entries using the finding's approach as input.
3. If match found AND disposition=blocked → auto-elevate finding severity to **Critical**.
4. Append to `docs/handoff/<task-id>/negative-memory-matches.yaml` under `review_phase_matches:`.

---

## Recovery phase integration

Before architect(opus) retry brief is written:

1. Extract proposed retry approach from recovery brief.
2. Run match filter with `current_phase: recovery`.
3. If disposition=blocked → prepend to recovery brief:
   ```
   NEGATIVE MEMORY BLOCK: approach "<X>" previously caused "<failure_mode>" (NM-YY).
   Unblock criteria not met. Architect MUST propose alternative — do not retry same approach.
   ```

---

## Rules

- `pyyaml.safe_load` for all YAML I/O — never `yaml.load`.
- If negative-memory yaml missing → empty matches, no error. Never hard-fail.
- Keyword overlap is approximate heuristic — over-match is safer than under-match.
- Tier B default-timeout: default = redesign (not proceed). Founder silence = architect spawned.
- Never add `status: active` entries directly — new entries start as `candidate` and require founder Tier B approval (see `leadv2-negative-memory-compile.sh`).
- Archive entries when `ttl_expires` is past — move to `docs/leadv2-negative-memory-archive.yaml`.

## Anti-patterns

- Skipping this check because "the plan looks different" — run the filter, let keyword overlap decide.
- Auto-approving a candidate entry without founder Tier B confirmation.
- Blocking on an expired entry — check `status == "active"` strictly.
- Writing to the archive instead of the main file for new candidates.
