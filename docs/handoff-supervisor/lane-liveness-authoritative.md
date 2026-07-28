# Lane liveness is authoritative

`scripts/leadv2-lane-liveness.sh` is the single liveness reader used by the
supervisor and by Codex planner relaunch protection.

Precedence is fixed:

1. Provider status: Codex uses `codex-task.sh status` (including its own
   `--all --json` job registry); Claude/GLM lanes use their provider receipts.
2. Durable evidence: completion flags, deliverables, and commits.
3. Process and mtime observations, always labelled `heuristic`.

`codex-guard.sh` is a rescue sidecar, not a liveness provider. Its absence
cannot produce a `dead` verdict. Provider `running`, `done`, `cancelled`, and
`failed` are reported distinctly; unknown remains unknown.

Supervise renders Codex jobs as `codex:<job-id>` lanes with authoritative Phase.
Before a Codex planner dispatch, an existing task job still `running` is refused
to prevent a duplicate edit lane.
