# QUOTA-GAUGE-COUNTS-GLM-AS-ANTHROPIC-01 — the quota gauge attributes GLM's tokens to the Anthropic subscription

Founder asked: measure GLM/Codex/Anthropic in **subscription remainder** (5h / weekly), not dollars,
and answer whether leaning hard on GLM actually pays. Measuring first surfaced a broken instrument.

## The bug

`~/.claude/scripts/leadv2-quota-status.sh` reports the rolling 5h window as:

```
Quota: 5h 18% (1509752 / 8000000 in) | weekly 1% | cache-hit 1.00 | safe
```

Its queries (`leadv2-quota-status.sh:52,56,60`) are `SELECT SUM(input) ... FROM turn_events WHERE ts
> datetime('now','-5 hours')` — **with no model filter at all.** But `turn_events` has a `model`
column, and `glm-coder.sh` drives the same `claude` CLI against Z.AI's Anthropic-compatible endpoint
(`ANTHROPIC_BASE_URL=https://api.z.ai/api/anthropic`), so every GLM run lands in the same
`~/.claude/burn/history.db` the gauge reads. Split by model:

| provider | input | output | cache_read | turns |
|---|---|---|---|---|
| GLM (Z.AI sub) | **1,507,004** | 332,323 | 17,984,192 | 235 |
| ANTHROPIC (Max sub) | **2,748** | 874,828 | 278,748,383 | 1,414 |

**99.8% of the "Anthropic 5h usage" the gauge shows is GLM** — tokens that never touch Anthropic.
Real Anthropic input in that window: 2,748, i.e. **0.03%** of the cap, not 18%.

Re-runnable proof:
```
sqlite3 -column -header ~/.claude/burn/history.db "select case when model like 'glm%' then 'GLM'
  else 'ANTHROPIC' end p, sum(input), sum(output), sum(cr), count(*) from turn_events
  where ts > datetime('now','-5 hours') group by 1;"
bash ~/.claude/scripts/leadv2-quota-status.sh
```

## Why this is worse than a wrong number

The gauge is wired to a **circuit breaker**: `--check` exits 1 above 85% of the 5h window and warns
at 60%, and routing has an `opus→sonnet` downgrade chain. So the more work we push onto GLM — which
is the entire point of GLM-FIRST-01 — the higher this gauge climbs, until offloading to GLM
*throttles the Anthropic lead*. **The instrument punishes the strategy it exists to protect.** Today
it reads 18% while true Anthropic input is 0.03%; the same day GLM-FIRST-01 finally got an enforcer,
which will drive GLM volume up further.

## Second defect: `input` is the wrong metric for Anthropic anyway

Anthropic sessions run almost entirely on cache: 2,748 input vs **278,748,383 cache_read** in 5h.
Summing `input` alone measures almost nothing of what a Claude Max session actually consumes.
Any honest gauge must count input + cache_read + output, per provider, separately.

## Third: the cap itself is a guess

The script's own header says so — "Budgets (heuristic ...): 5h input cap ≈ 8M tokens, weekly ≈ 100M".
So `18%` is a guessed fraction of a guessed cap, computed over the wrong provider. Three
independent reasons the number means nothing. The only real Anthropic quota signal we have ever
observed is `rate_limit_info` (`rateLimitType: five_hour`, `resetsAt`, `overageStatus`) in API
responses — seen in a lane log at ~05:00Z on 2026-07-17. It is not currently captured anywhere.
**Capture that, and the cap stops being folklore.** (Related: the lead generalised one lane's
`overageStatus: rejected` into "the account is walled until 09:40Z" and was wrong — a real captured
signal would have settled it in seconds.)

## What to build

1. Group every quota query by provider (`model like 'glm%'` vs `claude%`). GLM burns the Z.AI
   subscription; Codex burns the ChatGPT one; only `claude*` touches Claude Max.
2. Report input + cache_read + output per provider — not input alone.
3. Capture `rate_limit_info` from API responses into `history.db` when present, and prefer it over
   the heuristic cap. A gauge that reads the provider's own number cannot be folklore.
4. The `--check` breaker must gate on **Anthropic-only** usage. Never let GLM volume throttle the lead.
5. Codex usage is not in this db at all — it goes through the ChatGPT subscription and is currently
   unmeasured. Say so in the report rather than implying zero (`feedback-column-with-no-writer-lies-zero`).

## The founder's actual question, answered with today's numbers

**Is leaning on GLM paying off? For code volume — yes, decisively. For total Anthropic burn — it
does not touch the biggest consumer, which is the lead itself.**

- GLM absorbed 1.5M input / 332K output in 5h across 235 turns of real code work. None of it hit
  Claude Max.
- Anthropic in the same window: 2,748 input but **874,828 output over 1,414 turns** — 2.6× GLM's
  output. That is not subagents; it is this orchestrating conversation.

So GLM-FIRST correctly moved code-writing off Claude Max, and the remaining Anthropic burn is the
lead's own reasoning and long context — which no amount of GLM offloading reduces. If Claude Max
pressure needs to come down further, the lever is the lead's context discipline (shorter turns,
fewer re-reads, earlier compaction), not more GLM lanes.

Caveat, stated plainly: these come from our own burn db, not from any provider's quota API. Until
`rate_limit_info` is captured, treat the *ratio* as solid and the *percentage-of-cap* as unknown.
