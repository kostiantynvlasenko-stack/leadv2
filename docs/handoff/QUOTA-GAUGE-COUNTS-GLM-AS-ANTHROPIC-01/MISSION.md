# Mission — the quota gauge counts GLM's tokens as Claude Max usage, and throttles the lead for it

**Task:** `654974b8632a`.
**Read first:** `docs/handoff/QUOTA-GAUGE-COUNTS-GLM-AS-ANTHROPIC-01/FINDING.md` — it has the live
numbers and the re-runnable proof. Do not re-derive them; verify and move on.
**File to fix — CANONICAL ONLY:** `~/Projects/leadv2/plugins/leadv2/scripts/leadv2-quota-status.sh`
(the bug is at lines ~52/56/60). You are running with `--cwd ~/Projects/leadv2`, so this is in scope.

The script exists in THREE places — canonical (above), `~/.claude/leadv2-shared/scripts/`, and
`~/.claude/scripts/` — all byte-identical today. **Edit canonical, then propagate with
`bash plugins/leadv2/scripts/leadv2-plugin-sync.sh`.** If you edit a copy instead, the next sync
silently reverts you; that exact accident ate three shipped fixes on 2026-07-16.

This is a SHARED edit — it lands in all repos. The founder chose that deliberately (a quota gauge
reads one account-wide burn db; a per-repo override would be meaningless). Do not create an override.

**Do not touch anything else in `~/Projects/leadv2`.** Its tree has pre-existing WIP from other
sessions, including a deleted `plugins/leadv2/agents/SCHEMA.md` that is NOT yours — leave it exactly
as-is. `git add <specific paths>` only, never `git add -A`. Any stashes there are other people's.

## The bug

The gauge does `SELECT SUM(input) FROM turn_events WHERE ts > datetime('now','-5 hours')` with **no
model filter** — but `turn_events` HAS a `model` column, and `glm-coder.sh` drives the same `claude`
CLI against Z.AI's Anthropic-compatible endpoint, so GLM runs land in the same
`~/.claude/burn/history.db`. Live 5h split: GLM 1,507,004 input vs Anthropic **2,748**. So 99.8% of
the "Anthropic usage" it reports is GLM.

**Why this is worse than a wrong number:** the gauge gates a circuit breaker (`--check` exits 1 at
85%, warns at 60%, routing downgrades opus→sonnet). Push work onto GLM — which is the entire point
of GLM-FIRST-01 — and the gauge climbs until offloading to GLM **throttles the Anthropic lead**. The
instrument punishes the strategy it exists to protect.

## What to build

1. **Group every quota query by provider.** `model like 'glm%'` = Z.AI subscription;
   `model like 'claude%'` = Claude Max. They are different subscriptions with different caps; summing
   them together is meaningless.
2. **Report input + cache_read + output per provider, not input alone.** Anthropic sessions run
   almost entirely on cache: 2,748 input vs **278,748,383 cache_read** in the same 5h. `input` alone
   measures nearly nothing of what a Max session consumes.
3. **The `--check` breaker must gate on `claude*` ONLY.** This is the load-bearing fix. Never let
   GLM volume throttle the lead.
4. **Capture `rate_limit_info` when present.** The provider's own signal (`rateLimitType: five_hour`,
   `resetsAt`, `overageStatus`) appeared in a lane log at ~05:00Z on 2026-07-17 and is captured
   nowhere. If you can persist it into `history.db`, prefer it over the heuristic cap — a gauge that
   reads the provider's own number stops being folklore. If that plumbing is out of reach in this
   task, say so explicitly and leave the hook for it; do not fake it.
5. **Codex usage is not in this db at all** (ChatGPT subscription, unmeasured). The report must SAY
   "Codex: unmeasured" rather than implying zero.
6. The 8M/100M caps are the script's own self-declared heuristic. Label them as estimates in the
   output. A guessed fraction of a guessed cap must not read like a measurement.

## Acceptance — paste real terminal output

1. `bash ~/.claude/scripts/leadv2-quota-status.sh` before and after, side by side.
2. The per-provider sqlite query and its output, showing Anthropic's real 5h numbers.
3. `--check` proof: with GLM at >1.5M input in the window, `--check` must NOT trip on GLM's account.
   Show the exit code.
4. A test that fails if the model filter is ever dropped again.

## Deliverable

`~/Projects/persona-engine/docs/handoff/QUOTA-GAUGE-COUNTS-GLM-AS-ANTHROPIC-01/glm-result.md` —
diff + the 4 proofs + what you did about `rate_limit_info` (built / left a hook / why).
End with `DELIVERABLE_COMPLETE`.
