#!/usr/bin/env bash
set -euo pipefail
# leadv2-cost-estimate.sh — Pre-run cost estimator for /leadv2 tasks.
#
# Usage:
#   leadv2-cost-estimate.sh --task-id <id> --main-model <opus|sonnet>
#
# Reads:
#   docs/LEAD_V2_STATE.md              — task classification
#   docs/handoff/<id>/prior-art.yaml   — historical similar task costs (from R6 RAG intake)
#   .claude/ref/leadv2-routing.yaml    — expected tokens per phase
#
# Outputs:
#   docs/handoff/<id>/cost-estimate.yaml  — structured estimate
#   Human-readable summary to stdout

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
readonly PROJECT_ROOT

readonly ROUTING_YAML="$PROJECT_ROOT/.claude/ref/leadv2-routing.yaml"
readonly STATE_MD="$PROJECT_ROOT/docs/LEAD_V2_STATE.md"
readonly MAIN_MODEL_YAML="$PROJECT_ROOT/.claude/ref/leadv2-main-model.yaml"

log()      { printf '[leadv2-cost-estimate] %s\n' "$*" >&2; }
log_warn() { printf '[leadv2-cost-estimate] WARN: %s\n' "$*" >&2; }

usage() {
  cat >&2 <<'EOF'
Usage: leadv2-cost-estimate.sh --task-id <id> --main-model <opus|sonnet>
EOF
  exit 1
}

TASK_ID=""
MAIN_MODEL=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --task-id)    TASK_ID="$2";    shift 2 ;;
    --main-model) MAIN_MODEL="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) log_warn "unknown arg: $1"; usage ;;
  esac
done

[[ -z "$TASK_ID" || -z "$MAIN_MODEL" ]] && { log_warn "--task-id and --main-model are required"; usage; }

HANDOFF_DIR="$PROJECT_ROOT/docs/handoff/$TASK_ID"
mkdir -p "$HANDOFF_DIR"

PRIOR_ART_YAML="$HANDOFF_DIR/prior-art.yaml"
OUTPUT_YAML="$HANDOFF_DIR/cost-estimate.yaml"

python3 - \
  "$ROUTING_YAML" "$STATE_MD" "$PRIOR_ART_YAML" "$MAIN_MODEL_YAML" \
  "$TASK_ID" "$MAIN_MODEL" "$OUTPUT_YAML" <<'PYEOF'
import sys
import os
import math
from pathlib import Path

try:
    import yaml
except ImportError:
    print("ERROR: pyyaml not available — install pyyaml", file=sys.stderr)
    sys.exit(1)

routing_yaml_path, state_md_path, prior_art_path, main_model_yaml_path, \
    task_id, main_model, output_yaml_path = sys.argv[1:]

# ---------------------------------------------------------------------------
# Pricing (USD per 1M tokens)
# ---------------------------------------------------------------------------
PRICE = {
    "opus":   {"input": 15.0,  "output": 75.0,  "cache_read": 1.50, "cache_write": 18.75},
    "fable":  {"input": 10.0,  "output": 50.0,  "cache_read": 1.00, "cache_write": 12.50},
    "sonnet": {"input": 3.0,   "output": 15.0,  "cache_read": 0.30, "cache_write": 3.75},
    "haiku":  {"input": 0.25,  "output": 1.25,  "cache_read": 0.03, "cache_write": 0.30},
}
PRICE_KEYS = ["opus", "fable", "sonnet", "haiku"]

# ---------------------------------------------------------------------------
# Load routing YAML
# ---------------------------------------------------------------------------
def load_yaml(path: str) -> dict | list:
    try:
        return yaml.safe_load(Path(path).read_text()) or {}
    except Exception:
        return {}

routing = load_yaml(routing_yaml_path) if os.path.isfile(routing_yaml_path) else {}
phases_cfg = routing.get("phases", {}) if isinstance(routing, dict) else {}

# ---------------------------------------------------------------------------
# Determine task classification from LEAD_V2_STATE.md
# ---------------------------------------------------------------------------
classification = "Standard"
if os.path.isfile(state_md_path):
    for line in Path(state_md_path).read_text().splitlines():
        stripped = line.strip()
        if stripped.startswith("classification:"):
            val = stripped.split(":", 1)[1].strip().strip("'\"")
            if val:
                classification = val
            break

# ---------------------------------------------------------------------------
# Cost ceilings per class
# ---------------------------------------------------------------------------
CEILINGS = {"Light": 0.50, "Standard": 2.00, "Heavy": 8.00, "Strategic": 20.00}
class_cap = CEILINGS.get(classification, 2.00)

# ---------------------------------------------------------------------------
# Sum expected tokens across phases that use LLM for this class
# ---------------------------------------------------------------------------
PHASE_ORDER = ["intake", "plan", "build", "review", "deploy", "verify", "close"]
expected_phases = []
total_input_tokens = 0
total_output_tokens = 0

# Map classification → which plan/review step to pick
CLASS_TO_PLAN_STEP = {
    "Light": "light",
    "Standard": "standard",
    "Heavy": "heavy",
    "Strategic": "strategic",
}
CLASS_TO_REVIEW_STEP = {
    "Light": "light_low_risk",
    "Standard": "standard",
    "Heavy": "heavy",
    "Strategic": "heavy",
}

plan_step = CLASS_TO_PLAN_STEP.get(classification, "standard")
review_step = CLASS_TO_REVIEW_STEP.get(classification, "standard")

for phase_name in PHASE_ORDER:
    phase_cfg = phases_cfg.get(phase_name, {}) if isinstance(phases_cfg, dict) else {}
    if not phase_cfg:
        continue

    # Pick the relevant step for this phase
    if phase_name == "plan":
        step_cfgs = {plan_step: phase_cfg.get(plan_step, {})}
    elif phase_name == "review":
        step_cfgs = {review_step: phase_cfg.get(review_step, {})}
    else:
        step_cfgs = phase_cfg

    for step_name, step_cfg in step_cfgs.items():
        if not isinstance(step_cfg, dict):
            continue
        tokens = int(step_cfg.get("expected_tokens", 0))
        if tokens == 0:
            continue
        expected_phases.append(phase_name)
        # Rough 90/10 input/output split assumption
        total_input_tokens += int(tokens * 0.90)
        total_output_tokens += int(tokens * 0.10)

expected_phases = list(dict.fromkeys(expected_phases))  # dedupe, preserve order

# ---------------------------------------------------------------------------
# Compute cost range for the selected main model
# Cached fraction thanks to R6.10 prompt caching (~35% on average)
# ---------------------------------------------------------------------------
CACHED_FRACTION = 0.35
CACHE_DISCOUNT  = 0.10  # cached tokens cost 10% of full input price

main_model_lower = main_model.lower()
main_model_key = next((k for k in PRICE_KEYS if k in main_model_lower), None)
if main_model_key is None:
    print(f"WARNING: unknown model '{main_model}' — falling back to sonnet pricing", file=sys.stderr)
    main_model_key = "sonnet"
prices = PRICE[main_model_key]

def calc_cost(inp: int, out: int, cached_frac: float) -> float:
    cached_inp = inp * cached_frac
    uncached_inp = inp * (1 - cached_frac)
    return (
        uncached_inp * prices["input"]
        + cached_inp * prices["input"] * CACHE_DISCOUNT
        + out * prices["output"]
    ) / 1_000_000

# Subagents are always Sonnet (hybrid routing)
sub_prices = PRICE["sonnet"]
# Roughly 60% of token budget is subagents (build/review phases)
SUB_FRACTION = 0.60
sub_inp = int(total_input_tokens * SUB_FRACTION)
sub_out = int(total_output_tokens * SUB_FRACTION)
main_inp = total_input_tokens - sub_inp
main_out = total_output_tokens - sub_out

cost_mean = (
    calc_cost(main_inp, main_out, CACHED_FRACTION)
    + (sub_inp * sub_prices["input"] + sub_out * sub_prices["output"]) / 1_000_000
)
cost_low  = cost_mean * 0.50
cost_high = cost_mean * 2.33

# Sonnet equivalent (all Sonnet, same tokens)
sonnet_prices = PRICE["sonnet"]
sonnet_cost = (
    (total_input_tokens * (1 - CACHED_FRACTION) * sonnet_prices["input"]
     + total_input_tokens * CACHED_FRACTION * sonnet_prices["input"] * CACHE_DISCOUNT
     + total_output_tokens * sonnet_prices["output"])
    / 1_000_000
)
opus_premium = max(0.0, cost_mean - sonnet_cost)

# ---------------------------------------------------------------------------
# Load prior-art similar cost
# ---------------------------------------------------------------------------
prior_art_cost = None
if os.path.isfile(prior_art_path):
    try:
        data = load_yaml(prior_art_path)
        if isinstance(data, list) and len(data) > 0:
            costs = []
            for item in data[:3]:
                c = item.get("actual_cost_usd") or item.get("cost_usd")
                if c is not None:
                    try:
                        costs.append(float(c))
                    except (TypeError, ValueError):
                        pass
            if costs:
                prior_art_cost = round(sum(costs) / len(costs), 4)
    except Exception:
        pass

within_cap = cost_mean <= class_cap

# ---------------------------------------------------------------------------
# Write output YAML
# ---------------------------------------------------------------------------
estimate_block = {
    "task_id": task_id,
    "classification": classification,
    "main_model": main_model,
    "expected_phases": expected_phases,
    "expected_total_usd": {
        "low":  round(cost_low,  4),
        "mean": round(cost_mean, 4),
        "high": round(cost_high, 4),
    },
    "expected_tokens": {
        "input":  total_input_tokens,
        "output": total_output_tokens,
    },
    "cached_fraction": CACHED_FRACTION,
    "prior_art_similar_cost_usd": prior_art_cost,
    "class_cap_usd": class_cap,
    "within_cap": within_cap,
    "sonnet_equivalent_cost_usd": round(sonnet_cost, 4),
    "opus_premium_usd": round(opus_premium, 4),
    "generated_at": __import__("datetime").datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
}

output = {"estimate": estimate_block}
Path(output_yaml_path).write_text(yaml.dump(output, default_flow_style=False, sort_keys=False))

# ---------------------------------------------------------------------------
# Human-readable summary to stdout
# ---------------------------------------------------------------------------
within_str = "WITHIN CAP" if within_cap else "EXCEEDS CAP"
print(f"Cost estimate for {task_id} ({classification}, main={main_model}):")
print(f"  Expected: ${cost_low:.2f} – ${cost_mean:.2f} – ${cost_high:.2f} (low/mean/high)")
print(f"  Tokens: {total_input_tokens:,} in / {total_output_tokens:,} out")
print(f"  Cache fraction: {CACHED_FRACTION:.0%}")
if prior_art_cost is not None:
    print(f"  Prior-art avg (top-3): ${prior_art_cost:.2f}")
print(f"  Cap ({classification}): ${class_cap:.2f}  [{within_str}]")
print(f"  Sonnet equiv: ${sonnet_cost:.2f} | Opus premium: ${opus_premium:.2f}")
print(f"  Written to: {output_yaml_path}")
PYEOF
