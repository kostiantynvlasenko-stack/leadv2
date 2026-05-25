# Verify Contracts — Phase 7 templates

Reusable verification contracts for `verify-probe.sh`. Each yaml describes a
class of "no-regression" check that recurs across tasks. Plan-time, architect
copies one or more entries into `context.yaml.verification.live_signal[]`.

## Pattern

```yaml
- name: <unique-key>
  type: positive | no-regression
  query: <sql or shell>   # MUST be idempotent + read-only
  exit_contract:
    0: ok
    1: warn  # numeric — log only, don't block
    2: block # task fails Phase 7, triggers Phase 7 recovery
  timeout_sec: 60
```

## Available templates

| File | What it verifies | Class of task |
|---|---|---|
| `voice-floor.yaml` | After deploy, `agent_outputs.voice_score` for the touched persona stays >= `personas.{id}.config.voice_floor` over next 10 generations | safety-gate, voice changes |
| `content-analysis-freshness.yaml` | `content_analysis` row count for persona stays within 20% of `posts` count over 14d window | strategist briefing, content_analysis backfill |
| `engagement-baseline.yaml` | engagement_24h rolling p50 doesn't drop more than 40% post-deploy over 48h window | bandit / scoring / strategy changes |

## When to add a new template

If you write the same SQL/probe in `context.yaml.verification` of 3+ tasks
across one month, extract it here. Anchor the extraction with a one-line
reason citing the source task_ids.

## Off-limits

- Never put a write-query in a verify contract
- Never let a contract time out >120s
- Contracts are advisory inside Phase 7 — they signal regression, they do not
  judge feature correctness. That's `verify-probe.sh` positive signal.
