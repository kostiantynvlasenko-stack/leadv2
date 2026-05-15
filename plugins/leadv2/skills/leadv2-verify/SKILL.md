---
name: leadv2-verify
description: "[internal] Phase 7 — waits for concrete production signal (log/endpoint/supabase/file) via…"
allowed-tools:
  - Read
  - Write
  - Edit
  - Bash
---

# Lead v2 Verify — Live Signal Gate

## When: Phase 7, after Deploy clean. When NOT: deploy circuit-broke.

## Protocol

### 1. Read verification spec from context.yaml

```yaml
verification:
  live_signal: "one-sentence description for history"
  probe:
    type: signal-file | log-grep | http-check | supabase-check
    args: ...
  timeout: 1800   # seconds, default 30 min
```

If `verification.probe` missing → circuit break: "verification spec missing, architect should have defined".

### 2. Choose probe mode

**Decision flowchart:**

```
task-class = Light AND no runtime path touched?
  └─ YES → single-probe OK (any existing type)
  └─ NO  → corroborate required (positive + ≥1 no-regression probe)
```

Heavy tasks (any change to agent cycle, publish path, scheduler, VPS runtime): REQUIRE `--corroborate`.
Light tasks (docs, web UI, schema-only, non-runtime platform code): single-probe acceptable.

### Corroboration mode (default for Heavy tasks)

Write a YAML config file, then invoke:
```bash
verify-probe.sh --timeout 180 --corroborate /tmp/verify-<task-id>.yaml
```

Config format:
```yaml
positive:
  type: log-grep          # signal-file | log-grep | http-check
  host: <user>@<host>
  path: <your-app-log-path>
  pattern: "<expected-success-signal>"
  window_min: 5
no_regression:
  - type: no-5xx-spike    # checks nginx access log for 5xx spike vs prior window
    host: <user>@<host>
    path: /var/log/nginx/access.log
    window_min: 10
    threshold_multiplier: 2.0
  - type: error-log-quiet # checks app log error count recent vs baseline
    host: <user>@<host>
    path: <your-app-log-path>
    window_min: 10
    threshold_multiplier: 2.0
    error_pattern: "(ERROR|CRITICAL|Traceback|Exception)"  # optional, shown is default
```

Behaviour: positive probe runs first (60s timeout). If it fails → PROBE_NEG, stop.
If it passes, each no-regression probe runs in sequence (60s each, 180s total budget).
If ANY no-regression probe fails → PROBE_NEG (regression likely). All must pass → PROBE_OK.

All sub-probes emit structured JSON to stderr: `{"probe":"<type>","result":"pass|fail","reason":"..."}`.

### Launch probe — single-probe (Light tasks or backward compat)

Always pass `--result-file` so `verify-probe-result.yaml` is written atomically
(PO-058 contract: `docs/specs/leadv2-verify-contract.md`).

Compose probe command based on type:

| Type | Command |
|---|---|
| signal-file | `verify-probe.sh --timeout <N> --signal-file <path> --result-file docs/handoff/<id>/verify-probe-result.yaml` |
| log-grep | `verify-probe.sh --timeout <N> --log-grep <vps> <file> "<pattern>" --result-file docs/handoff/<id>/verify-probe-result.yaml` |
| http-check | `verify-probe.sh --timeout <N> --http-check <url> --result-file docs/handoff/<id>/verify-probe-result.yaml` |
| supabase-check | `verify-probe.sh --timeout <N> --supabase-check "<description>" --result-file docs/handoff/<id>/verify-probe-result.yaml` |

For **log-grep on VPS**, wrap via ssh (both VPS in parallel or whichever is relevant):
```bash
ssh <host> "tail -F <your-app-log-path>" | verify-probe.sh --log-grep /dev/stdin "<pattern>" --timeout <N> \
  --result-file "docs/handoff/<id>/verify-probe-result.yaml" &
```

Run in background, capture PID.

### 3. Wait — use Monitor

```
Monitor:
  command: while ! ls /tmp/verify-<task-id>.done 2>/dev/null; do
    <probe writes /tmp/verify-<task-id>.done on exit with status inside>
    sleep 10
  done
  echo "probe finished: $(cat /tmp/verify-<task-id>.done)"
  description: "live verify for <task-id>"
  timeout_ms: <probe-timeout * 1000 + 60000>
```

### 4. Interpret result (PO-058)

Read `outcome:` from `verify-probe-result.yaml` — do NOT rely solely on exit code:

```bash
source .claude/scripts/leadv2-helpers.sh
PROBE_RESULT="docs/handoff/${TASK_ID}/verify-probe-result.yaml"
_validate_probe_result "$PROBE_RESULT" || echo "[verify] WARN: probe result schema invalid"
outcome=$(python3 -c "import yaml; print(yaml.safe_load(open('$PROBE_RESULT'))['outcome'])" 2>/dev/null)
```

| `outcome` field | Exit | Meaning | Action |
|---|---|---|---|
| `probe_ok` | 0 | signal seen | Phase 8 Close |
| `probe_timeout` | 1 | never saw signal | Trigger `leadv2-recovery` with reason: timeout |
| `probe_negative` | 2 | negative signal (error line in log) | Immediate `leadv2-rollback.sh` + `leadv2-recovery` |

### 5. Project override hook

Before selecting probe type, check for a project-level verify override:

```bash
OVERRIDE="$CLAUDE_PROJECT_ROOT/.claude/leadv2-overrides/verify.sh"
STACK="$CLAUDE_PROJECT_ROOT/.claude/leadv2-overrides/stack.yaml"

if [[ -f "$OVERRIDE" ]]; then
  # Run project-specific verify script
  LEAD_V2_TASK_ID="<task-id>" \
  LEAD_V2_DEPLOY_TARGET="<target-if-known>" \
    bash "$OVERRIDE"
  override_rc=$?
  case $override_rc in
    0) echo "[verify] override PASS — proceed to Phase 8 Close" ;;
    1) echo "[verify] override TIMEOUT — trigger leadv2-recovery reason:timeout" ;;
    2) echo "[verify] override NEGATIVE SIGNAL — trigger leadv2-rollback + leadv2-recovery" ;;
  esac
  # Map exit code to probe outcome and skip generic probe steps below
  # Record in verify-probe-result.yaml and proceed per §4 table
else
  echo "[verify] no project override — using generic probe (§2 flowchart)"
fi
```

If no override exists: escalate via `leadv2-founder-input` with message:
"project has no verify.sh override in .claude/leadv2-overrides/ — define probe spec"

### 5b. Verify-probe types — generic (used when no override)

**Publish cycle log grep:**
```
log-grep on host:
  path: <your-app-log-path>     # example — fill from .claude/leadv2-overrides/stack.yaml
  pattern: "cycle_complete|action_published"
  timeout: 3600
```

**Web / dashboard change**:
```
http-check:
  url: <stack.yaml web.domain>/<page>
  expected: 200
  timeout: 300
```

**Schema / migration**:
```
supabase-check:
  description: "manual: verify <column> exists in <table>, RLS policy updated"
```

**Cron / scheduler change**:
```
log-grep with longer timeout:
  pattern: "<new cron job name> executed"
  timeout: <cron_interval_seconds + 300>
```

### 6. State update on success

```
LEAD_V2_STATE.md:
  phase: verify
  step: confirmed
  note: "live signal: <description>, seen at <timestamp>"

context.yaml.verification.confirmed_at: <ISO>
```

```bash
source .claude/scripts/leadv2-helpers.sh && leadv2_active_update_phase close
```

Proceed to Phase 8 Close.

### 7. State update on failure

```
LEAD_V2_STATE.md:
  phase: verify
  step: failed
  status: recovery
  note: "probe <timeout|negative>, triggering recovery"
```

Invoke `leadv2-recovery` skill.

## Rules

- **No "tests pass" shortcut.** Tests ≠ live signal. Must see real production effect.
- **Timeout must be realistic.** Publish cycle = 30-60 min. HTTP = seconds. Don't set 5-min for cron task.
- **Supabase-check is last resort.** Prefer log-grep or http-check. Manual prompt defeats autonomy.
- **Negative signal > timeout.** Error in log → immediate rollback, don't wait for timeout.
- **Heavy task = corroborate required.** Single positive probe is not enough when runtime paths are touched — a green log line with a concurrent 5xx spike is a false green. Use `--corroborate` with ≥1 no-regression probe.
- **Light task = single-probe acceptable.** Docs, web UI, schema-only changes don't need no-regression probes.

## Anti-patterns

- Asking founder "выглядит норм?" instead of defining a probe — that's abdicating automation.
- Probe returns OK but log has errors → missed scope of probe. Fix probe def, not skip.
- Accepting "systemd active" as verify — systemd only confirms process started, not did its work.
