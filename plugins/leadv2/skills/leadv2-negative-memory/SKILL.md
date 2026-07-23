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

For each active entry in negative memory, **match if ALL of:**

```
A. entry.signature.phase == current_phase
   OR entry.signature.phase is null (matches any phase)
B. entry.signature.change_kind == current change_kind
   OR entry.signature.change_kind is null
   OR current change_kind is null (unknown footprint — still check approach)
C. keyword_overlap(entry.signature.approach, approach_description) >= threshold (default 0.55)
   OR semantic similarity via optional helper >= 0.35
   [See REFERENCE.md for threshold tuning & semantic recall details]
```

Keyword overlap counts shared significant words / total unique words. Semantic match uses cosine similarity when enabled. **Either match fires a block.**

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
