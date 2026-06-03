#!/usr/bin/env bash
# leadv2-premortem.sh — Cheap pre-mortem simulator for /leadv2 deploy path.
# No LLM calls — pure bash+python heuristics.
#
# Usage:
#   leadv2-premortem.sh --task-id <id> --phase <build|deploy>
#                       [--project-root <path>]
#
# Reads:
#   docs/handoff/<task-id>/context.yaml
#   docs/handoff/<task-id>/prior-art.yaml       (optional)
#   docs/handoff/<task-id>/negative-memory.yaml (optional)
#   docs/handoff/<task-id>/coverage.yaml        (optional, deploy phase)
#   docs/handoff/<task-id>/review.yaml          (optional, deploy phase)
#
# Writes:
#   docs/handoff/<task-id>/premortem-<phase>.yaml
#
# Exit codes:
#   0 = proceed
#   1 = proceed_with_caution
#   2 = skip_recommended
#
# Calibration targets (tune with real data after 50+ tasks):
#   See .claude/skills/leadv2-premortem/SKILL.md#calibration-note

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
readonly SCRIPT_DIR PROJECT_ROOT

log()       { printf '[leadv2-premortem] %s\n' "$*" >&2; }
log_warn()  { printf '[leadv2-premortem] WARN: %s\n' "$*" >&2; }
log_error() { printf '[leadv2-premortem] ERROR: %s\n' "$*" >&2; }

usage() {
  cat >&2 <<'EOF'
Usage: leadv2-premortem.sh --task-id <id> --phase <build|deploy>
                           [--project-root <path>]
EOF
  exit 1
}

TASK_ID=""
PHASE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --task-id)      TASK_ID="$2";        shift 2 ;;
    --phase)        PHASE="$2";          shift 2 ;;
    --project-root) PROJECT_ROOT="$2";   shift 2 ;;
    -h|--help)      usage ;;
    *) log_error "unknown arg: $1"; usage ;;
  esac
done

[[ -z "$TASK_ID" ]] && { log_error "--task-id required"; usage; }
[[ -z "$PHASE" ]]   && { log_error "--phase required (build|deploy)"; usage; }
[[ "$PHASE" != "build" && "$PHASE" != "deploy" ]] && {
  log_error "--phase must be 'build' or 'deploy'"; usage
}

HANDOFF_DIR="${PROJECT_ROOT}/docs/handoff/${TASK_ID}"
OUTPUT_FILE="${HANDOFF_DIR}/premortem-${PHASE}.yaml"

# Source helpers for _atomic_write_yaml and leadv2_validate_yaml (PO-057).
# shellcheck source=leadv2-helpers.sh
source "${SCRIPT_DIR}/leadv2-helpers.sh" || { echo "FATAL: cannot source leadv2-helpers.sh" >&2; exit 1; }

[[ ! -d "$HANDOFF_DIR" ]] && { log_error "handoff dir not found: $HANDOFF_DIR"; exit 1; }

# Dual-path hook: after bash heuristic writes OUTPUT_FILE, Haiku refines it.
# (Invoked below at end of run; see PREMORTEM_HAIKU_WIRE block.)
PREMORTEM_HAIKU_SCRIPT="${SCRIPT_DIR}/leadv2-premortem-haiku.sh"

# Guard: never overwrite an existing run
if [[ -f "$OUTPUT_FILE" ]]; then
  log_warn "premortem-${PHASE}.yaml already exists — reading existing verdict"
  exit_code=0
  verdict=$(python3 -c "
import yaml, sys
with open('$OUTPUT_FILE') as fh:
    d = yaml.safe_load(fh) or {}
v = d.get('premortem', d).get('verdict', 'proceed')
print(v)
" 2>/dev/null || echo "proceed")
  case "$verdict" in
    skip_recommended) exit_code=2 ;;
    proceed_with_caution) exit_code=1 ;;
    *) exit_code=0 ;;
  esac
  log "Re-using existing verdict: $verdict (exit $exit_code)"
  exit "$exit_code"
fi

log "Running pre-mortem for task=$TASK_ID phase=$PHASE"

# ---------------------------------------------------------------------------
# Python helper: read all context files, apply heuristics, write output yaml
# ---------------------------------------------------------------------------
_cleanup_tmps=()
trap 'rm -f "${_cleanup_tmps[@]}"' EXIT
PY_TMP=$(mktemp /tmp/leadv2-premortem-XXXXXX.py)
_cleanup_tmps+=("$PY_TMP")

python3 -c "import sys; print(open(sys.argv[1]).read())" /dev/stdin > "$PY_TMP" 2>/dev/null <<'PYEOF'
import sys
import os
import json
from datetime import datetime, timezone
from pathlib import Path

try:
    import yaml
except ImportError:
    print("ERROR: pyyaml not installed", file=sys.stderr)
    sys.exit(1)

task_id      = sys.argv[1]
phase        = sys.argv[2]
handoff_dir  = Path(sys.argv[3])

def safe_load(p: Path) -> dict | list | None:
    if not p.is_file():
        return None
    try:
        return yaml.safe_load(p.read_text()) or None
    except Exception:
        return None

# ── Load context files ──────────────────────────────────────────────────────
context_raw     = safe_load(handoff_dir / "context.yaml")
prior_art_raw   = safe_load(handoff_dir / "prior-art.yaml")
neg_memory_raw  = safe_load(handoff_dir / "negative-memory.yaml")
coverage_raw    = safe_load(handoff_dir / "coverage.yaml")
review_raw      = safe_load(handoff_dir / "review.yaml")

# ── Parse context fields ────────────────────────────────────────────────────
ctx = context_raw if isinstance(context_raw, dict) else {}
task_ctx = ctx.get("task", {})
task_class       = str(task_ctx.get("class", "Standard")).lower()
decisions_list   = ctx.get("decisions", []) or []
off_limits_list  = ctx.get("off_limits", []) or []

fp = ctx.get("graph_footprint", {}) or {}
footprint_risk       = str(fp.get("risk_score", "")).lower()
change_kind          = str(fp.get("change_kind", "")).lower()
impacted_callers_raw = fp.get("impacted_callers_count", 0)
try:
    impacted_callers = int(impacted_callers_raw)
except (TypeError, ValueError):
    impacted_callers = 0

# ── Parse prior art ─────────────────────────────────────────────────────────
prior_list = prior_art_raw if isinstance(prior_art_raw, list) else []
prior_top3 = prior_list[:3]
has_rollback_prior = any(
    str(p.get("outcome", "")).lower() == "rollback" for p in prior_top3
)
all_success_prior = (
    len(prior_top3) > 0 and
    all(str(p.get("outcome", "")).lower() == "success" for p in prior_top3)
)
has_prior_art = len(prior_list) > 0

# ── Parse negative memory ───────────────────────────────────────────────────
neg_mem_list = neg_memory_raw if isinstance(neg_memory_raw, list) else []
if isinstance(neg_memory_raw, dict):
    neg_mem_list = neg_memory_raw.get("matches", []) or []
has_negative_memory = len(neg_mem_list) > 0

# ── Parse coverage (deploy phase only) ─────────────────────────────────────
coverage_pct   = 0
coverage_passed = True
if coverage_raw and isinstance(coverage_raw, dict):
    cov = coverage_raw.get("coverage", coverage_raw)
    coverage_pct    = float(cov.get("new_code_pct", 100))
    coverage_passed = bool(cov.get("passed", True))

# ── Parse review findings (deploy phase only) ───────────────────────────────
review_remaining = 0
if review_raw and isinstance(review_raw, dict):
    rev = review_raw.get("reviews", review_raw)
    review_remaining = int(rev.get("findings_remaining", 0))

# ── Heuristic factor table ──────────────────────────────────────────────────
BASE_SUCCESS = 0.80

FACTOR_DEFS: list[dict] = [
    # Risk factors (deduct from success)
    {
        "factor": "rag_prior_similar_rolled_back",
        "triggered": has_rollback_prior,
        "weight": +0.15,
        "direction": "risk",
    },
    {
        "factor": "graph_footprint_risk_high",
        "triggered": footprint_risk == "high",
        "weight": +0.10,
        "direction": "risk",
    },
    {
        "factor": "graph_footprint_risk_critical",
        "triggered": footprint_risk == "critical",
        "weight": +0.20,
        "direction": "risk",
    },
    # blast_radius factors are mutually exclusive: only the highest bracket triggers.
    # blast_radius_critical (>= 25) takes precedence over blast_radius_high (>= 10).
    {
        "factor": "blast_radius_high",
        "triggered": 10 <= impacted_callers < 25,
        "weight": +0.10,
        "direction": "risk",
    },
    {
        "factor": "blast_radius_critical",
        "triggered": impacted_callers >= 25,
        "weight": +0.20,
        "direction": "risk",
    },
    {
        "factor": "negative_memory_match",
        "triggered": has_negative_memory,
        "weight": +0.20,
        "direction": "risk",
    },
    {
        "factor": "change_kind_cross_service",
        "triggered": "cross_service" in change_kind,
        "weight": +0.05,
        "direction": "risk",
    },
    {
        "factor": "off_limits_candidates_nonzero",
        "triggered": len(off_limits_list) > 0,
        "weight": +0.05,
        "direction": "risk",
    },
    {
        "factor": "coverage_low",
        "triggered": (phase == "deploy" and coverage_pct < 50),
        "weight": +0.10,
        "direction": "risk",
    },
    {
        "factor": "review_findings_remaining",
        "triggered": (phase == "deploy" and review_remaining > 0),
        "weight": +0.15,
        "direction": "risk",
    },
    {
        "factor": "high_decision_count",
        "triggered": len(decisions_list) > 5,
        "weight": +0.05,
        "direction": "risk",
    },
    {
        "factor": "no_prior_art",
        "triggered": not has_prior_art,
        "weight": +0.03,
        "direction": "risk",
    },
    {
        "factor": "class_heavy_or_strategic",
        "triggered": task_class in ("heavy", "strategic"),
        "weight": +0.05,
        "direction": "risk",
    },
    # Positive factors (add to success)
    {
        "factor": "prior_all_success",
        "triggered": all_success_prior,
        "weight": -0.10,
        "direction": "positive",
    },
    {
        "factor": "coverage_high",
        "triggered": (phase == "deploy" and coverage_pct >= 70),
        "weight": -0.05,
        "direction": "positive",
    },
    {
        "factor": "class_light",
        "triggered": task_class == "light",
        "weight": -0.05,
        "direction": "positive",
    },
]

# Compute success probability
total_deduction = sum(
    f["weight"] for f in FACTOR_DEFS if f["triggered"]
)
success_prob = max(0.05, min(0.95, BASE_SUCCESS - total_deduction))

# ── Outcome distribution ─────────────────────────────────────────────────────
risk_high       = footprint_risk in ("high", "critical")
rollback_mult   = (2.0 if has_negative_memory else 1.0) * (1.5 if has_rollback_prior else 1.0)
timeout_mult    = 1.5 if "cross_service" in change_kind else 1.0
cov_low_mult    = 2.0 if (phase == "deploy" and coverage_pct < 50) else 1.0
offlimits_mult  = 3.0 if risk_high else 1.0

raw_block     = 0.02 * offlimits_mult
raw_rollback  = 0.10 * rollback_mult
raw_timeout   = 0.08 * timeout_mult
raw_partial   = 0.05 * cov_low_mult

# Normalize failure modes so total = 1 - success_prob
raw_fail_total = raw_block + raw_rollback + raw_timeout + raw_partial
failure_budget = max(0.0, 1.0 - success_prob)
if raw_fail_total > 0 and failure_budget > 0:
    norm = failure_budget / raw_fail_total
    p_block   = round(raw_block    * norm, 3)
    p_rollback = round(raw_rollback * norm, 3)
    p_timeout  = round(raw_timeout  * norm, 3)
    p_partial  = round(raw_partial  * norm, 3)
    # Adjust for rounding errors
    p_partial += round(failure_budget - (p_block + p_rollback + p_timeout + p_partial), 3)
else:
    p_block = p_rollback = p_timeout = p_partial = 0.0

# ── Verdict ──────────────────────────────────────────────────────────────────
if success_prob > 0.70:
    verdict = "proceed"
    notes = f"Success prob {success_prob:.2f} — normal flow."
elif success_prob >= 0.40:
    verdict = "proceed_with_caution"
    triggered = [f["factor"] for f in FACTOR_DEFS if f["triggered"]]
    notes = f"Success prob {success_prob:.2f} — caution: {', '.join(triggered[:3]) if triggered else 'borderline'}."
else:
    verdict = "skip_recommended"
    triggered = [f["factor"] for f in FACTOR_DEFS if f["triggered"]]
    notes = (
        f"Success prob {success_prob:.2f} < 0.40 — recommend redesign via architect. "
        f"Top risks: {', '.join(triggered[:3]) if triggered else 'compound risk'}."
    )

# ── Write output ─────────────────────────────────────────────────────────────
risk_factors_out = [
    {
        "factor": f["factor"],
        "triggered": bool(f["triggered"]),
        "weight": f"+{f['weight']}" if f["weight"] >= 0 else str(f["weight"]),
    }
    for f in FACTOR_DEFS
]

output = {
    "premortem": {
        "task_id": task_id,
        "phase": phase,
        "computed_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "predicted_outcome_prob": {
            "success": round(success_prob, 3),
            "block_offlimits": p_block,
            "rollback": p_rollback,
            "verify_timeout": p_timeout,
            "partial_coverage": p_partial,
        },
        "risk_factors": risk_factors_out,
        "verdict": verdict,
        "notes": notes,
    }
}

import io as _io
_yaml_buf = _io.StringIO()
yaml.dump(output, _yaml_buf, default_flow_style=False, sort_keys=False, allow_unicode=True)
sys.stdout.write(_yaml_buf.getvalue())
PYEOF

# STATUS_FILE side-channel: verdict/success_prob written here, stdout stays pure YAML
STATUS_FILE=$(mktemp /tmp/leadv2-premortem-status-XXXXXX)
_cleanup_tmps+=("$STATUS_FILE")

# Run the python helper — stdout is pure YAML, stderr forwarded to log
_py_stderr_tmp=$(mktemp /tmp/leadv2-premortem-err-XXXXXX)
_cleanup_tmps+=("$_py_stderr_tmp")
yaml_content=$(python3 "$PY_TMP" \
  "$TASK_ID" "$PHASE" "$HANDOFF_DIR" 2>"$_py_stderr_tmp") || {
  log_error "premortem python helper failed"
  cat "$_py_stderr_tmp" >&2
  exit 1
}

# Extract verdict/success_prob from captured YAML via side-channel
# Use a temp Python script file to avoid heredoc+pipe stdin conflict
STATUSPY_TMP=$(mktemp /tmp/leadv2-premortem-statuspy-XXXXXX.py)
_cleanup_tmps+=("$STATUSPY_TMP")
cat > "$STATUSPY_TMP" <<'STATUSPY'
import sys, yaml
content = open(sys.argv[1]).read()
d = yaml.safe_load(content) or {}
premortem = d.get("premortem", d)
verdict = premortem.get("verdict", "")
prob = premortem.get("predicted_outcome_prob", {}) or {}
success_prob = float(prob.get("success", 0.0))
with open(sys.argv[2], "w") as fh:
    fh.write(f"verdict={verdict}\nsuccess_prob={success_prob:.3f}\n")
STATUSPY
YAML_TMP=$(mktemp /tmp/leadv2-premortem-yaml-XXXXXX.yaml)
_cleanup_tmps+=("$YAML_TMP")
printf '%s\n' "$yaml_content" > "$YAML_TMP"
python3 "$STATUSPY_TMP" "$YAML_TMP" "$STATUS_FILE"

verdict=$(grep '^verdict=' "$STATUS_FILE" | cut -d= -f2)
success_prob=$(grep '^success_prob=' "$STATUS_FILE" | cut -d= -f2)

log "Verdict: $verdict (success_prob=$success_prob)"

# Write atomically via helpers (tmp + mv)
_atomic_write_yaml "$OUTPUT_FILE" "$yaml_content" || {
  log_error "atomic write failed for $OUTPUT_FILE"
  exit 1
}
log "Output written (atomic): $OUTPUT_FILE"

# ---------------------------------------------------------------------------
# PREMORTEM_HAIKU_WIRE — dual-path refinement (R7).
# If Haiku script present + output file readable, run it. On escalate_to_opus,
# the caller (deploy/build skill) inspects premortem-haiku.yaml and can
# re-run with Opus. For now, bash-heuristic verdict remains authoritative
# for exit code; Haiku adds a second opinion.
# ---------------------------------------------------------------------------
if [[ -x "${PREMORTEM_HAIKU_SCRIPT:-}" ]]; then
  # Symlink the phase output so haiku script reads expected filename
  ln -sf "premortem-${PHASE}.yaml" "${HANDOFF_DIR}/premortem.yaml" 2>/dev/null || \
    cp "$OUTPUT_FILE" "${HANDOFF_DIR}/premortem.yaml" 2>/dev/null || true
  bash "$PREMORTEM_HAIKU_SCRIPT" --task-id "$TASK_ID" >/dev/null 2>&1 || \
    log_warn "haiku refinement skipped (script failed)"
fi

# Exit code from verdict (bash heuristic remains authoritative)
case "$verdict" in
  skip_recommended)     exit 2 ;;
  proceed_with_caution) exit 1 ;;
  *)                    exit 0 ;;
esac
