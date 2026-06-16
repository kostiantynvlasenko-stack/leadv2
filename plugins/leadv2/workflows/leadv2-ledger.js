// leadv2-ledger.js — append-only event ledger (C3 / F2)
// Exports: emit(event, payload) — called from workflow phase transitions.
// Ledger file: docs/leadv2/ledger.jsonl (per-worktree; DO NOT share across worktrees).
// Each line is a complete JSON object — POSIX append is atomic for lines < PIPE_BUF.
// Crash recovery: read ledger to find last committed phase for a task_id.
//
// Usage in workflows:
//   import { emit } from '~/.claude/workflows/leadv2-ledger.js'  // conceptual; workflows call via bash helper
//   OR inline: await bash(`python3 .claude/scripts/lv2-ledger-emit.py '${JSON.stringify(event)}'`)
//
// This file is the Workflow interface — it does NOT run standalone as a workflow.
// It is sourced/imported by other workflows or called via the bash helper below.

export const meta = {
  name: 'leadv2-ledger',
  description: 'Append-only event ledger for leadv2 phase transitions and task lifecycle. Enables crash-recovery via last-committed-phase detection. DO NOT invoke as a standalone workflow.',
  whenToUse: 'Internal — called by emit() helper in other workflows. Never invoke directly.',
  phases: [],  // no phases — this is a library module
}

// ── Event schema ──────────────────────────────────────────────────────────────
// Every event: { ts, event, task_id, phase, payload }
// event values: 'phase_enter' | 'phase_exit' | 'agent_spawn' | 'decision_made' | 'skill_promoted' | 'task_close'
//
// Ledger path: docs/leadv2/ledger.jsonl (relative to project root)
// Per-worktree: each git worktree writes its own ledger.jsonl (no cross-worktree sharing).
// The file grows unboundedly within a worktree session; GC is not needed (it's a log, not a store).

// ── Python helper (embedded, called via bash()) ───────────────────────────────
// Workflows emit events by running:
//   await bash(`python3 -c "
// import json, sys, os, datetime
// ev = json.loads(sys.argv[1])
// ev.setdefault('ts', datetime.datetime.utcnow().isoformat() + 'Z')
// line = json.dumps(ev, separators=(',',':')) + '\n'
// path = os.path.join(os.environ.get('LEADV2_PROJECT_ROOT', '.'), 'docs/leadv2/ledger.jsonl')
// os.makedirs(os.path.dirname(path), exist_ok=True)
// with open(path, 'a') as f: f.write(line)
// " '${JSON.stringify({event: 'phase_enter', task_id: TASK_ID, phase: 'Gather'})}'`)
//
// Shorthand: use the bash helper script lv2-ledger-emit.sh (created below alongside this file).

// ── Crash-recovery reader ─────────────────────────────────────────────────────
// To find last committed phase for a task_id, run:
//   python3 .claude/scripts/lv2-ledger-last-phase.py <task_id> [ledger_path]
// Returns: last 'phase_exit' event phase name, or "NONE" if no exit found.
// Lead uses this at session-resume to decide whether to re-run a phase or skip.

// ── emit() conceptual signature ───────────────────────────────────────────────
// emit(event: string, payload: object) → void (fire-and-forget, never throws)
// event: one of the values above
// payload: arbitrary object merged into the ledger entry alongside ts/task_id/phase
//
// Workflows that want to emit MUST pass task_id and phase in payload or via context.
// The helper script reads TASK_ID from env (LEADV2_TASK_ID) as fallback.

// lean: JS export/import not available in Workflow runtime — emit is bash-only for now; upgrade to native workflow helper when runtime supports module imports
