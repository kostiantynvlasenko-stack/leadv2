# Closed Vocabulary — full definitions

Referenced from SKILL.md. All `signature:` fields in `lead-reflect` history entries MUST use values from these lists. No free-text allowed.

### phase
```
intake | plan | build | review | deploy | verify | recovery | close
```
- `intake`: first triage, classification, gate-1 decision
- `plan`: architect/codex plan drafting
- `build`: developer/postgres-pro implementation
- `review`: codex review, critic review
- `deploy`: devops, VPS, migration apply
- `verify`: outcome-watch, acceptance test
- `recovery`: rollback, hotfix, incident-postmortem
- `close`: lead-reflect, log update, state → idle

### task_class
```
Light | Standard | Heavy | Strategic
```
As classified by `lead-classify`. Use the final forced class if overridden.

### failure_class
```
timeout | wrong-file | env-missing | api-4xx | api-5xx | logic-bug | scope-creep | stale-state | none
```
- `timeout`: agent or external call timed out
- `wrong-file`: subagent edited incorrect file/path
- `env-missing`: required env var / credential absent
- `api-4xx`: external API client error (bad request, auth)
- `api-5xx`: external API server error
- `logic-bug`: implementation defect found in review/verify
- `scope-creep`: subagent exceeded mission boundaries
- `stale-state`: local state / cache was stale, caused wrong decision
- `none`: no failure this task

### recovery_decision
```
retry | rollback | hotfix | escalate | none
```
- `retry`: re-ran the same step with minor adjustment
- `rollback`: reverted code or DB change
- `hotfix`: patched live without full cycle
- `escalate`: stopped and pinged founder
- `none`: no recovery needed

### outcome
```
success | rolled_back | paused | failed
```
- `success`: task completed, accepted by verify
- `rolled_back`: changes reverted, system restored
- `paused`: founder asked to pause mid-task
- `failed`: task terminated without deliverable

### involved_agents
Any subset of:
```
architect | developer | frontend-developer | postgres-pro | devops-engineer |
critic | security-auditor | product-owner
```

### change_kind
Structural footprint classification produced by `leadv2-graph-reflect`. Sourced into `signature.change_kind` and `graph_footprint.change_kind`.
```
new-route | new-migration | refactor-internal | bugfix-pure | cross-service | ui-only | config-only | docs-only
```
- `new-route`: a new HTTP/API route was added (Route node in graph)
- `new-migration`: a Supabase migration file was added
- `refactor-internal`: internal restructure, no new external surface
- `bugfix-pure`: defect fix with no new symbols added
- `cross-service`: change introduces cross-service edges (HTTP_CALLS, ASYNC_CALLS)
- `ui-only`: changes confined to `web/` or frontend files
- `config-only`: changes confined to config files (json/yaml/env)
- `docs-only`: changes confined to docs, prompts, or `.claude/` skill files

### fix_quality
Derived from hack-detection findings in Review phase (see `leadv2-hack-detection` skill and `lead-reflect` §6).
```
band-aid | reasonable | durable
```
- `band-aid`: block hack findings present, OR > 3 warn findings
- `reasonable`: 1-3 warn findings, OR no hack data (default)
- `durable`: 0 hack findings AND test-synthesis coverage ≥ 80%
