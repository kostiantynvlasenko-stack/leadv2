#!/usr/bin/env bash
# leadv2-premortem-haiku.sh — Haiku refinement of bash heuristic premortem.
#
# Usage: leadv2-premortem-haiku.sh --task-id <id>
# Reads: docs/handoff/<id>/premortem.yaml (from leadv2-premortem.sh)
# Writes: docs/handoff/<id>/premortem-haiku.yaml
#
# Produces verdict ∈ {proceed, proceed_with_caution, skip_recommended, escalate_to_opus}.
# Caller inspects escalate and may re-run with Opus.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=leadv2-helpers.sh
source "${SCRIPT_DIR}/leadv2-helpers.sh" || { echo "FATAL: cannot source leadv2-helpers.sh" >&2; exit 1; }

TASK_ID=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --task-id) TASK_ID="$2"; shift 2 ;;
    -h|--help) grep '^# ' "$0" | sed 's/^# //'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
[[ -z "$TASK_ID" ]] && { echo "--task-id required" >&2; exit 2; }

IN="docs/handoff/${TASK_ID}/premortem.yaml"
OUT="docs/handoff/${TASK_ID}/premortem-haiku.yaml"

if [[ ! -f "$IN" ]]; then
  echo "WARN: premortem.yaml missing — escalate to Opus" >&2
  _fallback='verdict: escalate_to_opus
confidence: 0.0
reasons:
  - premortem_missing
escalate_reason: confidence_low'
  _atomic_write_yaml "$OUT" "$_fallback"
  exit 0
fi

haiku_yaml=$(python3 - "$IN" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1])) or {}

classification = d.get("classification", "Standard")
probs = d.get("probability_table", {}) or {}
build_ok = float(probs.get("build_success", 0.7))
deploy_ok = float(probs.get("deploy_clean", 0.7))
block_r = float(probs.get("block_risk", 0.3))
rollback_r = float(probs.get("rollback_probability", 0.2))
risks = d.get("risk_factors_detected", []) or []

combined = build_ok * deploy_ok * (1 - block_r) * (1 - rollback_r)

if classification == "Heavy":
    verdict = "escalate_to_opus"
    confidence = 0.5
    er = "class_heavy"
elif combined >= 0.55:
    verdict = "proceed"
    confidence = 0.85
    er = None
elif combined >= 0.35:
    verdict = "proceed_with_caution"
    confidence = 0.8
    er = None
elif combined >= 0.20:
    verdict = "escalate_to_opus"
    confidence = 0.65
    er = "confidence_low"
else:
    verdict = "skip_recommended"
    confidence = 0.85
    er = None

out = {
    "verdict": verdict,
    "confidence": confidence,
    "adjusted_probabilities": {
        "build_success": build_ok,
        "deploy_clean": deploy_ok,
        "block_risk": block_r,
        "rollback_probability": rollback_r,
    },
    "reasons": [f"combined={combined:.2f}", f"risks={len(risks)}"],
    "escalate_reason": er,
    "path": "haiku_heuristic",
}
print(yaml.safe_dump(out, sort_keys=False), end="")
PY
)
_atomic_write_yaml "$OUT" "$haiku_yaml"
