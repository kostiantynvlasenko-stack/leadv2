#!/usr/bin/env bash
# leadv2-scorecard-write.sh — append or patch a scorecard row to docs/leadv2/scorecard.jsonl.
#
# MODES:
#   (default) — build and append a new row from context.yaml + costs.yaml + closed YAML.
#   --dry-run — print JSON to stdout without appending (unit-test friendly).
#   --patch    — merge patch fields by task_id (append-only patch record, flock protected).
#
# USAGE:
#   bash leadv2-scorecard-write.sh --task-id PO-042
#   bash leadv2-scorecard-write.sh --task-id PO-042 --dry-run
#   bash leadv2-scorecard-write.sh --task-id PO-042 --patch --post-deploy-regression 1
#
# EXIT CODES:
#   0  success
#   1  required args missing, file not found, or I/O error
#   4  schema violation — unknown key or enum value mismatch
#
# ENV:
#   LEADV2_PROJECT_ROOT       — required; repo root
#   LEADV2_SCORECARD_ON_CLOSE — must be "1" to enable append; absent = skip (D6)
#   LEADV2_FOUNDER_INTERVENTIONS — integer override for founder_interventions_count (D9)
#
# DECISIONS: D1 D2 D4 D6 D8 D9; R4 flock

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log()       { printf -- '[%s] leadv2-scorecard-write: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }
log_error() { log "ERROR: $*"; }

: "${LEADV2_PROJECT_ROOT:=$(git -C "$(dirname "$SCRIPT_DIR")" rev-parse --show-toplevel 2>/dev/null || pwd)}"

MODE="append"
TASK_ID=""
DRY_RUN=0
PATCH_POST_DEPLOY_REGRESSION=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --task-id)                TASK_ID="$2"; shift 2 ;;
    --dry-run)                DRY_RUN=1; MODE="append"; shift ;;
    --patch)                  MODE="patch"; shift ;;
    --post-deploy-regression) PATCH_POST_DEPLOY_REGRESSION="$2"; shift 2 ;;
    -h|--help)
      printf -- 'Usage: %s --task-id <id> [--dry-run]\n' "$(basename "$0")" >&2
      printf -- '       %s --task-id <id> --patch --post-deploy-regression 0|1\n' "$(basename "$0")" >&2
      exit 0 ;;
    *) log_error "unknown arg: $1"; exit 1 ;;
  esac
done

[[ -z "$TASK_ID" ]] && { log_error "--task-id is required"; exit 1; }

# D6 guard: absent LEADV2_SCORECARD_ON_CLOSE leaves existing flow byte-identical
if [[ "$MODE" == "append" && "${LEADV2_SCORECARD_ON_CLOSE:-0}" != "1" && "$DRY_RUN" != "1" ]]; then
  log "LEADV2_SCORECARD_ON_CLOSE not set — skipping scorecard write (D6)"
  exit 0
fi

SCORECARD_FILE="${LEADV2_PROJECT_ROOT}/docs/leadv2/scorecard.jsonl"
SCORECARD_LOCK="${LEADV2_PROJECT_ROOT}/docs/leadv2/.scorecard.lock"
SCHEMA_FILE="${SCRIPT_DIR}/../contracts/leadv2-scorecard.schema.json"
HANDOFF_DIR="${LEADV2_PROJECT_ROOT}/docs/handoff/${TASK_ID}"
CONTEXT_YAML="${HANDOFF_DIR}/context.yaml"
COSTS_YAML="${HANDOFF_DIR}/costs.yaml"
CLOSED_YAML="${LEADV2_PROJECT_ROOT}/docs/leadv2/closed/${TASK_ID}.yaml"
ROUTE_DECISIONS_YAML="${HANDOFF_DIR}/route-decisions.yaml"  # [BANDIT-01]

# ── PATCH mode ────────────────────────────────────────────────────────────────
if [[ "$MODE" == "patch" ]]; then
  [[ -z "$PATCH_POST_DEPLOY_REGRESSION" ]] && { log_error "--patch requires --post-deploy-regression 0|1"; exit 1; }
  if [[ "$PATCH_POST_DEPLOY_REGRESSION" != "0" && "$PATCH_POST_DEPLOY_REGRESSION" != "1" ]]; then
    log_error "--post-deploy-regression must be 0 or 1, got: ${PATCH_POST_DEPLOY_REGRESSION}"; exit 4
  fi
  PATCH_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  PATCH_JSON="{\"task_id\":\"${TASK_ID}\",\"post_deploy_regression\":${PATCH_POST_DEPLOY_REGRESSION},\"patch_at\":\"${PATCH_AT}\"}"
  mkdir -p "$(dirname "$SCORECARD_FILE")"
  (
    flock -x 9 || { log_error "could not acquire scorecard lock — aborting patch"; exit 1; }
    printf -- '%s\n' "$PATCH_JSON" >> "$SCORECARD_FILE"
    log "patch record appended: task_id=${TASK_ID} post_deploy_regression=${PATCH_POST_DEPLOY_REGRESSION}"
  ) 9>"$SCORECARD_LOCK"
  exit 0
fi

# ── APPEND mode ───────────────────────────────────────────────────────────────
[[ ! -f "$SCHEMA_FILE" ]] && { log_error "schema file not found: ${SCHEMA_FILE}"; exit 1; }

# Build JSON row via Python; exits 4 on schema violation (D2)
_py_build_row() {
  local _task_id="$1" _project_root="$2" _context="$3" _costs="$4" _closed="$5" _schema="$6"
  local _founder_int="${LEADV2_FOUNDER_INTERVENTIONS:-}"
  local _route_decisions_path="${_route_decisions_path:-}"
  python3 -c "
import sys, json, yaml, hashlib, os, re
from pathlib import Path
from datetime import datetime, timezone

task_id      = sys.argv[1]
project_root = sys.argv[2]
context_path = sys.argv[3]
costs_path   = sys.argv[4]
closed_path  = sys.argv[5]
schema_path  = sys.argv[6]
env_fi       = sys.argv[7]

errors = []
repo = Path(project_root).name

schema        = json.loads(Path(schema_path).read_text())
allowed_keys  = set(schema['properties'].keys())
required_keys = set(schema.get('required', []))

def enum_values(n):
    return schema['properties'].get(n, {}).get('enum')

ctx = {}
if Path(context_path).exists():
    try:
        ctx = yaml.safe_load(Path(context_path).read_text()) or {}
    except Exception as e:
        errors.append(f'context.yaml: {e}')

task_class = ctx.get('task_class') or ctx.get('class') or 'Standard'
if isinstance(ctx.get('classification'), dict):
    task_class = ctx['classification'].get('class', task_class)

arm = ctx.get('arm', None)
if arm not in ('A', 'B', None):
    arm = None

founder_int = 0
if ctx.get('decision_override'):
    founder_int += 1
if env_fi.isdigit():
    founder_int = int(env_fi)

cost_est_usd = None
est_block = ctx.get('cost_estimate') or {}
if isinstance(est_block, dict) and est_block.get('usd') is not None:
    try:
        cost_est_usd = float(est_block['usd'])
    except (TypeError, ValueError):
        pass

# Fallback: read cost-estimate.yaml when context.yaml lacks cost_estimate.usd
if cost_est_usd is None:
    ce_path = Path(project_root) / 'docs' / 'handoff' / task_id / 'cost-estimate.yaml'
    if ce_path.exists():
        try:
            ce_data = yaml.safe_load(ce_path.read_text()) or {}
            # cost-estimate.yaml structure: {estimate: {expected_total_usd: {mean: N}}}
            est_inner = ce_data.get('estimate') or {}
            mean_val = (est_inner.get('expected_total_usd') or {}).get('mean')
            if mean_val is not None:
                cost_est_usd = float(mean_val)
        except Exception as e:
            errors.append(f'cost-estimate.yaml: {e}')

cost_actual = None
if Path(costs_path).exists():
    try:
        rows = yaml.safe_load(Path(costs_path).read_text()) or []
        if isinstance(rows, list) and len(rows) > 0:
            cost_actual = round(sum(float(r.get('cost_usd', 0)) for r in rows if isinstance(r, dict)), 6)
        # empty list → cost_actual remains None (no data, not zero)
    except Exception as e:
        errors.append(f'costs.yaml: {e}')

# FIX-BANDIT-COST-01: fallback cost source for Workflow-tool runs (no claude-subsession.sh markers).
# leadv2-cost-flush.sh only handles .cost-pending.yaml from claude-subsession.sh; Workflow runs
# don't create those markers, so costs.yaml stays absent. Read optional cost-actual.yaml written
# by future instrumentation (TODO: add Workflow wrapper that writes token counts on completion).
# cost-actual.yaml shape: {cost_usd: <float>}  — single scalar, not a list.
if cost_actual is None:
    cost_actual_path = Path(project_root) / 'docs' / 'handoff' / task_id / 'cost-actual.yaml'
    if cost_actual_path.exists():
        try:
            ca_data = yaml.safe_load(cost_actual_path.read_text()) or {}
            if isinstance(ca_data, dict) and ca_data.get('cost_usd') is not None:
                cost_actual = round(float(ca_data['cost_usd']), 6)
        except Exception as e:
            errors.append(f'cost-actual.yaml: {e}')
# TODO(FIX-BANDIT-COST-01): wire Workflow completion hook to write cost-actual.yaml from
# usage_metadata returned by the Workflow tool response (input_tokens + output_tokens × model rate).

closed = {}
if Path(closed_path).exists():
    try:
        closed = yaml.safe_load(Path(closed_path).read_text()) or {}
    except Exception as e:
        errors.append(f'closed yaml: {e}')

outcome = closed.get('outcome', '')
verify_pass = 1 if 'success' in str(outcome).lower() else 0

closed_at = closed.get('closed_at') or datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
if isinstance(closed_at, str) and not closed_at.endswith('Z'):
    closed_at = closed_at[:19] + 'Z'

error_usd = round(cost_actual - cost_est_usd, 6) if (cost_actual is not None and cost_est_usd is not None) else None

h = int(hashlib.sha1(task_id.encode()).hexdigest(), 16)
shadow_arm = 'A' if h % 2 == 0 else 'B'

# Optional: nested_spawns from nested-spawns.log allow-count
nested_spawns = 0
ns_log = Path(project_root) / 'docs' / 'leadv2' / 'tasks' / task_id / 'nested-spawns.log'
if ns_log.exists():
    try:
        nested_spawns = sum(1 for ln in ns_log.read_text().splitlines() if 'verdict=allow' in ln)
    except Exception:
        nested_spawns = 0

# Optional: escalations_used from escalation-budget.yaml
escalations_used = 0
budget_path = Path(project_root) / 'docs' / 'handoff' / task_id / 'escalation-budget.yaml'
if budget_path.exists():
    try:
        import yaml as _yaml
        bd = _yaml.safe_load(budget_path.read_text()) or {}
        escalations_used = int(bd.get('used', 0))
    except Exception:
        try:
            import re as _re
            src = budget_path.read_text()
            m = _re.search(r'used\s*:\s*(\d+)', src)
            escalations_used = int(m.group(1)) if m else 0
        except Exception:
            escalations_used = 0

# [BANDIT-01] Read route-decisions.yaml for bandit route fields
# FIX-BANDIT-COST-01: also compute bandit_reward_composite inline so scorecard row carries
# a non-null value immediately; bandit update() later uses the same value to update arm priors.
route_phases_captured = 0
bandit_deviations = 0
bandit_reward_composite = None
route_decisions_path = sys.argv[8] if len(sys.argv) > 8 else ''
if route_decisions_path and Path(route_decisions_path).exists():
    try:
        import yaml as _ry
        entries = _ry.safe_load(Path(route_decisions_path).read_text()) or []
        if isinstance(entries, list) and len(entries) > 0:
            route_phases_captured = len(entries)
            bandit_deviations = sum(
                1 for e in entries
                if isinstance(e, dict) and str(e.get('bandit_deviation', 'false')).lower() == 'true'
            )
            # Compute composite reward now so the field is non-null in the scorecard row.
            # Canonical source: leadv2-route-bandit-py.py::compute_reward() (~line 195).
            # Keep byte-equivalent: ce==0 → cost_eff=1.0; only degrade to 2-term when
            # both cost values are absent (None), never when cost_est_usd==0.
            _vp = verify_pass  # already computed above (1 if 'success' in outcome, else 0)
            _pr = 0            # post_deploy_regression default; may be patched later
            if cost_actual is not None and cost_est_usd is not None:
                try:
                    ca, ce = float(cost_actual), float(cost_est_usd)
                    cost_eff = max(0.0, 1.0 - (ca / ce - 1.0)) if ce > 0 else 1.0
                    bandit_reward_composite = round(0.6 * _vp + 0.25 * (1 - _pr) + 0.15 * cost_eff, 4)
                except (TypeError, ValueError):
                    bandit_reward_composite = round(0.7 * _vp + 0.3 * (1 - _pr), 4)
            else:
                bandit_reward_composite = round(0.7 * _vp + 0.3 * (1 - _pr), 4)
    except Exception as e:
        errors.append(f'route-decisions.yaml: {e}')

row = {
    'task_id': task_id, 'repo': repo, 'task_class': task_class,
    'arm': arm, 'verify_pass': verify_pass, 'post_deploy_regression': 0,
    'cost_actual_usd': cost_actual, 'cost_estimate_usd': cost_est_usd,
    'error_usd': error_usd, 'founder_interventions_count': founder_int,
    'shadow_arm': shadow_arm, 'closed_at': closed_at,
    'nested_spawns': nested_spawns, 'escalations_used': escalations_used,
    'route_phases_captured': route_phases_captured,
    'bandit_deviations': bandit_deviations,
    'bandit_reward_composite': bandit_reward_composite,
}

unknown = set(row.keys()) - allowed_keys
if unknown:
    print(f'SCHEMA_ERROR:unknown_keys:{chr(44).join(sorted(unknown))}', file=sys.stderr)
    sys.exit(4)

missing = required_keys - set(row.keys())
if missing:
    print(f'SCHEMA_ERROR:missing_required:{chr(44).join(sorted(missing))}', file=sys.stderr)
    sys.exit(4)

for fn, val in row.items():
    ev = enum_values(fn)
    if ev is not None and val not in ev:
        print(f'SCHEMA_ERROR:enum:{fn}={val!r}', file=sys.stderr)
        sys.exit(4)

if not re.match(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$', str(closed_at)):
    print(f'SCHEMA_ERROR:closed_at_fmt:{closed_at!r}', file=sys.stderr)
    sys.exit(4)

for e in errors:
    print(f'WARN: {e}', file=sys.stderr)

print(json.dumps(row, separators=(',', ':')))
" "$_task_id" "$_project_root" "$_context" "$_costs" "$_closed" "$_schema" "$_founder_int" "${_route_decisions_path:-}"
}

# [BANDIT-01] Pass route-decisions.yaml path (absent file → nulls in scorecard)
_route_decisions_path="${ROUTE_DECISIONS_YAML}"

ROW_JSON=$(_py_build_row \
  "$TASK_ID" "$LEADV2_PROJECT_ROOT" \
  "$CONTEXT_YAML" "$COSTS_YAML" "$CLOSED_YAML" "$SCHEMA_FILE" \
) || {
  rc=$?
  [[ $rc -eq 4 ]] && { log_error "Schema violation (exit 4) — row not appended"; exit 4; }
  log_error "Row build failed (exit ${rc})"; exit 1
}

# Dry-run: print and exit
if [[ "$DRY_RUN" -eq 1 ]]; then
  printf -- '%s\n' "$ROW_JSON"
  log "dry-run: JSON printed (not appended)"
  exit 0
fi

# Idempotency + flock-protected append (D7, R4)
mkdir -p "$(dirname "$SCORECARD_FILE")"

(
  flock -x 9 || { log_error "could not acquire scorecard lock — aborting"; exit 1; }

  if [[ -f "$SCORECARD_FILE" ]]; then
    if python3 -c "
import sys, json
tid = sys.argv[1]
with open(sys.argv[2]) as f:
    for line in f:
        line = line.strip()
        if not line: continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue
        if obj.get('task_id') == tid and 'closed_at' in obj:
            sys.exit(0)
sys.exit(1)
" "$TASK_ID" "$SCORECARD_FILE" 2>/dev/null; then
      log "task_id=${TASK_ID} already in scorecard.jsonl — skipping (idempotent)"
      exit 0
    fi
  fi

  printf -- '%s\n' "$ROW_JSON" >> "$SCORECARD_FILE"
  log "row appended: task_id=${TASK_ID}"
) 9>"$SCORECARD_LOCK"
