# COMPACT-FORCED-ON-HUMAN-01 — result

**Status: FIXED + verified live.** The Stop hook no longer forges `/compact` in a session
where a human has typed, while genuine daemon children (0 founder turns) still force-compact.

## Root cause (both halves, lead-verified)

1. **Plugin hook** — `plugins/leadv2/hooks/leadv2-compact-trigger.sh` has a daemon-mode branch
   (added by the uncommitted `WAVE-RELIABILITY-01` lane) that emits
   `{"decision":"block","reason":"/compact"}`. `decision:block` + `reason:"/compact"` is
   indistinguishable from the founder typing `/compact` — the lead obeys it as a real user turn.
   The branch guarded on `LEADV2_DAEMON`, `LEVEL`, and `STOP_ACTIVE` but **never consulted
   `FOUNDER_TURNS`**, so it fired in interactive sessions even when the counter read 73.
2. **Repo env** — `persona-engine/.claude/settings.json:46` hard-set `LEADV2_DAEMON: "1"`
   for every session, so an interactive founder session was indistinguishable from an
   unattended `/goal` child by env alone.

## Fix

### 1. Plugin — human-presence gate + kill-switch (the robust half)

`FOUNDER_TURNS` is computed earlier in the hook (count of user-typed turns) and is always a
non-negative integer (`python3 … || echo 0`). The daemon branch now requires **no human present**:

```bash
if [[ "${LEADV2_DAEMON:-0}" == "1" \
   && "${LEADV2_NO_FORCE_COMPACT:-0}" != "1" \
   && "$FOUNDER_TURNS" -eq 0 \
   && "$LEVEL" != "long_chat" \
   && "$STOP_ACTIVE" != "true" ]]; then
   … printf '{"decision":"block","reason":"/compact"}' …
fi
```

- `FOUNDER_TURNS > 0` ⇒ the `if` is false ⇒ **falls through** to the existing interactive
  pending-warn path (tells the lead to *mention* compact, never to do it). Daemon behaviour for
  genuine children (0 founder turns) is untouched.
- `LEADV2_NO_FORCE_COMPACT=1` ⇒ hard kill-switch, never force regardless of anything else.
- ERR/EXIT traps unchanged ⇒ still fail-open (exit 0) on every error path.

### 2. Repo — removed the repo-wide `LEADV2_DAEMON` lie

Deleted `"LEADV2_DAEMON": "1"` from `persona-engine/.claude/settings.json`. Safe because daemon
children **export it themselves** — proven, not guessed:

```
plugins/leadv2/scripts/leadv2-session-spawner.sh:107:  export LEADV2_DAEMON=1
plugins/leadv2/scripts/leadv2-daemon.sh:714:           export LEADV2_DAEMON=1
plugins/leadv2/scripts/leadv2-fanout.sh:677/683/902:   export LEADV2_DAEMON=1 …
plugins/leadv2/scripts/leadv2-session-runner.sh:68:    export LEADV2_DAEMON="${LEADV2_DAEMON:-1}"
```

Children get the flag from the spawner, not by inheriting settings.json, so removing the
repo-wide setting does not break daemon mode. The other 3 repos (m3-market, respiro-ios,
campaign-platform) do **not** set it in their settings.json — only persona-engine did.
`LEADV2_DAEMON` is also **not** in the global `~/.claude/settings.json` (only
`LEADV2_LEAD_GUARD`/`LEADV2_WIKI_INJECT`/`LEADV2_ROUTE_BANDIT`/`LEADV2_SCORECARD_ON_CLOSE` are).

`python3 -m json.tool settings.json` ⇒ VALID JSON after the edit.

## Acceptance — real output (harness: `/tmp/compact_accept.sh`, `env -i` so the live
session's `LEADV2_DAEMON=1` never leaks in)

```
=== T1: daemon=1 + FOUNDER_TURNS>0 (founder's exact live case) → must NOT block ===
  stdout=[]
PASS  T1 no-block when human present — no decision in stdout
=== T2: daemon=1 + 0 founder turns → daemon child still FORCES /compact ===
  stdout=[{"decision":"block","reason":"/compact"}]
PASS  T2 daemon child unbroken — emits decision:block /compact
=== T3: LEADV2_NO_FORCE_COMPACT=1 + daemon + 0 turns → no block ===
  stdout=[]
PASS  T3 kill-switch disables force — no decision in stdout
=== T4: LEADV2_DAEMON unset + warn level → interactive pending-warn written ===
  stdout=[]
  pending-warn exists=yes
PASS  T4 interactive pending-warn — no block + pending-warn file written
=== T5a: bash -n syntax ===
PASS  T5a bash -n — syntax OK
=== T5b: malformed + empty payload → exit 0 ===
  empty→exit 0  malformed→exit 0
PASS  T5b fail-open exit 0 — both exit 0

SUMMARY: pass=6 fail=0
ALL_ACCEPTANCE_PASS
```

Mapping to the contract: T1=acceptance①, T2=②, T3=③, T4=④, T5a/T5b=⑤.

## Sync / deploy proof (acceptance ⑥)

The full `leadv2-plugin-sync.sh` was **not** run, deliberately: it syncs the whole canonical
working tree and would also deploy the unrelated, uncommitted `CODEX-WAIT-AND-TIER-01`
`codex-task.sh` dead-lane change as a side-effect (see "Dead-lane files" below) — out of scope
for this task. Instead the hook was deployed **surgically** to its single executing target and
proven identical:

```
canonical: ~/Projects/leadv2/plugins/leadv2/hooks/leadv2-compact-trigger.sh
cache:     ~/.claude/plugins/cache/leadv2-local/leadv2/0.1.0/hooks/leadv2-compact-trigger.sh
$ cmp canonical cache && echo BYTE-IDENTICAL ✓
BYTE-IDENTICAL ✓
perms: -rwxr-xr-x (exec bit preserved)
```

The cache copy was then re-tested through the same harness ⇒ `ALL_ACCEPTANCE_PASS` (6/6).
The hook exists only in canonical + the cache (executing) + two `~/.claude/leadv2-quarantine/`
backups from a sync earlier today (left untouched). Shared tree carries scripts+contracts only,
no hooks; no repo vendors this hook. To land `codex-task.sh` later, run
`bash ~/.claude/scripts/leadv2-plugin-sync.sh` and commit the resulting drift.

## Dead-lane files (inspected, NOT clobbered, NOT committed — separate lanes)

Uncommitted in `~/Projects/leadv2` at start, preserved as-is:

- `plugins/leadv2/hooks/leadv2-compact-trigger.sh` — **this file.** Its pre-existing uncommitted
  edits (`LEAD-ANCHOR-01` PYTHONWARNINGS, `WAVE-RELIABILITY-01` daemon branch + STOP_ACTIVE, the
  2026-07-10 capped-block token calibration) are the substrate this fix builds on; they are
  committed together with the gate (the daemon branch cannot land without the gate).
- `plugins/leadv2/scripts/codex-task.sh` (+81) — `CODEX-WAIT-AND-TIER-01`: `--wait` forces
  foreground blocking for task/review; `--tier top` now requires `--reason "<why>"` (refuses
  otherwise). Complete and documented, but a separate lane — left uncommitted, NOT deployed.
- `plugins/leadv2/skills/leadv2-review/SKILL.md` (+11) — already matches the cache (a prior
  sync deployed it); left uncommitted.
- `plugins/leadv2/agents/SCHEMA.md` (deleted) + untracked `agents/README.md` — dead-lane doc
  refactor; left as-is, not investigated deeply.

## Commits

- `leadv2` repo: hook fix (canonical) + this deliverable doc.
- `persona-engine` repo: `.claude/settings.json` `LEADV2_DAEMON` removal only.

Note: the task brief annotated the deliverable "(persona-engine)", but persona-engine
`.gitignore:80` deliberately ignores `docs/handoff/` ("working artifacts, not project docs").
leadv2 tracks handoff docs (sibling to `docs/handoff/QUOTA-GATE-01/glm-result.md`, same
convention), so the doc lives here.

DELIVERABLE_COMPLETE
