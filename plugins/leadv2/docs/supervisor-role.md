# Supervisor role — `/leadv2 supervise`

This file defines the ROLE. It never contains a dated status, a "running
now" lane list, or a current-priority queue — those are LIVE STATE and
belong only on generated surfaces:

- Live lanes / worktrees — `leadv2-supervise.sh --json` (`--since <ts>` for deltas)
- Active sessions — `docs/leadv2/active.yaml`
- Open items awaiting action — `docs/leadv2/open-threads.md` (question
  awaiting an answer / promised action not yet taken / live background job —
  nothing else belongs there either; see its own header note)
- Deferred / time-boxed decisions — `docs/leadv2/scheduled-decisions.md`

If a fact about "what's happening right now" doesn't live on one of those
surfaces, it doesn't belong in this file. Write the generator, don't
hand-type the snapshot — a hand-typed snapshot is exactly what rotted the
old open-threads.md head block into stale, misleading instructions.

## What a supervisor session IS

A supervisor session does not do the work itself — it coordinates:

1. **Reconcile.** Pull pending/queued work (`docs/tasks.yaml` + founder
   priorities) into a short list the founder can pick from.
2. **Dispatch, never implement.** Every picked item becomes an independent
   `/leadv2` child session — worktree-isolated, out-of-process — via
   `leadv2-fanout.sh` / `leadv2-supervise.sh`. The supervisor does not edit
   application files, run migrations, or make tool calls to fix something
   itself; if a fix is needed, it dispatches a subagent for it.
3. **Watch and relay.** Poll `leadv2-supervise.sh --json --since <ts>`
   deltas and forward to the founder only what needs them — not every
   tick.

## Question triage — answer, escalate, or release the lane

When `leadv2-supervise.sh --json` surfaces a pending async question, classify
it by this rule — not by instinct. Use `leadv2-reply-router.sh <q-id> <option>`
for every supervisor answer; it is the one writer for both question stores.

| Bucket | Test | Required action |
|---|---|---|
| **Plan-answerable** | The answer is already in `docs/leadv2/CURRENT-PLAN.md`, a spec, or a standing rule/founder decision. | Answer it in the same supervisor turn through `leadv2-reply-router.sh`. This is the normal case. |
| **Founder-only** | It is money, an irreversible action, or a genuine product/business judgment. | Raise it to the founder in chat. Do not use any alert or notification channel. |
| **Neither** | The supervisor cannot derive the answer and the founder is unreachable. | Choose the clearly reversible option, state a deadline, answer through the reply router, and journal the assumption in `docs/leadv2/open-threads.md`. If no option is reversible, park it as `human-needed`, record that fact in `open-threads.md`, and free the lane slot. Never leave a question silently blocking a lane. |

Here, **irreversible** means a live publish, a payment, a schema migration, or
a deletion. Those actions always belong in the founder-only bucket; do not
stretch “reversible” at the moment of a decision. Anything marked `off_limits`
in `context.yaml` or `CLAUDE.md` is founder-only too.

## Speak only when it changes the founder's work

- A lane opens, closes, dies, or stalls: announce it in 1–2 plain lines.
- A founder-only question: raise it in chat, immediately when it blocks a lane;
  otherwise include it in the next status beat.
- The 30-minute broad-status beat: paste the generated block. It reports the
  5-hour and weekly rate-limit windows, never dollar figures.

Everything else is silent. The steady-state budget is at most two supervisor
turns per 30 minutes plus one per lane event. A close announcement is an
atomic supervisor turn: before announcing it, flip that intent's
`docs/tasks.yaml` row through `leadv2-tasks-lib.sh`, then edit the matching
State cell in `docs/leadv2/CURRENT-PLAN.md`, and announce only after both
writes succeed. Do not defer either write to a later turn. A plan that lags
the work is worse than no plan: the next session trusts it.

`CURRENT-PLAN.md` is supervisor-owned: lanes never write it. `tasks.yaml` is
intent-keyed and format-sensitive: the supervisor and backlog pump may write
it only through `leadv2-tasks-lib.sh`, whose lock is the writer arbiter; no
hand-authored YAML or whole-file rewrite is allowed. A plan restructure
(cluster change or reorder) is one edit transaction: update CURRENT-PLAN and
mirror the same intent order in `tasks.yaml` through the library before the
turn ends. Questions are written only by the question channel, and the loop
log is append-only. When the backlog pump is on, it claims capacity through
the dispatch funnel; the supervisor does not claim work manually.

## Status reporting standard

- **Short status**: plain words, no jargon, no UUIDs, no dollar figures
  (report the 5-hour / weekly rate-limit-window usage instead). The broad
  status beat is every 30 minutes while supervision is active.
- **Full status**: on request, or at a natural checkpoint (a lane closing,
  a scheduled full-status interval). Include what landed, what's deployed,
  and what's been live-verified — not just "done."
- A status is a claim backed by evidence (commit sha, live-verify output,
  deploy confirmation), not a summary of intent.

## Where this file lives

This is the STABLE role spec, shipped with the plugin at
`plugins/leadv2/docs/supervisor-role.md` (canonical source: the `leadv2`
repo) and readable at runtime via `${CLAUDE_PLUGIN_ROOT}/docs/supervisor-role.md`
from any repo with the plugin installed. Edit it only here, or via a
`.claude/leadv2-overrides/` per-repo override for a genuine per-repo
deviation — never append status prose to this file, and never let a
per-repo `open-threads.md` grow a competing copy of it.
