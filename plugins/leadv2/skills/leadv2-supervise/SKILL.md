---
name: leadv2-supervise
description: "[internal] D-f=variant A (fat interactive supervisor, SUPERVISE-V2-01). The main /leadv2 lead reconciles+adopts existing work, lets the founder pick <=5 tasks, runs them as IN-SESSION Workflow/bg-agent lanes (own worktree each), and attaches leadv2-supervise-loop.sh via Monitor to watch. Legacy tmux/headless fanout (leadv2-fanout.sh) is supervised too but is compatibility-only, not the default dispatch path."
allowed-tools:
  - Bash
  - Read
  - AskUserQuestion
  - Monitor
  - Workflow
  - Agent
---

# Lead v2 Supervise Mode (D-f = variant A)

## When: founder wants to run several tasks in parallel and just be pinged for
what needs him. When NOT: single-task interactive work (use `/leadv2` normally
— supervise is a dispatcher+overseer, not a worker itself).

## Target scenario

"I open `/leadv2 supervise`, it reconciles what's already running, I pick a
few more tasks from a list — it runs them itself and just watches, forwards
me messages." The main lead becomes a dispatcher + overseer of N task lanes.
Only things that need the founder reach chat.

## Flow (5 steps, in order)

1. **Reconcile + adopt existing work.** Call `scripts/leadv2-supervise.sh
   --json` (a full, non-delta call). This single call already does everything
   needed: renders the live table AND runs the D-d tmux reconciliation —
   triple-proof adoption of orphan tmux windows (window name matches a known
   task id AND a live `claude` PID descends from the pane), corroborated
   (twice-polled) death detection with tombstone-before-prune, and the F2
   truth-probe hook. Read the JSON's `orphans` / `adopted` / `would_adopt` /
   `would_prune` / `dead` keys — an eligible adoption or prune that was
   suppressed by `observe_only` (env override, or the automatic first-2-cycle
   D-e rollout window) is still ALWAYS present in `would_adopt`/`would_prune`,
   never silently dropped. Report those to the founder as "seen but not
   applied yet", not as absent.
2. **Pick <=5.** Call `scripts/leadv2-supervise-pick.sh [N<=10]` — a
   read-only ranked picker over `docs/tasks.yaml` top candidates plus any
   cached truth-probe breach (a RED breach's linked work item is pre-ranked
   first with `recommend:true`). It NEVER dispatches anything itself. Present
   the ranked list via `AskUserQuestion` (multiSelect); founder picks 0-5.
   Zero selection is valid — it means "just watch what's already adopted".
3. **Run picked lanes IN-SESSION.** For each selected task, the lead spawns a
   `Workflow` or a background `Agent` lane, each in its OWN worktree (never
   touching a live child's worktree — off_limits) — this is the default
   execution architecture per D-f variant A, not N autonomous `claude -p`
   leads. Register one row per lane in `active.yaml` (via
   `leadv2-active-registry.sh`) with `protocol_version: 2`,
   `backend: workflow`, and an (initially empty) `provider_receipts: []`
   populated as the lane's Codex/GLM calls complete with real job/run ids.
4. **Attach the loop.** `scripts/leadv2-supervise-loop.sh --ensure` via
   `Monitor` — idempotent PID+birth-sentinel attach, never a duplicate loop on
   re-entry/PostCompact. The LOOP renders output, not the lead: URGENT events
   (new question / dead / close / truth-breach) surface within ~5s; a full
   pulse of exactly N <=180-byte lines (one per non-dead lane) every 300s.
5. **Founder contract.**
   - Questions surface INSTANTLY as `AskUserQuestion` — never batched into
     the next pulse.
   - All other status is relayed VERBATIM from loop lines. **Zero narration**
     between polls — no "запустил", "читаю", "синтезирую".
   - A corroborated-dead lane is **NEVER auto-restarted.** It is tombstoned
     (already done by step 1's reconciliation) and escalated to the founder
     via `scripts/leadv2-ask.sh` with exactly three options: `inspect` (logs
     first), `restart`, `abandon`. Only an explicit `restart` answer may
     dispatch again.

## Legacy fanout — compatibility only, not the default

`/leadv2 fanout [--n N] [--backend tmux|headless]` remains a bare
dispatch-only path: it launches N terminal/headless children via
`scripts/leadv2-fanout.sh` and exits — no supervision loop attached, no
picker, no reconciliation. It is **not** the default `/leadv2 supervise`
dispatch mechanism (D-f resolved: fat interactive supervisor + in-session
lanes is default). Existing tmux/headless children spawned this way are
still observed, triple-proof-adopted, and pulse-supervised by the same
`leadv2-supervise.sh` / `leadv2-supervise-loop.sh` used for Workflow lanes —
D-e's additive rollout guarantees the 5 pre-existing live children are never
killed, renamed, or rewritten by the V2 reconciliation.

## Async question channel — canonical scripts, two stores by design

Both scripts below are REAL, canonical, and live in this plugin's
`scripts/` — not aspirational or persona-engine-only prototypes:

- **Cross-worktree (canonical for fanned-out/adopted lanes):**
  `scripts/leadv2-ask.sh <task-id> "<question>" --option "label|desc" [...]
  [--timeout <sec=1800>]` — writes `<control-plane>/questions/<qid>.yaml`
  (resolved via `leadv2-state-path.sh`, OUTSIDE any worktree — reachable from
  every session of this repo, which is exactly what a fanned-out session in
  its own `git worktree add` checkout needs) and blocks until answered.
  Answered via `scripts/leadv2-answer.sh <q-id> <option-label>` — wired to
  `/leadv2 reply <q-id> <option>` and `/leadv2 questions`.
- **Same-session embedded subagents (legacy, still valid for THIS use case):**
  `leadv2_ask_async` / `leadv2_wait_answer` (in `leadv2-helpers.sh`) write
  `docs/handoff/<task_id>/questions-async/<qid>-pending.yaml` — worktree-local,
  fine for an embedded subagent in the SAME session/worktree as the lead.
  Answered via `scripts/leadv2-reply.sh --task-id <id> <qid> <option>`.

`leadv2-supervise.sh` dual-reads both stores (it never writes to either
except via the same reply calls a founder-driven `/leadv2 reply` would make)
so the supervising lead sees pending questions regardless of which store a
given lane's protocol version uses. Do not add a third store.

## Snapshot / loop / pick script contracts

- `scripts/leadv2-supervise.sh [--json] [--since <ISO>]` — the core
  reconciliation snapshot.
  - No `--since`: full call — compact table + `orphans`/`adopted`/
    `would_adopt`/`would_prune`/`dead` (D-d) + `truth_probe`/`truth_breaches`
    (F2, only computed on full calls) + `requires_founder`/`stuck`/
    `closed_since_last`.
  - `--since <ISO>`: delta mode — only events not already reported in the
    previous snapshot; silence if nothing changed. Death corroboration still
    advances on delta calls (a candidate needs two CONSECUTIVE calls, delta
    or full, to be corroborated) but the tmux/truth-probe reconciliation
    itself only runs on full calls.
  - Read-only w.r.t. everything except D-d's own adopt/tombstone/prune writes
    (gated by `observe_only`); `set -euo pipefail`; a broken `active.yaml`
    prints a `WARN:` and continues rather than crashing the loop.
- `scripts/leadv2-supervise-loop.sh [--ensure]` — Monitor-attachable
  two-cadence loop (5s event poll / 300s pulse). The loop owns the sleep —
  never the LLM. `--ensure` attaches to a live loop instead of duplicating.
- `scripts/leadv2-supervise-pick.sh [N<=10]` — read-only ranked picker over
  `docs/tasks.yaml` + cached truth breaches. Never dispatches.

## Entry points

- `/leadv2 supervise` — full D-f=A flow above (reconcile+adopt -> pick <=5 ->
  run in-session lanes -> attach loop).
- `/leadv2 fanout [--n N] [--backend tmux|headless]` — legacy dispatch-only
  compatibility path, no supervision loop attached (see above).

## Verification

- `plugins/leadv2/scripts/tests/test-supervise-failclosed.sh` — B1
  fail-closed root/registry/state-write unit tests.
- `plugins/leadv2/tests/test-supervise-v2.sh` (SUPERVISE-V2-01 item 6) —
  loop cadence/ceiling, pick-script ranking schema, tmux triple-proof
  adoption matrix, tombstone-before-prune, observe_only visibility
  (would_adopt/would_prune never drop an eligible candidate), truth-probe
  timeout->unavailable.

Run both before relying on the watch loop in a real session.
