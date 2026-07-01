# Model Routing — leadv2 plugin (universal, all consuming repos)

This is the plugin-level template for per-repo `docs/model-routing.md`. Each consuming
repo (persona-engine, m3-market, respiro-ios, ...) may keep its own concrete copy with
repo-specific numbers; this file is the shared authority for the ARCHITECTURE behind it.

## Gating metric = Claude token QUOTA, not dollars

If the founder is on a Claude subscription, $/token pricing is irrelevant. Measured burn
across repos: the overwhelming majority of tokens is **cache-read** (context re-read every
turn), not output. Per-turn token load is roughly MODEL-INDEPENDENT — the real cost of a
heavier model (e.g. Opus) is its weight against a plan's tighter weekly cap, not raw
token count. Route on QUOTA PRESSURE, not sticker price.

## The three quota levers (in order of impact)

1. **Codex offload** — a separate ChatGPT token pool = ZERO Claude quota. The single
   biggest lever available. Route anything code-shaped to Codex FIRST where the repo has
   opted in (see below).
2. **Context discipline** — compact at the turn cap, fewer parallel sessions, don't revive
   cold sessions. This dwarfs any model-choice saving.
3. **Model choice** — second-order. Route by difficulty × volume (below).

## Route by DIFFICULTY x VOLUME

| Workload | Lane | Why |
|---|---|---|
| Code (any volume) | **Codex** (where `codex_enabled: true`) | off Claude quota entirely; more volume = more saved |
| High-volume Claude bulk (fan-out, reads, mechanical) | **Sonnet-low / Haiku** | light quota weight; protects the Opus/Fable cap at volume |
| Hard / high-value minority (architecture, root-cause, tricky logic, safety) | **Opus / Fable** | few turns, quality pays for itself |
| Lead decisions / routing | **Fable** (or the repo's pinned lead model) | thin router, not a thinker |

Rule: **VOLUME -> cheap lane (Codex/Sonnet/Haiku); HARDNESS -> smart lane (Opus/Fable).**
Codex-first for anything code-shaped, in any repo that has opted in. Never run Sonnet
above `low` effort without escalating — if it needs more, it needs Opus/Fable or Codex,
not a longer Sonnet run.

## Per-agent defaults (template — tune per repo)

| Subagent | Model | Codex? |
|---|---|---|
| lead (orchestrator) | repo's pinned lead model (e.g. Fable) | -- |
| **developer** | Codex-first where enabled; Sonnet fallback (parallel fan-out) | YES |
| **critic / review** | Codex-primary + Sonnet/Opus critic as second opinion | YES |
| architect | Sonnet (Opus/Fable on Heavy classification) | -- |
| postgres-pro | Sonnet | opt |
| frontend-developer | Sonnet | rare |
| devops-engineer | Sonnet (commits on Haiku) | no |
| security-auditor | Sonnet | opt |
| Explore / discovery | Haiku | no |
| product-owner / strategist | Sonnet | no |

## Codex-first is gated per-repo, never global

Codex-first routing is **NOT** a plugin-wide default — it is gated by each repo's own
`.claude/leadv2-overrides/codex-policy.yaml`:

```yaml
codex_enabled: true          # opt-in; default is false/absent = Codex OFF
codex_first_class: true      # optional: default to Codex on plan/review + fitting dev
```

- `leadv2-block-codex.sh` (PreToolUse:Agent+Bash) hard-BLOCKS any Codex invocation
  (`subagent_type=codex:*`, `codex-task.sh`, raw `codex` CLI) when `codex_enabled` is
  false or the policy file is missing. This is the enforcement half.
- `leadv2-codex-first-nudge.sh` (PreToolUse:Agent) is the WARN-only companion: when a
  repo HAS opted in (`codex_enabled: true`) and the lead spawns a fitting build/review
  role (`developer`, `postgres*`, `frontend*`, `critic`, `security*`) WITHOUT routing to
  Codex, it prints a single stderr reminder — never blocks, never denies, always exits 0.
  Silent everywhere else (policy absent/false, or subagent already Codex-routed).
- **Never edit another repo's `codex-policy.yaml` from this plugin repo or from a
  different repo's session.** Each repo's founder-directive opt-in is authoritative and
  repo-local; the plugin only supplies the mechanism (both hooks), not the policy value.

## Codex quota EXHAUSTION — fallback ladder

Codex runs on its own subscription pool with its own rolling usage caps. When Codex
fails (login down OR quota exhausted — `codex-task.sh` exits non-zero / rate-limited):

1. **SURFACE to founder** ("Codex unavailable: `<login|quota>` — falling back to
   Claude"). Never degrade silently.
2. **Fall back by task type onto Claude quota:**
   - code, hard → Opus/Fable (low/med effort)
   - code, bulk → Sonnet (low effort)
   - review/critic → Sonnet critic (Opus/Fable if safety-touched)
3. This loads the Claude quota — watch the Opus/Fable weekly cap. A `downgrade_chain`
   (e.g. `fable->sonnet`) should auto-catch cap strain; Haiku is the last-resort floor.
4. Codex caps are a ROLLING window — retry Codex-first on the next session/task; don't
   stay parked on the Claude fallback once Codex recovers.

**Full ladder:**
`Codex -> [hard: Opus/Fable | bulk: Sonnet | review: Sonnet-critic] -> Sonnet (cap valve) -> Haiku`

## Per-repo concrete copies

- `persona-engine/docs/model-routing.md` — Codex first-class (founder directive
  2026-07-01), full measured-burn numbers.
- `m3-market/.claude/leadv2-overrides/codex-policy.yaml` — `codex_enabled: true`.
- Other repos (respiro-ios, ...) — Codex OFF by default until the founder explicitly
  opts in via that repo's own `codex-policy.yaml`. Do not flip it from here.

---
Template source: adapted from `persona-engine/docs/model-routing.md` (2026-07-01) for
plugin-wide reuse. Each repo may extend with its own measured burn data; the mechanism
(policy gate + WARN-only nudge hook) is shared and lives in this plugin.
