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

### 6.5. Phase 7.5 — Soak-watch (invariant watchdog, post-verify gate)

**Gate condition:** only run when the task diff touched runtime, publish, or safety paths. Skip for docs, UI-only, schema-only, and tooling-only tasks.

```bash
# Gate: runtime/publish/safety diff check
_RUNTIME_CHANGED=$(git diff --name-only "${TASK_START_SHA}..HEAD" \
  | grep -E '^(agent/|platform/(publish|safety|auth|engine|cycle)|platform/.*cycle.*\.py)' \
  || true)

if [[ -n "$_RUNTIME_CHANGED" ]]; then
  echo "[verify] Phase 7.5 soak-watch: runtime/publish/safety paths touched — running invariant checks" >&2

  # Schedule a 24h outcome watch (shorter than the 48h Heavy-class watch in Phase 8)
  # to catch regressions that only surface after a few publish cycles
  bash "${CLAUDE_PLUGIN_ROOT}/scripts/leadv2-outcome-watch.sh" \
    --schedule \
    --task-id "${TASK_ID}" \
    --delay-hours 24

  # Immediate soak: run a second corroborating probe with an extended window
  # using the same verify-probe override if available
  SOAK_OVERRIDE="${CLAUDE_PROJECT_ROOT:-$PWD}/.claude/leadv2-overrides/soak-watch.sh"
  if [[ -x "$SOAK_OVERRIDE" ]]; then
    echo "[verify] running project soak-watch override: ${SOAK_OVERRIDE}" >&2
    _SOAK_RC=0
    LEADV2_TASK_ID="${TASK_ID}" \
    LEADV2_START_SHA="${TASK_START_SHA}" \
      bash "$SOAK_OVERRIDE" >/tmp/soak-watch-${TASK_ID}.out 2>&1 || _SOAK_RC=$?
    if [[ $_SOAK_RC -ne 0 ]]; then
      echo "[verify] WARN soak-watch override exited ${_SOAK_RC} — check /tmp/soak-watch-${TASK_ID}.out" >&2
      # Write advisory finding to handoff; does NOT block Phase 8
      printf 'soak_watch:\n  status: warn\n  exit_code: %d\n  output_file: /tmp/soak-watch-%s.out\n' \
        "$_SOAK_RC" "$TASK_ID" \
        >> "docs/handoff/${TASK_ID}/verify-probe-result.yaml"
    else
      printf 'soak_watch:\n  status: ok\n  exit_code: 0\n' \
        >> "docs/handoff/${TASK_ID}/verify-probe-result.yaml"
    fi
  else
    # No project override: log that soak-watch is pending via the scheduled outcome-watch
    echo "[verify] no soak-watch.sh override found — 24h outcome-watch scheduled (docs/leadv2/watches/${TASK_ID}.yaml)" >&2
    printf 'soak_watch:\n  status: scheduled\n  delay_hours: 24\n  note: "no immediate override — outcome-watch will fire at 24h"\n' \
      >> "docs/handoff/${TASK_ID}/verify-probe-result.yaml"
  fi
else
  echo "[verify] Phase 7.5 soak-watch: no runtime/publish/safety paths touched — skipped" >&2
fi
```

**Soak-watch does NOT block Phase 8 Close.** A warn/failure result is an advisory finding — write it to `verify-probe-result.yaml` and surface in the Phase 8 reflect entry. The 24h scheduled watch will flip `outcome_watch` in STATE.md history when it fires (via `leadv2-stale-sweeper.sh --sweep` at next session start).

**How to create a project soak-watch override:** place an executable `.claude/leadv2-overrides/soak-watch.sh` that exits 0 for stable and non-zero for regression. The script receives `LEADV2_TASK_ID` and `LEADV2_START_SHA` as env vars.

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

## Browser-qa step (frontend changes only)

**Configurable frontend roots:** by default `web/`. Repos with a different layout list path prefixes in `.claude/leadv2-overrides/frontend-paths.txt` (one prefix per line). E.g. m3-market: `m3/apps/`. The trigger reads that file if present, else defaults to `["web/"]`.

**RUN ONLY IF** at least one of:
- `git diff --name-only HEAD~1 HEAD` contains a path matching any configured frontend root
- `context.yaml.affected_paths` contains an entry matching any configured frontend root

For all other tasks this step is a **no-op** — skip entirely, no delay, no output file.

### Loading frontend roots

```bash
frontend_roots_file=".claude/leadv2-overrides/frontend-paths.txt"
if [[ -f "$frontend_roots_file" ]]; then
  mapfile -t frontend_roots < <(grep -vE '^\s*(#|$)' "$frontend_roots_file")
else
  frontend_roots=("web/")
fi
```

### When triggered

**1. Find preview URL**

```bash
# Option A: from recent vercel output recorded in context.yaml or LEAD_V2_STATE.md
preview_url=$(python3 -c "
import yaml, sys
ctx = yaml.safe_load(open('docs/leadv2/tasks/${TASK_ID}/context.yaml')) or {}
print(ctx.get('deploy_gate', {}).get('vercel_preview_url', '') or '')
" 2>/dev/null)

# Option B: from vercel meta output if present
if [[ -z "$preview_url" && -f "web/.vercel/output/meta.json" ]]; then
  preview_url=$(python3 -c "
import json, sys
d = json.load(open('web/.vercel/output/meta.json'))
print(d.get('url','') or d.get('previewUrl','') or '')
" 2>/dev/null || true)
fi
```

**2. HTTP smoke check (if preview URL found)**

```bash
if [[ -n "$preview_url" ]]; then
  http_status=$(curl -sIL --max-time 15 -w '%{http_code}' -o /dev/null "$preview_url" 2>/dev/null || echo "000")
  if [[ "$http_status" -ge 400 ]] || [[ "$http_status" == "000" ]]; then
    echo "[verify-browser] WARN: preview URL returned HTTP $http_status — $preview_url" >&2
    browser_qa_verdict="http_warn:${http_status}"
  else
    echo "[verify-browser] HTTP check OK: $http_status — $preview_url" >&2
    browser_qa_verdict="http_ok:${http_status}"
  fi
else
  echo "[verify-browser] NOTE: no preview URL found — skipping HTTP check" >&2
  browser_qa_verdict="no_url"
fi
```

**3. Playwright smoke check (optional, if available)**

```bash
# Check whether browser-qa skill or Playwright MCP is available for this project.
BROWSER_QA_OVERRIDE="${CLAUDE_PROJECT_ROOT:-$PWD}/.claude/leadv2-overrides/browser-qa.sh"
if [[ -x "$BROWSER_QA_OVERRIDE" && -n "$preview_url" ]]; then
  # Delegate one quick smoke check (load route, screenshot, no console errors).
  LEAD_V2_TASK_ID="$TASK_ID" \
  LEAD_V2_PREVIEW_URL="$preview_url" \
    bash "$BROWSER_QA_OVERRIDE" \
    && browser_qa_verdict="playwright_ok" \
    || browser_qa_verdict="playwright_warn"
else
  echo "[verify-browser] NOTE: no browser-qa.sh override — Playwright check skipped" >&2
fi
```

**4. Write result to handoff**

```bash
mkdir -p "docs/handoff/${TASK_ID}"
cat > "docs/handoff/${TASK_ID}/verify-browser.md" <<EOF
# Browser QA — ${TASK_ID}

- preview_url: ${preview_url:-none}
- http_status: ${http_status:-n/a}
- verdict: ${browser_qa_verdict:-skipped}
- timestamp: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
EOF
```

A `http_warn` or `playwright_warn` result is **advisory** — it does not block Phase 8 Close unless the main positive probe also failed. Log the warning in `LEAD_V2_STATE.md` and continue.

A `http_ok` or `playwright_ok` result counts as an **additional corroboration** probe — record in `context.yaml.verification.browser_qa`.

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
