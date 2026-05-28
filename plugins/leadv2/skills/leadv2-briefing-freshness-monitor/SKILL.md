---
name: leadv2-briefing-freshness-monitor
description: "[PE-domain only] Health check for strategist briefing inputs (content_analysis vs posts). Applies ONLY when: personas/ directory exists at project root AND stack.yaml db == supabase. Skip (no-op) in all other projects. Invoke via /leadv2 health subcommand; not auto-fired in /leadv2 cycles."
allowed-tools:
  - Read
  - Write
  - Bash
---

# Lead v2 Briefing Freshness Monitor

> **Precondition — skip unless BOTH are true:**
> 1. A `personas/` directory exists at the project root.
> 2. `.claude/leadv2-overrides/stack.yaml` has `db: supabase`.
>
> If either condition is absent: **exit 0 / no-op silently** — do not proceed.
>
> ```bash
> # Guard (run first, before any other step):
> [[ -d "personas" ]] || exit 0
> source "${CLAUDE_PLUGIN_ROOT}/scripts/leadv2-helpers.sh"
> [[ "$(_lv2_stack_scalar db '')" == "supabase" ]] || exit 0
> ```

## When
- Invoked explicitly: `/leadv2 health`
- Cron (recommended daily): `bash plugins/leadv2/scripts/leadv2-briefing-freshness.sh --cron`
- Optional auto-trigger: Phase 0 if `docs/agents/strategist/HEALTH.md` mtime > 24h

## When NOT
- Inside a build/review phase — never blocks pipeline
- If Supabase env vars missing — log skip, no error

## What it checks

For each active persona (from `personas/*/config.yaml` where `active: true`):

1. **content_analysis row count** for last 14 days
2. **posts count** for last 14 days
3. **divergence ratio** = (posts - content_analysis) / max(posts, 1)
4. **strategist-weekly last run** from `docs/agents/strategist/<persona>/LAST_RUN.md` (date field)

Flag if ANY:
- `divergence_ratio > 0.20` (>20% of posts missing analysis)
- `posts > 0` AND `content_analysis = 0` (cold-start trap)
- `last_run` older than 8 days (weekly cadence broken)

## Protocol

### 1. Resolve personas
```bash
PERSONAS=$(find personas -mindepth 2 -maxdepth 2 -name 'config.yaml' \
  -exec grep -l 'active: true' {} \; \
  | sed 's|personas/||;s|/config.yaml||')
```

### 2. Per-persona query (psql via existing helper)
```bash
for p in $PERSONAS; do
  posts=$(psql "$SUPABASE_DB_URL" -tAc "
    SELECT count(*) FROM posts
    WHERE persona_id = (SELECT id FROM personas WHERE handle = '$p')
      AND created_at > now() - interval '14 days'")
  analyzed=$(psql "$SUPABASE_DB_URL" -tAc "
    SELECT count(*) FROM content_analysis
    WHERE persona_id = (SELECT id FROM personas WHERE handle = '$p')
      AND analyzed_at > now() - interval '14 days'")
  # compute divergence, flag if threshold breached
done
```

### 3. Emit HEALTH.md
```markdown
# Strategist Briefing Health — <YYYY-MM-DD HH:MM UTC>

| Persona | Posts (14d) | Analyzed | Divergence | Last weekly | Status |
|---|---|---|---|---|---|
| nik | 61 | 58 | 4.9% | 2026-05-13 | OK |
| respiro | 84 | 22 | 73.8% | 2026-05-05 | ⚠ STALE |
| marco | 12 | 0 | 100% | never | ⚠ COLD |

## Actions suggested
- respiro: run `bash scripts/backfill-content-analysis.sh respiro --since 2026-05-05`
- marco: bootstrap — register first weekly run via `/leadv2 meeting strategist`
```

### 4. Surface in /leadv2 greeting
Lead's startup compact reader checks for `⚠` in HEALTH.md (Phase 0). If found, includes one line in greeting:
> `briefing-health: respiro STALE 73.8%, marco COLD ⇒ /leadv2 health for details`

## Off-limits
- NEVER auto-run backfill — only suggest
- NEVER touch DB write operations from this skill
- Health output is advisory; never blocks gates

## Retro signal that motivated this skill

Week 2026-05-12: founder caught `content_analysis` empty for Respiro by hand (briefing said 0 posts vs 61 real). 272-row manual backfill + strategist-weekly.sh date-fix commit. Pure observability gap — no proactive monitor existed.
