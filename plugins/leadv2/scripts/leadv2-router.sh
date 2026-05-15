#!/usr/bin/env bash
# leadv2-router.sh — Marginal-value router for /leadv2 phases.
# Reads leadv2-routing.yaml, applies signal conditions, outputs selected model + command template.
# No LLM calls — pure bash + python.
#
# Usage:
#   leadv2-router.sh --phase <phase> --step <step> [--signals '{"risk":"high","total_lines":600}']
#                    [--task-id <id>] [--class <Light|Standard|Heavy|Strategic>]
#
# Output (on stdout):
#   model=sonnet
#   tool=claude-subsession
#   command_template=bash .claude/scripts/claude-subsession.sh --role {{role}} --model sonnet --task-id {{task_id}} --mission-file {{mission}}
#   expected_cost_usd=0.08
#   expected_tokens=15000
#   ceiling_status=ok          # ok | warn_60pct | hard_stop_95pct
#   downgrade_applied=false    # true if model was downgraded due to cost/empty-session
#
# Exit codes:
#   0 — model selected, proceed
#   1 — hard stop (burn > 95% ceiling, or no valid model after stop rules)
#   2 — routing.yaml missing (caller should fall back to class-based routing)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
readonly PROJECT_ROOT
readonly ROUTING_YAML="$PROJECT_ROOT/.claude/ref/leadv2-routing.yaml"
readonly AGENT_STATS_YAML="$PROJECT_ROOT/docs/agents/agent-stats.yaml"
# LEADV2_PRIORS_YAML: optional override path; defaults to docs/leadv2-priors.yaml
PRIORS_YAML="${LEADV2_PRIORS_YAML:-${PROJECT_ROOT}/docs/leadv2-priors.yaml}"

log() { printf '[leadv2-router] %s\n' "$*" >&2; }
log_warn() { printf '[leadv2-router] WARN: %s\n' "$*" >&2; }
log_error() { printf '[leadv2-router] ERROR: %s\n' "$*" >&2; }

usage() {
  cat >&2 <<'EOF'
Usage: leadv2-router.sh --phase <phase> --step <step>
                        [--signals '{"risk":"high","total_lines":600}']
                        [--task-id <id>]
                        [--class <Light|Standard|Heavy|Strategic>]
EOF
  exit 1
}

PHASE=""
STEP=""
SIGNALS="{}"
TASK_ID=""
TASK_CLASS="Standard"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --phase)   PHASE="$2";      shift 2 ;;
    --step)    STEP="$2";       shift 2 ;;
    --signals) SIGNALS="$2";    shift 2 ;;
    --task-id) TASK_ID="$2";    shift 2 ;;
    --class)   TASK_CLASS="$2"; shift 2 ;;
    *) log_error "unknown arg: $1"; usage ;;
  esac
done

[[ -z "$PHASE" || -z "$STEP" ]] && { log_error "--phase and --step required"; usage; }

# ---------------------------------------------------------------------------
# Fallback: routing.yaml missing → exit 2 so caller uses class-based routing
# ---------------------------------------------------------------------------
if [[ ! -f "$ROUTING_YAML" ]]; then
  log_warn "routing.yaml not found at $ROUTING_YAML — caller should use class-based fallback"
  exit 2
fi

# ---------------------------------------------------------------------------
# Python helper: reads routing.yaml, evaluates signals, applies stop rules,
# checks cost ceiling, outputs key=value pairs for bash to consume.
# ---------------------------------------------------------------------------
PY_HELPER=$(mktemp /tmp/leadv2-router-XXXXXX.py)
trap 'rm -f "$PY_HELPER"' EXIT

python3 -c "import sys; print(open(sys.argv[1]).read())" /dev/stdin > "$PY_HELPER" 2>/dev/null <<'PYEOF'
import sys
import json
import math
import os
from pathlib import Path

try:
    import yaml
except ImportError:
    # Minimal YAML subset parser for our simple routing.yaml structure
    # (no anchors, no complex types beyond str/int/float/bool/dict/list)
    yaml = None

def load_yaml_file(path: str) -> dict:
    """Load YAML using PyYAML if available, else fallback to json (not ideal but safe for our format)."""
    content = Path(path).read_text()
    if yaml:
        return yaml.safe_load(content)
    # Last-resort: try to import ruamel or tomllib as alternatives
    try:
        import tomllib  # 3.11+
    except ImportError:
        pass
    # If nothing works, raise so the bash script exits 2
    raise RuntimeError("PyYAML not available — install pyyaml")

routing_yaml, phase, step, signals_json, task_id, task_class = \
    sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6]
priors_yaml = sys.argv[8] if len(sys.argv) > 8 else ""

# Parse signals
try:
    signals = json.loads(signals_json)
except json.JSONDecodeError:
    signals = {}

# Load operator priors routing hints (non-blocking — missing file is OK)
priors_routing: dict = {}
try:
    if priors_yaml and Path(priors_yaml).is_file():
        p = load_yaml_file(priors_yaml)
        if isinstance(p, dict):
            priors_routing = p.get("routing_priors", {}) or {}
            # Merge priors into signals for downstream escalate_if evaluation
            # signal key: priors_skip_llm = true when task_class is in skip_llm_for
            # DEFENSIVE READ (Risk 5): list fields may be "insufficient_data" until
            # 10+ history entries exist. Normalize sentinel to empty list.
            def _safe_list(d, key):
                v = d.get(key, [])
                return v if isinstance(v, list) else []

            skip_llm = _safe_list(priors_routing, "skip_llm_for")
            sonnet_ok = _safe_list(priors_routing, "sonnet_sufficient_for")
            opus_ok   = _safe_list(priors_routing, "opus_justified_for")
            tc_lower = task_class.lower()
            if any(tc_lower == s.lower() for s in skip_llm):
                signals.setdefault("priors_skip_llm", True)
            if any(tc_lower == s.lower() for s in sonnet_ok):
                signals.setdefault("priors_sonnet_ok", True)
            if any(tc_lower == s.lower() for s in opus_ok):
                signals.setdefault("priors_opus_justified", True)
except Exception:
    pass   # priors are enrichment only — never block routing

# Load routing table
try:
    cfg = load_yaml_file(routing_yaml)
except Exception as e:
    print(f"ROUTING_YAML_ERROR: {e}", file=sys.stderr)
    sys.exit(2)

# Navigate to phase.step
phases = cfg.get("phases", {})
phase_cfg = phases.get(phase, {})
step_cfg = phase_cfg.get(step, {})

if not step_cfg:
    # Unknown phase/step — emit empty so bash falls through to class-based
    print("UNKNOWN_PHASE_STEP")
    sys.exit(2)

# Determine selected model: check escalate_if condition
selected_model = step_cfg.get("default", "sonnet")
tool = step_cfg.get("tool", "agent-tool")
expected_cost = step_cfg.get("expected_cost_usd", 0.0)
expected_tokens = step_cfg.get("expected_tokens", 0)
is_floor = step_cfg.get("floor", False)
escalated = False

escalate_if = step_cfg.get("escalate_if", "")
if escalate_if:
    # Evaluate simple condition: key==value or key>value
    cond = escalate_if.strip()
    try:
        if "==" in cond:
            lhs, rhs = cond.split("==", 1)
            lhs = lhs.strip().replace(".", "_")
            # Walk nested keys using dot notation
            val = signals
            for part in lhs.split("_"):
                if isinstance(val, dict):
                    val = val.get(part, None)
            if val is not None and str(val) == rhs.strip():
                escalated = True
        elif ">" in cond:
            lhs, rhs = cond.split(">", 1)
            lhs = lhs.strip()
            # Support dotted keys
            val = signals
            for part in lhs.split("."):
                if isinstance(val, dict):
                    val = val.get(part, None)
            if val is not None:
                try:
                    if float(val) > float(rhs.strip()):
                        escalated = True
                except (ValueError, TypeError):
                    pass
    except Exception:
        pass  # ignore malformed condition, don't escalate

if escalated:
    selected_model = step_cfg.get("escalate_to", selected_model)
    tool = step_cfg.get("escalate_tool", tool)
    expected_cost = step_cfg.get("escalate_cost_usd", expected_cost * 3)
    expected_tokens = int(expected_tokens * 4)

# ---------------------------------------------------------------------------
# Agent success rate check: escalate if agent has low success for change_kind
# ---------------------------------------------------------------------------
change_kind = signals.get("change_kind", "")
if change_kind and os.path.isfile(sys.argv[7] if len(sys.argv) > 7 else ""):
    # agent-stats.yaml present — check success_rate
    try:
        stats_cfg = load_yaml_file(sys.argv[7])
        agents_list = stats_cfg.get("agents", [])
        # Derive primary agent from tool/model string
        primary_agent = "developer"
        if "architect" in selected_model:
            primary_agent = "architect"
        elif "critic" in selected_model:
            primary_agent = "critic"
        for entry in agents_list:
            if entry.get("agent") == primary_agent and entry.get("change_kind") == change_kind:
                rate = float(entry.get("success_rate_30d", 1.0))
                if rate < 0.60:
                    # Auto-escalate: sonnet→opus, add critic pass
                    downgrade_chain = cfg.get("downgrade_chain", {})
                    # Escalate upward (reverse of downgrade)
                    escalate_map = {v: k for k, v in downgrade_chain.items()}
                    base_model = selected_model.split("+")[0].split("-")[0]
                    if base_model in escalate_map and not is_floor:
                        selected_model = escalate_map[base_model] + "+" + selected_model
                        escalated = True
    except Exception:
        pass

# ---------------------------------------------------------------------------
# Cost ceiling check
# ---------------------------------------------------------------------------
stop_rules = cfg.get("stop_rules", {})
ceiling_cfg = stop_rules.get("cost_ceiling_per_task", {})
ceiling = float(ceiling_cfg.get(task_class, 2.00))
warn_pct = float(ceiling_cfg.get("warn_threshold_pct", 60)) / 100
hard_pct = float(ceiling_cfg.get("hard_stop_threshold_pct", 95)) / 100

current_burn = 0.0
if task_id:
    costs_file = Path(f"docs/handoff/{task_id}/costs.yaml")
    # Try PROJECT_ROOT prefix
    alt = Path(os.environ.get("PROJECT_ROOT", ".")) / "docs" / "handoff" / task_id / "costs.yaml"
    for cf in [costs_file, alt]:
        if cf.is_file():
            try:
                entries = load_yaml_file(str(cf))
                if isinstance(entries, list):
                    current_burn = sum(float(e.get("cost_usd", 0)) for e in entries if isinstance(e, dict))
                break
            except Exception:
                pass

ceiling_status = "ok"
downgrade_applied = False

if ceiling > 0 and current_burn > 0:
    burn_ratio = current_burn / ceiling
    if burn_ratio >= hard_pct:
        ceiling_status = "hard_stop_95pct"
    elif burn_ratio >= warn_pct:
        ceiling_status = "warn_60pct"
        # Downgrade subsequent model: opus→sonnet, but respect floor
        if not is_floor:
            downgrade_chain = cfg.get("downgrade_chain", {})
            parts = selected_model.split("+")
            new_parts = []
            for p in parts:
                base = p.split("-")[0]
                new_parts.append(downgrade_chain.get(base, p))
            new_model = "+".join(new_parts)
            if new_model != selected_model:
                selected_model = new_model
                downgrade_applied = True
                expected_cost = expected_cost * 0.3  # rough sonnet vs opus ratio

# ---------------------------------------------------------------------------
# Build command_template from tool type
# ---------------------------------------------------------------------------
def build_command_template(tool_str: str, model_str: str) -> str:
    # Primary model is the first token before +
    primary_model = model_str.split("+")[0].replace("-subsession", "").replace("-agent-tool", "")
    if primary_model in ("bash", "bash+python", "bash+yaml", "mcp-calls-only", "skip"):
        return f"# no-LLM: {primary_model}"
    if "subsession" in tool_str or "subsession" in model_str:
        return (
            "bash .claude/scripts/claude-subsession.sh "
            "--role {{role}} "
            f"--model {primary_model} "
            "--task-id {{task_id}} "
            "--mission-file {{mission}} "
            "--wait"
        )
    # Default: Agent tool invocation hint
    return (
        f"Agent(subagent_type={{role}}, model={primary_model}, "
        "prompt=<mission from {{mission_file}}>)"
    )

command_template = build_command_template(tool, selected_model)

print(f"model={selected_model}")
print(f"tool={tool}")
print(f"command_template={command_template}")
print(f"expected_cost_usd={expected_cost:.4f}")
print(f"expected_tokens={expected_tokens}")
print(f"ceiling_status={ceiling_status}")
print(f"downgrade_applied={str(downgrade_applied).lower()}")
print(f"escalated={str(escalated).lower()}")
print(f"current_burn_usd={current_burn:.6f}")
print(f"ceiling_usd={ceiling:.2f}")
PYEOF

# Run the helper — argv[7]=agent-stats, argv[8]=priors-yaml
STATS_ARG="${AGENT_STATS_YAML:-}"

result=$(python3 "$PY_HELPER" \
  "$ROUTING_YAML" "$PHASE" "$STEP" "$SIGNALS" \
  "${TASK_ID:-}" "${TASK_CLASS:-Standard}" \
  "${STATS_ARG:-}" "${PRIORS_YAML:-}" 2>/tmp/leadv2-router-err.tmp) || {
  err_code=$?
  if [[ $err_code -eq 2 ]]; then
    log_warn "routing.yaml parse error or unknown phase/step — caller uses fallback"
    cat /tmp/leadv2-router-err.tmp >&2 2>/dev/null || true
    exit 2
  fi
  log_error "router python helper failed (exit $err_code)"
  cat /tmp/leadv2-router-err.tmp >&2 2>/dev/null || true
  exit 1
}

if [[ "$result" == "ROUTING_YAML_ERROR"* ]] || [[ "$result" == "UNKNOWN_PHASE_STEP"* ]]; then
  log_warn "routing returned: $result — using fallback"
  exit 2
fi

# Extract ceiling_status to decide exit code
ceiling_status=$(printf '%s\n' "$result" | grep '^ceiling_status=' | cut -d= -f2)

if [[ "$ceiling_status" == "hard_stop_95pct" ]]; then
  log_error "HARD STOP: task burn >= 95% of ceiling — refusing spawn for $PHASE/$STEP"
  printf '%s\n' "$result"
  exit 1
fi

if [[ "$ceiling_status" == "warn_60pct" ]]; then
  log_warn "burn >= 60% of ceiling — model may have been downgraded for $PHASE/$STEP"
fi

printf '%s\n' "$result"
exit 0
