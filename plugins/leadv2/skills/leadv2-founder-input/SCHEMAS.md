# Decision-file schema (leadv2-founder-input)

Referenced from Step 1 — Compose the decision file, in `SKILL.md`.

```yaml
id: <YYYY-MM-DDThh-mm-ssZ>-<task-id>
created_at: <iso>
task_id: <task-id>
tier: <A|B|C>
phase: <current-phase>
trigger: circuit-break | recovery-failed | verify-timeout | off-limits-warning | coverage-low | other
status: pending
question: "<clear plain-English question for the founder; include what failed, how many times, last error>"
options:
  - id: A
    label: "<action label>"
    action: retry_task | skip_task | pause_indefinite | rollback_and_investigate
    fix_quality: band-aid | reasonable | durable
  - id: B
    label: "<action label>"
    action: ...
    fix_quality: band-aid | reasonable | durable
  - id: C
    label: "Pause daemon, investigate manually, resume when ready"
    action: pause_indefinite
    fix_quality: reasonable
  - id: D
    label: "Roll back last commit and open RECOVERY- task"
    action: rollback_and_investigate
    fix_quality: reasonable
recommended: <id of fix_quality:durable option; if none → highest reasonable; see rules below>
reasoning: "<why recommended is best; prefix with WARN: no durable option available if none exists>"
context:
  task_class: <Light|Standard|Heavy|Strategic>
  files_touched: [<list of files changed in this task>]
  last_fail_reason: "<one-line summary>"
  last_n_history: []  # last 3 history entries from docs/LEAD_V2_STATE.md
answer:
  selected: null
  selected_at: null
  notes: null
escalation:
  re_ping_at: <iso + 2h>
  re_ping_count: 0
  auto_apply_at: null  # set for Tier B only: now+10min ISO
```

**`fix_quality` semantics:**
- `band-aid` — patches symptom, does not fix root cause (e.g. retry same failing approach)
- `reasonable` — safe, defers root-cause work (e.g. rollback + file tracker item)
- `durable` — addresses root cause permanently (e.g. redesign via architect)

**`recommended` field is REQUIRED.** Always select the `fix_quality: durable` option if one exists. If no durable option → select `fix_quality: reasonable` and prepend `WARN: no durable option available, escalating option set to founder` to `reasoning`. Missing `fix_quality` on any option → treat as `band-aid` (conservative).
