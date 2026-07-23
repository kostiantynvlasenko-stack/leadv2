---
name: leadv2-supervise
description: "[internal] Provider-aware full-cycle supervisor. The main /leadv2 lead reconciles work, lets the founder pick <=5 tasks, dispatches each as an independent Claude or Codex /leadv2 session that must complete Phase 0..8, then attaches leadv2-supervise-loop.sh via Monitor."
allowed-tools:
  - Bash
  - Read
  - AskUserQuestion
  - Monitor
---

# Lead v2 Supervise Mode (D-f = variant A)

## When: founder wants to run several tasks in parallel and just be pinged for
what needs him. When NOT: single-task interactive work (use `/leadv2` normally
— supervise is a dispatcher+overseer, not a worker itself).

## Target scenario

"I open `/leadv2 supervise`, it reconciles what's already running, I pick a
few more tasks from a list — it dispatches them and just watches, forwarding
me messages." This is a distinct supervisor session, not a single-task lead.
It owns no task, phase, worktree, task lock, or child prompt history. Each
child is an independent full lead session; only the shared control plane
(registry, quota, questions, completion receipts) crosses that boundary.
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
3. **Dispatch picked tasks as complete child sessions.** Call
   `scripts/leadv2-fanout.sh --tasks <comma-separated-ids> --provider auto
   --headless`. Each selected task gets an independent provider session and
   its own Phase-0 worktree claim. `leadv2-session-route.sh` deterministically
   chooses the provider/model: routine Light/Standard work may use Codex when
   its CLI, leadv2 skill, and quota headroom are available; Heavy/Strategic or
   high-risk tags stay on Claude/Opus. The provider-neutral runner passes
   `/leadv2 <task-id>` (or the Codex skill-equivalent) and resumes the SAME
   Claude session/Codex thread until the common
   canonical `docs/handoff/<task-id>/phase8-passed.flag` or its validated
   shared control-plane completion receipt exists. A clean model
   turn without that sentinel is INCOMPLETE, never complete. Child-internal
   Workflow/Agent calls remain valid phase helpers, but they are not
   top-level supervised task lanes. Every launch and resume writes auditable
   `provider_receipts` to `active.yaml`.
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

## Direct fanout — full-cycle dispatch without the supervisor UI

`/leadv2 fanout [--n N] [--provider auto|claude|codex]
[--backend tmux|headless]` uses the same provider router and full Phase 0..8
runner, but exits after dispatch: no picker, reconciliation, or watch loop.
`/leadv2 supervise` is fanout plus the interactive selection and monitoring
control plane. Existing tmux/headless children remain observed and adopted by
the same `leadv2-supervise.sh` / `leadv2-supervise-loop.sh` machinery.

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
- **Same-session embedded subagents (only for child-internal phase helpers):**
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

- `/leadv2 supervise` — reconcile+adopt -> pick <=5 -> provider-aware full
  `/leadv2` child sessions -> attach loop.
- `/leadv2 fanout [--n N] [--provider auto|claude|codex]
  [--backend tmux|headless]` — the same full-cycle dispatch, without the
  interactive supervisor loop.

## Verification

For detailed test coverage and pre-deployment validation, see [VERIFICATION.md](./VERIFICATION.md).
Run the referenced test suites before relying on the watch loop in a real session.
