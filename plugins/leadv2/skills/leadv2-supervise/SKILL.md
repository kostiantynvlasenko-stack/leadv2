---
name: leadv2-supervise
description: "[internal] Turns the main /leadv2 lead into a supervisor over N fanned-out child sessions: founder picks tasks, lead launches leadv2-fanout.sh, then only watches leadv2-supervise.sh --json --since deltas and forwards to chat the things that need the founder (open questions, stalls, closes)."
allowed-tools:
  - Bash
  - Read
  - AskUserQuestion
  - Monitor
---

# Lead v2 Supervise Mode

## When: founder wants to run several tasks in parallel and just be pinged for
what needs him. When NOT: single-task interactive work (use /leadv2 normally —
supervise is a dispatcher, not a worker).

## Target scenario

"I open /leadv2, say what I want done, pick tasks from a list — it opens all
the windows itself and just watches, forwards me messages." The main lead
stops executing a single task and becomes a dispatcher + overseer of N child
sessions. Only things that need the founder reach chat.

## Flow

1. **Pick tasks** — `AskUserQuestion` (multiSelect) over the top-N open items
   in `docs/tasks.yaml`. Founder selects which tasks to fan out.
2. **Launch** — `scripts/leadv2-fanout.sh --tasks <ID1,ID2,...>`. This is the
   ONLY way sessions get created; supervise never spawns sessions itself.
   Contract: selects tasks, opens N terminal windows/headless processes, each
   in its own worktree, registers each session in `docs/leadv2/active.yaml`
   via `~/.claude/leadv2-shared/scripts/leadv2-active-registry.sh`.
3. **Watch** — set ONE `Monitor` on a loop calling
   `scripts/leadv2-supervise.sh --json --since <last-poll-ts>` every 60s.
   Each poll either prints nothing (silence — no news) or a JSON delta with
   new events. Every event in the delta becomes exactly one line in chat:
   - `TASK-X ждёт ответа: <question>` — from `requires_founder[]`
   - `TASK-Y застряла в <phase> N мин` — from `stuck[]`
   - `TASK-Z закрыта` — from `closed_since_last[]`

   **Never** print "запустил", "читаю", "синтезирую" or any narration between
   polls — those never reach chat. Supervise mode is silent by default; only
   forwarded events are chat-visible.
4. **Answer routing** — founder answers a forwarded question in plain words
   (e.g. "вариант b"). Supervisor resolves the option letter and calls
   `~/.claude/leadv2-shared/scripts/leadv2-reply.sh --task-id <TASK-ID> <qid> <option>`
   itself — founder never has to know the qid/option-letter mechanics.
5. **Supervisor never edits child worktrees.** No code, no `Edit`/`Write`
   inside a child's worktree — that's the child session's job. Supervisor
   only reads `docs/leadv2/active.yaml`, `docs/handoff/<id>/questions-async/`,
   and `docs/handoff/<id>/phase8-passed.flag` (all read-only, all via
   `leadv2-supervise.sh`).

## Async question channel — reuse, do not reinvent

The question/answer IPC already exists and is production code — supervise
mode builds ON it, it does not add a second channel:

- Writer (child session): `leadv2_ask_async` in
  `~/.claude/leadv2-shared/scripts/leadv2-helpers.sh` — writes
  `docs/handoff/<task_id>/questions-async/<qid>-pending.yaml`
  (`qid, phase, summary_for_lead, question, options[], auto_decide_after,
  wait_indefinitely, priority, created_at`).
- Reader (child session, blocking): `leadv2_wait_answer` in the same file —
  polls for `<qid>-answered.yaml`, optionally auto-decides after a timeout
  for non-Heavy/Strategic tasks.
- Answerer (founder-facing CLI): `/leadv2 reply <qid> <option>` →
  `~/.claude/leadv2-shared/scripts/leadv2-reply.sh --task-id <id> <qid> <option>`
  — atomically writes `<qid>-answered.yaml` via an `ln` sentinel.

`leadv2-supervise.sh` only *reads* `<qid>-pending.yaml` files that have no
sibling `<qid>-answered.yaml` yet — it never writes to this directory itself
except via the same `leadv2-reply.sh` call a founder-driven `/leadv2 reply`
would make.

## Entry points

- `/leadv2 supervise` — full flow above (pick tasks → fanout → watch loop).
- `/leadv2 fanout` — alias for a bare `leadv2-fanout.sh` launch with NO
  supervision loop (useful when the founder wants to babysit the windows
  himself).

## Snapshot script contract

`scripts/leadv2-supervise.sh [--json] [--since <ISO>]`

- No `--since`: full snapshot — compact table (task_id, phase, minutes in
  phase, status, waiting?) capped at 20 rows, plus `TREBUET TEBYA` /
  `ZASTRYALO` / `ZAKRYTO s proshlogo snimka` blocks.
- `--since <ISO>`: delta mode — prints ONLY events not already reported in
  the previous snapshot (`docs/leadv2/.supervise-last.json`); silence if
  nothing changed. This is what the Monitor loop should use.
- `--json`: same content, machine-readable, for the Monitor loop to parse.
- Stuck = time-in-phase > 25 min (freshness proxy: `last_pulse_at`, falling
  back to `started_at` — active.yaml has no per-phase-entry timestamp), OR
  the session's `pid` is dead, OR the registry already marked it `stale`.
- Closed = `docs/handoff/<task_id>/phase8-passed.flag` newly appeared since
  the last snapshot.
- Read-only, no network, `set -euo pipefail`. A broken `active.yaml` prints a
  `WARN:` line and continues with what it could parse — it never fails
  silently and never crashes the watch loop.

## Verification

`tests/leadv2/test-supervise.sh` — sandboxed fixture tests (3-session table,
open-question surfacing, stuck-session surfacing, `--since` silence on no
change, empty/malformed `active.yaml` handling). Run before relying on the
watch loop: `bash tests/leadv2/test-supervise.sh`.
