#!/usr/bin/env bash
# leadv2-llm-judge.sh — Assemble compact deploy packet and invoke LLM-judge.
# Called during Phase 6 Deploy, after premortem, before auto-Gate 2 check.
#
# Usage:
#   leadv2-llm-judge.sh --task-id <id> [--class <class>] [--project-root <path>]
#
# Reads:
#   docs/handoff/<task-id>/context.yaml
#   docs/handoff/<task-id>/coverage.yaml          (optional)
#   docs/handoff/<task-id>/premortem-deploy.yaml  (optional)
#   docs/handoff/<task-id>/hack-detection.yaml    (optional)
#   docs/handoff/<task-id>/review.yaml            (optional)
#   docs/handoff/<task-id>/prior-art.yaml         (optional)
#   docs/handoff/<task-id>/negative-memory.yaml   (optional)
#
# Writes:
#   /tmp/deploy-packet-<task-id>.yaml   (temp — for LLM prompt)
#   docs/handoff/<task-id>/llm-judge.yaml  (durable output)
#
# Exit codes:
#   0 = verdict go or go-with-caveats (or skipped)
#   1 = verdict no-go
#   2 = hard cost ceiling hit — caller should treat as go-with-caveats and log

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/leadv2-temp.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
readonly SCRIPT_DIR PROJECT_ROOT

log()       { printf '[leadv2-llm-judge] %s\n' "$*" >&2; }
log_warn()  { printf '[leadv2-llm-judge] WARN: %s\n' "$*" >&2; }
log_error() { printf '[leadv2-llm-judge] ERROR: %s\n' "$*" >&2; }

usage() {
  cat >&2 <<'EOF'
Usage: leadv2-llm-judge.sh --task-id <id>
                           [--class <Light|Standard|Heavy|Strategic>]
                           [--project-root <path>]
EOF
  exit 1
}

TASK_ID=""
TASK_CLASS="Standard"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --task-id)      TASK_ID="$2";      shift 2 ;;
    --class)        TASK_CLASS="$2";   shift 2 ;;
    --project-root) PROJECT_ROOT="$2"; shift 2 ;;
    -h|--help)      usage ;;
    *) log_error "unknown arg: $1"; usage ;;
  esac
done

[[ -z "$TASK_ID" ]] && { log_error "--task-id required"; usage; }

HANDOFF_DIR="${PROJECT_ROOT}/docs/handoff/${TASK_ID}"
OUTPUT_FILE="${HANDOFF_DIR}/llm-judge.yaml"
PACKET_FILE="/tmp/deploy-packet-${TASK_ID}.yaml"

[[ ! -d "$HANDOFF_DIR" ]] && { log_error "handoff dir not found: $HANDOFF_DIR"; exit 1; }

# Source helpers for _atomic_write_yaml and leadv2_validate_yaml (PO-057).
# shellcheck source=leadv2-helpers.sh
source "${SCRIPT_DIR}/leadv2-helpers.sh" 2>/dev/null || true

# Helper: validate + atomic re-flush a YAML file (write-tmp -> mv).
# Called after each python3 write to OUTPUT_FILE.
_judge_atomic_flush() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  if declare -f leadv2_validate_yaml >/dev/null 2>&1; then
    if ! leadv2_validate_yaml "$file" >/dev/null 2>&1; then
      log_error "YAML validation failed after write: $file"
      return 1
    fi
    local _content _tmp
    _content=$(cat "$file")
    _tmp="$(mktemp "$(dirname "$file")/.judge_XXXXXX.yaml")"
    printf -- '%s\n' "$_content" > "$_tmp"
    sync "$_tmp" 2>/dev/null || true
    mv -f "$_tmp" "$file"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Dual-path: Haiku first for Light/Standard. Escalate to Opus only if needed.
# Configured via .claude/ref/leadv2-routing.yaml (dual_path.llm_judge).
# ---------------------------------------------------------------------------
HAIKU_SCRIPT="${SCRIPT_DIR}/leadv2-llm-judge-haiku.sh"
if [[ "$TASK_CLASS" =~ ^(Light|Standard)$ ]] && [[ -x "$HAIKU_SCRIPT" ]]; then
  log "dual-path: trying Haiku first for class=${TASK_CLASS}"
  # Haiku needs the packet assembled; produce a minimal packet from coverage + premortem files
  if [[ -f "${HANDOFF_DIR}/deploy-packet.yaml" ]] || [[ -f "/tmp/deploy-packet-${TASK_ID}.yaml" ]]; then
    PACKET_SRC="${HANDOFF_DIR}/deploy-packet.yaml"
    [[ ! -f "$PACKET_SRC" ]] && PACKET_SRC="/tmp/deploy-packet-${TASK_ID}.yaml"
    cp "$PACKET_SRC" "${HANDOFF_DIR}/deploy-packet.yaml" 2>/dev/null || true
    if bash "$HAIKU_SCRIPT" --task-id "$TASK_ID" >/dev/null 2>&1; then
      HAIKU_OUT="${HANDOFF_DIR}/llm-judge-haiku.yaml"
      HVERDICT=$(python3 -c "import yaml,sys; d=yaml.safe_load(open('$HAIKU_OUT')); print(d.get('verdict',''))" 2>/dev/null || echo "")
      if [[ "$HVERDICT" == "go" ]] || [[ "$HVERDICT" == "no_go" ]]; then
        log "dual-path: Haiku resolved (verdict=${HVERDICT}) — skipping Opus"
        cp "$HAIKU_OUT" "$OUTPUT_FILE"
        exit 0
      fi
      log "dual-path: Haiku escalated (verdict=${HVERDICT:-unknown}) — continuing to Opus"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Step 1: Assemble deploy packet via Python helper
# ---------------------------------------------------------------------------
PY_TMP=$(lv2_mktemp_file "leadv2-judge-packet" "py")
trap 'rm -f "$PY_TMP" "$PACKET_FILE"' EXIT

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

task_id     = sys.argv[1]
task_class  = sys.argv[2]
handoff_dir = Path(sys.argv[3])
packet_file = Path(sys.argv[4])

def safe_load(p: Path) -> dict | list | None:
    if not p.is_file():
        return None
    try:
        return yaml.safe_load(p.read_text()) or None
    except Exception:
        return None

ctx_raw    = safe_load(handoff_dir / "context.yaml")
cov_raw    = safe_load(handoff_dir / "coverage.yaml")
pre_raw    = safe_load(handoff_dir / "premortem-deploy.yaml")
hack_raw   = safe_load(handoff_dir / "hack-detection.yaml")
review_raw = safe_load(handoff_dir / "review.yaml")
prior_raw  = safe_load(handoff_dir / "prior-art.yaml")
neg_raw    = safe_load(handoff_dir / "negative-memory.yaml")

# Load operator priors summary (≤300 tokens in packet)
from pathlib import Path as _Path
_priors_path = _Path(os.path.join(os.environ.get("PROJECT_ROOT", str(handoff_dir.parent.parent)), "docs/leadv2-priors.yaml"))
_priors_raw = safe_load(_priors_path) if _priors_path else None
priors_summary: dict = {}
if isinstance(_priors_raw, dict):
    fqp = _priors_raw.get("fix_quality_priors", {}) or {}
    rp  = _priors_raw.get("risk_priors", {}) or {}
    ab  = _priors_raw.get("active_blocks", {}) or {}

    # DEFENSIVE READ (Risk 5): fields are "insufficient_data" until 10+ history entries.
    # Normalize sentinel string and None to None so the packet omits them cleanly.
    def _safe_prior(d: dict, key: str):
        val = d.get(key)
        if val in (None, "insufficient_data", ""):
            return None
        return val

    priors_summary = {
        "band_aid_ratio_30d":           _safe_prior(fqp, "band_aid_ratio_30d"),
        "induced_regression_rate_30d":  _safe_prior(rp, "induced_regression_rate_30d"),
        "active_nm_ids": (ab.get("negative_memory_ids") or [])[:5],
        "most_recent_regression":       _safe_prior(rp, "most_recent_regression"),
    }
    # Drop None keys from packet — reduces token count and avoids judge confusion
    priors_summary = {k: v for k, v in priors_summary.items() if v is not None}

ctx = ctx_raw if isinstance(ctx_raw, dict) else {}
task_ctx  = ctx.get("task", {})
fp        = ctx.get("graph_footprint", {}) or {}
dg        = ctx.get("deploy_gate", {}) or {}
off_lims  = ctx.get("off_limits", []) or []

# Graph footprint
footprint = {
    "risk_score":   fp.get("risk_score", "unknown"),
    "change_kind":  fp.get("change_kind", "unknown"),
    "files_touched": fp.get("files_touched", 0),
}

# Coverage
coverage: dict = {}
if isinstance(cov_raw, dict):
    cov_inner = cov_raw.get("coverage", cov_raw)
    coverage = {
        "new_code_pct": cov_inner.get("new_code_pct", "unknown"),
        "passed":       cov_inner.get("passed", True),
    }

# Offlimits result
offlimits_val = dg.get("offlimits_result", {}) or {}
offlimits_str = "clean"
if isinstance(offlimits_val, dict):
    rc = offlimits_val.get("exit_code", 0)
    if rc != 0:
        offlimits_str = f"block_rc{rc}"
elif dg.get("offlimits_exit", 0) != 0:
    offlimits_str = f"block_rc{dg.get('offlimits_exit', 0)}"

# Premortem
premortem_out: dict = {}
if isinstance(pre_raw, dict):
    pre = pre_raw.get("premortem", pre_raw)
    triggered = [
        f.get("factor", "") for f in (pre.get("risk_factors") or [])
        if f.get("triggered")
    ]
    premortem_out = {
        "success_prob": pre.get("predicted_outcome_prob", {}).get("success", "unknown"),
        "verdict":      pre.get("verdict", "unknown"),
        "top_risk_factors": triggered[:5],
    }

# Hack findings
hack_out: dict = {"info": 0, "warn": 0, "block": 0}
if isinstance(hack_raw, dict):
    findings = hack_raw.get("findings", {}) or {}
    if isinstance(findings, dict):
        hack_out["info"]  = int(findings.get("info", 0))
        hack_out["warn"]  = int(findings.get("warn", 0))
        hack_out["block"] = int(findings.get("block", 0))
    elif isinstance(findings, list):
        for f in findings:
            sev = str(f.get("severity", "")).lower()
            if sev in hack_out:
                hack_out[sev] += 1

# Diff stats
diff_out: dict = {}
diff_stats = dg.get("diff_stats", {}) or {}
if diff_stats:
    diff_out = {
        "files_changed": diff_stats.get("files_changed", 0),
        "lines_added":   diff_stats.get("lines_added", 0),
        "lines_removed": diff_stats.get("lines_removed", 0),
    }

# Review
review_rounds     = 0
review_remaining  = 0
if isinstance(review_raw, dict):
    rev = review_raw.get("reviews", review_raw)
    review_rounds    = int(rev.get("rounds", 0))
    review_remaining = int(rev.get("findings_remaining", 0))

# Prior art summary
prior_summary = ""
prior_list = prior_raw if isinstance(prior_raw, list) else []
if prior_list:
    outcomes = [str(p.get("outcome", "?")) for p in prior_list[:3]]
    s = sum(1 for o in outcomes if o.lower() == "success")
    r = sum(1 for o in outcomes if o.lower() == "rollback")
    prior_summary = f"{len(outcomes)} similar past; {s} success, {r} rollback"
    if r > 0:
        causes = [p.get("rollback_cause", "") for p in prior_list[:3] if str(p.get("outcome","")).lower()=="rollback"]
        if any(causes):
            prior_summary += f" ({causes[0][:50]})"

# Negative memory
neg_hits: list = []
if isinstance(neg_raw, list):
    neg_hits = [str(n.get("pattern", "?")) for n in neg_raw[:3]]
elif isinstance(neg_raw, dict):
    neg_hits = [str(n.get("pattern", "?")) for n in (neg_raw.get("matches") or [])[:3]]

# Assemble packet (strip Nones and empty dicts for token density)
packet: dict = {"deploy_packet": {
    "task_id":         task_id,
    "classification":  task_class,
    "graph_footprint": footprint,
}}

if coverage:
    packet["deploy_packet"]["coverage"] = coverage
packet["deploy_packet"]["offlimits"] = offlimits_str
if premortem_out:
    packet["deploy_packet"]["premortem"] = premortem_out
packet["deploy_packet"]["hack_findings"] = hack_out
if diff_out:
    packet["deploy_packet"]["diff_stats"] = diff_out
packet["deploy_packet"]["review_rounds"] = review_rounds
packet["deploy_packet"]["review_findings_remaining"] = review_remaining
if prior_summary:
    packet["deploy_packet"]["rag_prior_outcome_summary"] = prior_summary
if neg_hits:
    packet["deploy_packet"]["negative_memory_hits"] = neg_hits
else:
    packet["deploy_packet"]["negative_memory_hits"] = []

if priors_summary:
    packet["deploy_packet"]["operator_priors"] = priors_summary

packet_file.parent.mkdir(parents=True, exist_ok=True)
with open(packet_file, "w") as fh:
    yaml.dump(packet, fh, default_flow_style=False, sort_keys=False, allow_unicode=True)

print(f"packet_written={packet_file}")
# Emit skip signal fields for bash to consume
offlimits_clean = offlimits_str == "clean"
premortem_proceed = (premortem_out.get("verdict", "") == "proceed") if premortem_out else True
is_light = task_class.lower() == "light"
hack_block = hack_out.get("block", 0) == 0
can_skip = is_light and offlimits_clean and premortem_proceed and hack_block
print(f"can_skip={'true' if can_skip else 'false'}")
print(f"offlimits_clean={'true' if offlimits_clean else 'false'}")
print(f"premortem_verdict={premortem_out.get('verdict', 'unknown') if premortem_out else 'unknown'}")
PYEOF

# Run packet assembly
packet_result=$(python3 "$PY_TMP" \
  "$TASK_ID" "$TASK_CLASS" "$HANDOFF_DIR" "$PACKET_FILE" 2>&1) || {
  log_error "Deploy packet assembly failed"
  printf '%s\n' "$packet_result" >&2
  exit 1
}

can_skip=$(printf '%s\n' "$packet_result" | grep '^can_skip=' | cut -d= -f2)
premortem_verdict=$(printf '%s\n' "$packet_result" | grep '^premortem_verdict=' | cut -d= -f2)

log "Packet assembled: $PACKET_FILE"
log "  can_skip=$can_skip premortem_verdict=$premortem_verdict class=$TASK_CLASS"

# ---------------------------------------------------------------------------
# Step 2: Skip gate for Light+clean
# ---------------------------------------------------------------------------
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
if [[ "$can_skip" == "true" ]]; then
  log "Skipping LLM-judge: Light+clean (all signals clean, no Opus needed)"
  python3 - "$OUTPUT_FILE" "$TASK_ID" "$NOW" <<'PY'
import sys, yaml
from pathlib import Path
output_file = Path(sys.argv[1])
task_id = sys.argv[2]
now = sys.argv[3]
output_file.parent.mkdir(parents=True, exist_ok=True)
data = {"llm_judge": {
    "task_id": task_id,
    "judged_at": now,
    "model_used": "skipped",
    "verdict": "go",
    "overall_risk": 2.0,
    "confidence": 0.95,
    "axes": {
        "reversibility": 9,
        "blast_radius": 9,
        "durability_of_fix": 8,
        "test_coverage": 8,
        "context_consensus": 10,
    },
    "blockers": [],
    "caveats": [],
    "reasoning": "Light class with all checks clean — judge skipped (predictable go).",
    "skipped": True,
    "skip_reason": "Light+clean: offlimits clean, premortem proceed, hack block=0",
}}
with open(output_file, "w") as fh:
    yaml.dump(data, fh, default_flow_style=False, sort_keys=False, allow_unicode=True)
PY
  _judge_atomic_flush "$OUTPUT_FILE" || exit 1
  log "Written: $OUTPUT_FILE (skipped)"
  exit 0
fi

# ---------------------------------------------------------------------------
# Step 3: Check cost ceiling via router
# ---------------------------------------------------------------------------
ROUTER_SCRIPT="${SCRIPT_DIR}/leadv2-router.sh"
ceiling_status="ok"
model="opus"

if [[ -f "$ROUTER_SCRIPT" ]]; then
  router_signals=$(python3 -c "
import json, sys, yaml
from pathlib import Path
p = Path(sys.argv[1])
pre_raw = yaml.safe_load(p.read_text()) if p.is_file() else {}
pre = pre_raw.get('premortem', pre_raw) if isinstance(pre_raw, dict) else {}
prob = pre.get('predicted_outcome_prob', {}).get('success', 0.8) if isinstance(pre, dict) else 0.8
print(json.dumps({'premortem_success': prob}))
" "${HANDOFF_DIR}/premortem-deploy.yaml" 2>/dev/null || echo '{}')

  router_out=$(bash "$ROUTER_SCRIPT" \
    --phase deploy --step llm_judge \
    --task-id "$TASK_ID" --class "$TASK_CLASS" \
    --signals "$router_signals" 2>/dev/null) || true

  if [[ -n "$router_out" ]]; then
    model=$(printf '%s\n' "$router_out" | grep '^model=' | cut -d= -f2 || echo "opus")
    ceiling_status=$(printf '%s\n' "$router_out" | grep '^ceiling_status=' | cut -d= -f2 || echo "ok")
  fi
fi

# ---------------------------------------------------------------------------
# Hard ceiling: skip judge, write synthetic go-with-caveats
# ---------------------------------------------------------------------------
if [[ "$ceiling_status" == "hard_stop_95pct" ]]; then
  log_warn "Cost ceiling reached — LLM-judge skipped (treating as go-with-caveats)"
  python3 - "$OUTPUT_FILE" "$TASK_ID" "$NOW" "$model" <<'PY'
import sys, yaml
from pathlib import Path
output_file = Path(sys.argv[1])
task_id, now, model = sys.argv[2], sys.argv[3], sys.argv[4]
output_file.parent.mkdir(parents=True, exist_ok=True)
data = {"llm_judge": {
    "task_id": task_id,
    "judged_at": now,
    "model_used": model,
    "verdict": "go-with-caveats",
    "overall_risk": 5.0,
    "confidence": 0.5,
    "axes": {},
    "blockers": [],
    "caveats": ["LLM-judge skipped due to cost ceiling — review manually"],
    "reasoning": "Cost ceiling reached; synthetic go-with-caveats assigned.",
    "skipped": True,
    "skip_reason": "cost_ceiling_hard_stop",
}}
with open(output_file, "w") as fh:
    yaml.dump(data, fh, default_flow_style=False, sort_keys=False, allow_unicode=True)
PY
  _judge_atomic_flush "$OUTPUT_FILE" || exit 1
  log "Written: $OUTPUT_FILE (ceiling skip)"
  exit 2
fi

# ---------------------------------------------------------------------------
# Step 4: The actual LLM-judge call is delegated to the lead (main session)
# because only lead has Agent tool access. This script outputs the packet path
# and judge prompt path so lead can spawn the agent.
# ---------------------------------------------------------------------------
# Write the judge prompt to /tmp for lead to consume
PROMPT_FILE="/tmp/leadv2-judge-prompt-${TASK_ID}.md"
cat > "$PROMPT_FILE" <<PROMPT_EOF
You are the LLM-judge for a software deploy gate. Read the deploy packet below.
Score on 5 axes (each 0-10, where 10=best/safest):

  reversibility:     Can this change be rolled back cleanly? (10=easy rollback, 0=irreversible)
  blast_radius:      How contained is the impact if something goes wrong? (10=very contained)
  durability_of_fix: Is this a root-cause fix or a workaround? (10=durable root fix)
  test_coverage:     Is the changed code adequately tested? (10=full coverage)
  context_consensus: Do offlimits/premortem/hack signals agree this is safe? (10=all clean)

Overall risk = weighted sum: 0.25*reversibility + 0.25*blast_radius + 0.20*durability_of_fix + 0.15*test_coverage + 0.15*context_consensus
Scale: 0-10 where 10=zero risk, 0=catastrophic risk.

Verdict rules:
  overall_risk >= 7.0 → go
  overall_risk 5.0-6.9 → go-with-caveats (list specific caveats)
  overall_risk < 5.0 → no-go (list specific blocker + recommended fix)

If no-go: specify the SINGLE most important blocker and ONE concrete action to resolve it.
If go-with-caveats: list caveats briefly (10 words max each).
If go: state confidence as a float 0-1.

Return ONLY valid YAML in this exact schema (no markdown fences, no extra keys):
verdict: go | no-go | go-with-caveats
overall_risk: <float>
confidence: <float>
axes:
  reversibility: <int>
  blast_radius: <int>
  durability_of_fix: <int>
  test_coverage: <int>
  context_consensus: <int>
blockers: []
caveats: []
reasoning: <one sentence max 25 words>

Deploy packet:
$(cat "$PACKET_FILE")
PROMPT_EOF

log "LLM-judge prompt written: $PROMPT_FILE"
log "Deploy packet: $PACKET_FILE"
log "Model: $model"
log ""
log "NEXT: Lead spawns Agent(architect, $model) with prompt from $PROMPT_FILE"
log "NEXT: Parse response → write $OUTPUT_FILE"
log "NEXT: Run leadv2-llm-judge-parse.sh --task-id $TASK_ID --response-file <opus_out>"

# Output for lead to consume
printf 'judge_prompt_file=%s\n' "$PROMPT_FILE"
printf 'packet_file=%s\n' "$PACKET_FILE"
printf 'output_file=%s\n' "$OUTPUT_FILE"
printf 'model=%s\n' "$model"
printf 'task_id=%s\n' "$TASK_ID"

exit 0
