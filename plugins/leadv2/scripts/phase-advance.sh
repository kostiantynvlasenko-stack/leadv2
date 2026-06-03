#!/usr/bin/env bash
set -euo pipefail

# phase-advance.sh — mid-task token-budget gate
# Called at every phase transition to check cumulative cost against the task's
# class cap.  Exits 1 (BUDGET_ABORT) when at/over cap; exits 0 otherwise.
#
# Usage: phase-advance.sh --task-id <id> --phase <name> [--cost <usd>]

log()       { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2; }
log_error() { log "ERROR: $*"; }

# ── Argument parsing ──────────────────────────────────────────────────────────
TASK_ID=""
PHASE=""
COST="0.0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --task-id) TASK_ID="$2"; shift 2 ;;
    --phase)   PHASE="$2";   shift 2 ;;
    --cost)    COST="$2";    shift 2 ;;
    *) log_error "Unknown argument: $1"; exit 1 ;;
  esac
done

if [[ -z "$TASK_ID" ]] || [[ -z "$PHASE" ]]; then
  log_error "Usage: phase-advance.sh --task-id <id> --phase <name> [--cost <usd>]"
  exit 1
fi

# ── Resolve project root (script lives in .claude/scripts/) ──────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

ESTIMATE_FILE="${PROJECT_ROOT}/docs/handoff/${TASK_ID}/cost-estimate.yaml"
COSTS_FILE="${PROJECT_ROOT}/docs/handoff/${TASK_ID}/phase-costs.yaml"

# ── No estimate → no gate ────────────────────────────────────────────────────
if [[ ! -f "$ESTIMATE_FILE" ]]; then
  exit 0
fi

# ── Read class_cap_usd and expected_total_usd.high from cost-estimate.yaml ───
read_estimate() {
  python3 - "$ESTIMATE_FILE" <<'PYEOF'
import sys, re

path = sys.argv[1]
with open(path) as f:
    text = f.read()

def extract(key):
    m = re.search(r'^\s*' + re.escape(key) + r'\s*:\s*([0-9.]+)', text, re.MULTILINE)
    if m:
        return float(m.group(1))
    return None

cap   = extract('class_cap_usd')
# FIX-4: anchor 'high' search under expected_total_usd parent key to avoid ambiguous match
high_m = re.search(r'expected_total_usd.*?high:\s*([\d.]+)', text, re.DOTALL)
high = float(high_m.group(1)) if high_m else None

if cap is None:
    print("MISSING_CAP")
    sys.exit(1)
if high is None:
    high = cap  # fall back to cap itself

print(f"{cap},{high}")
PYEOF
}

estimate_vals=$(read_estimate)
if [[ "$estimate_vals" == "MISSING_CAP" ]]; then
  log_error "cost-estimate.yaml missing class_cap_usd — skipping gate"
  exit 0
fi

CLASS_CAP_USD=$(echo "$estimate_vals" | cut -d',' -f1)
EXPECTED_HIGH=$(echo "$estimate_vals" | cut -d',' -f2)

# ── Accumulate prior phase costs ──────────────────────────────────────────────
sum_prior_costs() {
  python3 - "$COSTS_FILE" <<'PYEOF'
import sys, re

path = sys.argv[1]
try:
    with open(path) as f:
        text = f.read()
except FileNotFoundError:
    print("0.0")
    sys.exit(0)

# FIX-2 compat: match both quoted ("0.95") and unquoted (0.95) cost_usd values
total = sum(float(m) for m in re.findall(r'cost_usd\s*:\s*"?([0-9.]+)"?', text))
print(f"{total:.6f}")
PYEOF
}

if [[ -f "$COSTS_FILE" ]]; then
  PRIOR_COST=$(sum_prior_costs)
  # FIX-5: guard against empty or non-numeric result from python substitution
  PRIOR_COST="${PRIOR_COST:-0.0}"
  [[ -n "$PRIOR_COST" && "$PRIOR_COST" =~ ^[0-9] ]] || PRIOR_COST="0.0"
else
  # FIX-1: No phase tracking yet — first run, prior cost is zero
  PRIOR_COST="0.0"
fi

# ── Compute cumulative and percentage ────────────────────────────────────────
PCT=$(python3 -c "
import math
cap   = float('${CLASS_CAP_USD}')
prior = float('${PRIOR_COST}')
cost  = float('${COST}')
if cap <= 0:
    print(0)
else:
    # FIX-6: use math.ceil so 99.9% rounds up to 100 and triggers abort gate
    print(math.ceil((prior + cost) / cap * 100))
")

CUMULATIVE=$(python3 -c "print(float('${PRIOR_COST}') + float('${COST}'))")

# ── Gate decisions ────────────────────────────────────────────────────────────
if [[ "$PCT" -ge 100 ]]; then
  echo "BUDGET_ABORT: ${TASK_ID} at ${PCT}% of \$${CLASS_CAP_USD} cap" >&2
  exit 1
fi

if [[ "$PCT" -ge 75 ]]; then
  echo "BUDGET_WARN: ${TASK_ID} at ${PCT}% of \$${CLASS_CAP_USD} cap (warn threshold)"
fi

# ── Append entry to phase-costs.yaml ─────────────────────────────────────────
TS=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
# FIX-2: quote all shell variable values in YAML output to handle spaces/special chars
cat >> "$COSTS_FILE" <<YAML
- phase: "${PHASE}"
  cost_usd: "${COST}"
  pct_cap: ${PCT}
  ts: ${TS}
YAML

exit 0
