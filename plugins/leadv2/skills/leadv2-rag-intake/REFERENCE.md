# leadv2-rag-intake — Reference

Reference material for similarity interpretation, downstream integration, and defensive patterns.

---

## Thresholds

How to interpret similarity scores in the RAG output:

| Similarity | Treatment |
|---|---|
| ≥ 0.75 | Strong prior art — surface lessons prominently in Plan phase |
| 0.60–0.74 | Moderate — note in prior-art.yaml, mention in Plan |
| 0.40–0.59 | Weak — include in file but label "weak signal" |
| < 0.40 | Cold territory — prior-art.yaml written as `[]` |

**Default gate:** entries with similarity < 0.60 are excluded from Plan phase missions.

---

## Output examples

Guidance for Step 7 (lead chat output). All examples one line, ≤25 words, Russian preferred:

- **Top match ≥ 0.75, outcome success:**  
  "Похоже на <task_id> (sim 0.87, успех). Подход: <1-word strategy from key_lessons>."

- **Top match ≥ 0.60, outcome rolled_back:**  
  "⚠ Похоже на <task_id> (sim 0.73, откат). Разобрать уроки перед планом."

- **Top match 0.40–0.59, any outcome:**  
  "Слабое совпадение с <task_id> (sim 0.52). Ориентировочно."

- **No match or < 0.40:**  
  "Новая территория — нет похожих задач."

---

## Feed into Plan phase

When the architect/Codex planner receives the task context, include prior-art.yaml content as a top-level section in the mission file (e.g., `/tmp/mission-<id>.md` or `docs/handoff/<id>/context.yaml`):

```yaml
prior_art:
  - task_id: ...
    similarity: 0.87
    outcome: completed_success
    key_lessons:
      - "when Gate 1 plan bundles commit+deploy into final build step → split explicitly"
```

**Filtering rule:** Only include entries with similarity >= 0.60.  
If no entries qualify, omit the prior_art section entirely.

---

## Anti-patterns

Pitfalls to avoid:

- **Blocking intake if fastembed is slow on first run** (model download). The script exits 0 regardless; embedding slowness is not a failure.
- **Reading all of LEAD_V2_STATE.md inline** during this step. The bash script handles parsing; don't duplicate.
- **Including prior-art entries with similarity < 0.60** in Plan phase mission files. The threshold gate exists to reduce noise.
