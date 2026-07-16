# SUPERVISE-V2-01 — Fix round 2 report

Source: `docs/handoff/SUPERVISE-V2-01/codex-review-2.md` (5 High findings).
Repo: `~/Projects/leadv2`. Base HEAD at task start: d59377d (task brief said
4900c0a; d59377d is one commit ahead, no conflict).

## R2-1 — GUARD-vs-D-f=A CONTRADICTION (finding 1, architecture-critical)

`.supervise-active` gains `mode: interactive-lanes|legacy-relay`. Writer
(`leadv2-supervise.sh`) stamps `interactive-lanes` by default (the new
skill's D-f=A flow, which REQUIRES the supervising session to spawn its own
in-session Workflow/Agent lanes) unless `LEADV2_SUPERVISE_MODE=legacy-relay`
is exported first. Guard (`leadv2-supervise-fanout-guard.sh`) now only
denies the owning session's Agent spawns when `mode==legacy-relay` (or mode
absent — fail-closed default, same H2 philosophy as the unknown-subagent-type
deny). Original guard purpose (blocking accidental in-session workers when
children run in external tmux fanout) is preserved intact under
`legacy-relay`; D-f=A's required lanes are unblocked under the new default.
SKILL.md step 3 updated to document the mode contract.

Commit: `42e3727 fix(supervise-v2): R2-1 sentinel mode split resolves D-f=A guard contradiction`
Files: `plugins/leadv2/scripts/leadv2-supervise.sh`,
`plugins/leadv2/hooks/leadv2-supervise-fanout-guard.sh`,
`plugins/leadv2/skills/leadv2-supervise/SKILL.md`,
`plugins/leadv2/tests/test-supervise-fanout-guard.sh` (+2 tests: j, k).

Evidence: `bash plugins/leadv2/tests/test-supervise-fanout-guard.sh` -> 11/11
pass (9 pre-existing + 2 new mode tests).

## R2-2 — `--ensure` atomicity (finding 2)

`leadv2-supervise-loop.sh`: the liveness check (is a live loop already
attached?) and the ownership write (claim the sentinel as this process) now
happen inside ONE critical section under a single `flock` on
`${SENTINEL}.lock` (python3 `fcntl`, matching the project's portable-locking
convention — no bash `flock` binary on macOS/BSD). Closes the prior
unlocked-check-then-create race where two concurrent `--ensure` calls could
both see a stale sentinel and both claim ownership. The EXIT trap no longer
unconditionally `rm -f`s the sentinel; it removes it ONLY if it still
contains this process's own pid+birth (never clobbers a different owner's
live sentinel).

Commit: `31ac321 fix(supervise-v2): R2-2 atomic --ensure attach + owner-scoped EXIT trap`
File: `plugins/leadv2/scripts/leadv2-supervise-loop.sh`.

Evidence: manual functional probe (pre-seeded live sentinel with matching
pid+birth via `ps -o lstart=`) — `--ensure` printed
`already running pid=<N> log=<path>` and the sentinel file bytes were
byte-identical before/after (no clobber). Automated as Test 10 in
`test-supervise-v2.sh` — PASS.

## R2-3 — tmux death OR→AND (finding 3, D-d violation)

`leadv2-supervise.sh`: for `backend==tmux`, death evidence now requires BOTH
`window_missing` AND `pid_issue` (pid dead or birth mismatch) together —
previously ANY single signal alone advanced a dead candidate, so a tmux
window that transiently failed to list (tmux hiccup/rename race) while the
underlying claude PID was provably alive got pruned after two polls, a false
positive that killed a live child (D-d + live-child off_limits violation).
Non-tmux backends (headless/workflow — no window concept) are unaffected;
PID evidence alone remains sufficient there, unchanged from before.

Commit: `3d7a110 fix(supervise-v2): R2-3 tmux death corroboration requires BOTH window+PID (fix the OR)`
File: `plugins/leadv2/scripts/leadv2-supervise.sh`.

Evidence: Test 7 in `test-supervise-v2.sh` (3 sub-assertions):
- 7a: window-missing alone (pid alive, correct birth) across 2 polls -> NOT
  dead, row kept in active.yaml. PASS.
- 7b: pid-dead alone (real tmux window present, matching name) across 2
  polls -> NOT dead, row kept. PASS.
- 7c (control): both signals together -> corroborated dead, tombstoned+pruned
  (confirms the AND-fix doesn't regress real detection). PASS.

## R2-4 — tombstone-before-prune ordering (finding 4)

`leadv2-supervise.sh`: the active.yaml mutation previously wrote the
dead-rows-already-removed registry BEFORE the tombstone file was even
opened. Reordered: tombstone write happens FIRST inside the same locked
critical section; only `task_id`s whose tombstone write durably succeeded
(`tombstoned_ids`) are ever removed from active.yaml. A tombstone write
failure keeps EVERY intended-prune row live — both in the active.yaml file
and in the in-memory `current`/table view (not just the file) — and appends
a loud `"tombstone write failed ... row(s) KEPT"` warning to the JSON
`warnings[]` array. Founder escalation via `leadv2-ask.sh` is scoped to only
the actually-tombstoned ids.

Commit: `c09c845 fix(supervise-v2): R2-4 tombstone-before-prune ordering, fail-safe keep-row`
File: `plugins/leadv2/scripts/leadv2-supervise.sh`.

Evidence: Test 8 in `test-supervise-v2.sh` — pre-creates `tombstones.yaml`
as a directory (forces a real `IsADirectoryError`/OSError on
`os.replace(tmp, tombstones_file)`, isolated to the tombstone code path
only) -> row stays present in active.yaml AND a `warnings[]` entry containing
"tombstone write failed" is present in the JSON output. PASS. Test 4
(pre-existing, tombstone-before-prune happy path + observe_only visibility)
re-verified green.

## R2-5 — DEAD event dedup (finding 5, pulse ceiling violation)

`leadv2-supervise.sh`: `dead_now` entries now generate an event_key
(`dead:<task_id>:<reasons>`) folded into the same `current_events`/
`new_events` dedup machinery already used for waiting/stuck/closed. The
JSON `dead` key now reports `out_dead` (delta-mode filtered against
`new_events`) instead of the raw `dead_now` list on every call. Previously
`leadv2-supervise-loop.sh`'s `_render_events` appended a duplicate `DEAD`
urgent line to the log on every 5s poll while a row remained
corroborated-dead-but-not-yet-pruned (observe_only, or an R2-4 tombstone
failure), violating "unchanged poll -> zero bytes appended".

Commit: `14f9e37 fix(supervise-v2): R2-5 DEAD urgent event deduped through new_events`
File: `plugins/leadv2/scripts/leadv2-supervise.sh`.

Evidence: Test 9 in `test-supervise-v2.sh` — two consecutive
`--json --since <iso>` delta polls on an unchanged corroborated-dead row
(observe_only=1, so the row survives to be re-polled identically): `dead`
non-empty on poll 1 (event newly reported), empty on poll 2 (same event_key
already in `prev_reported`, correctly suppressed). PASS.

## Test commit

`300bdde test(supervise-v2): R2-2/3/4/5 regression coverage (6 new assertions)`
— Tests 7, 8, 9, 10 added to `plugins/leadv2/scripts/tests/test-supervise-v2.sh`
and wired into the run-all list. `test-supervise-fanout-guard.sh`'s 2 new
mode tests (j, k) were committed together with R2-1 since they belong to
that same fix.

## Full-suite evidence (final run, post all 6 commits)

    $ bash plugins/leadv2/scripts/tests/test-supervise-v2.sh        -> PASS=17 FAIL=0
    $ bash plugins/leadv2/scripts/tests/test-supervise-failclosed.sh -> PASS=6  FAIL=0
    $ bash plugins/leadv2/tests/test-supervise-fanout-guard.sh       -> 11 passed, 0 failed

34/34 assertions green across all three suites. route-bandit suite is not
among these three files and was not touched by this round's changes (per
coordinator's note, exempted as known-flaky and out of scope here).

## Commits (chronological)

1. `42e3727` fix(supervise-v2): R2-1 sentinel mode split resolves D-f=A guard contradiction
2. `3d7a110` fix(supervise-v2): R2-3 tmux death corroboration requires BOTH window+PID (fix the OR)
3. `c09c845` fix(supervise-v2): R2-4 tombstone-before-prune ordering, fail-safe keep-row
4. `14f9e37` fix(supervise-v2): R2-5 DEAD urgent event deduped through new_events
5. `31ac321` fix(supervise-v2): R2-2 atomic --ensure attach + owner-scoped EXIT trap
6. `300bdde` test(supervise-v2): R2-2/3/4/5 regression coverage (6 new assertions)

(Committed in dependency-safe hunk order — R2-3/4/5 share
`leadv2-supervise.sh` with genuinely interleaved diff hunks; each commit's
`git diff --cached` was verified to contain ONLY that finding's hunks before
committing, confirmed via `@@` line-number inspection.)

## Working-tree hygiene

`git status --short` before and after this round's commits shows the same
unrelated strays (`SCHEMA.md` deletion, `leadv2-compact-trigger.sh`,
`leadv2-review/SKILL.md`, `docs/leadv2/`, `plugins/leadv2/agents/README.md`,
`plugins/leadv2/docs/leadv2/`, `docs/handoff/WORKFLOW-BASH-FIX-01/`) —
none of these were touched, added, or committed by this task.

DELIVERABLE_COMPLETE
