#!/usr/bin/env bash
# leadv2-score-compute.sh — Compute per-task quality score.
#
# Usage:
#   leadv2-score-compute.sh <task-id>
#
# Reads per-repo config via _lv2_load_quality_engine_config().
# Config keys used (l_b block):
#   state_path_tmpl    — path template with {task_id} (default: docs/leadv2/tasks/{task_id}/STATE.md)
#   closed_yaml_tmpl   — path template (default: docs/leadv2/closed/{task_id}.yaml)
#   score_output_tmpl  — where to write score.json
#
# Output (stdout, JSON): score.json contents
# Side effect: writes score.json to score_output_tmpl path
#
# Exit codes:
#   0 = ok
#   2 = usage error
#   4 = quality_engine disabled or missing (no-op)

set -euo pipefail

# shellcheck source=./leadv2-helpers.sh
source "$(dirname "$(readlink -f "$0")")/leadv2-helpers.sh"

_lv2_load_quality_engine_config "l_b" || exit 4

# shellcheck source=./leadv2-score-helpers.sh
source "$(dirname "$(readlink -f "$0")")/leadv2-score-helpers.sh"

log()       { printf -- '[leadv2-score-compute] %s\n' "$*" >&2; }
log_warn()  { printf -- '[leadv2-score-compute] WARN: %s\n' "$*" >&2; }

# ── argument parsing ──────────────────────────────────────────────────────────
TASK_ID="${1:-}"
if [[ -z "$TASK_ID" ]]; then
  printf -- 'Usage: leadv2-score-compute.sh <task-id>\n' >&2
  exit 2
fi

# ── path resolution ────────────────────────────────────────────────────────────
STATE_PATH_TMPL="${LV2_QE_L_B_STATE_PATH_TMPL:-docs/leadv2/tasks/{task_id}/STATE.md}"
CLOSED_YAML_TMPL="${LV2_QE_L_B_CLOSED_YAML_TMPL:-docs/leadv2/closed/{task_id}.yaml}"
SCORE_OUTPUT_TMPL="${LV2_QE_L_B_SCORE_OUTPUT_TMPL:-docs/leadv2/tasks/{task_id}/score.json}"

resolve_tmpl() {
  local tmpl="$1" tid="$2"
  local resolved="${tmpl//\{task_id\}/$tid}"
  if [[ "${resolved}" != /* ]]; then
    resolved="${LEADV2_PROJECT_ROOT}/${resolved}"
  fi
  printf -- '%s' "$resolved"
}

STATE_MD="$(resolve_tmpl "$STATE_PATH_TMPL" "$TASK_ID")"
CLOSED_YAML="$(resolve_tmpl "$CLOSED_YAML_TMPL" "$TASK_ID")"
SCORE_OUTPUT="$(resolve_tmpl "$SCORE_OUTPUT_TMPL" "$TASK_ID")"

# Derive handoff dir from task_id
HANDOFF_DIR="${LEADV2_PROJECT_ROOT}/docs/handoff/${TASK_ID}"

# ── determine task class ───────────────────────────────────────────────────────
TASK_CLASS="Standard"
if [[ -f "$STATE_MD" ]]; then
  TC=$(grep -oE 'task_class[[:space:]]*:[[:space:]]*[A-Za-z]+' "$STATE_MD" 2>/dev/null \
    | grep -oE '[A-Za-z]+$' | head -1 || true)
  [[ -n "$TC" ]] && TASK_CLASS="$TC"
elif [[ -f "$CLOSED_YAML" ]]; then
  TC=$(grep -oE 'class[[:space:]]*:[[:space:]]*[A-Za-z]+' "$CLOSED_YAML" 2>/dev/null \
    | grep -oE '[A-Za-z]+$' | head -1 || true)
  [[ -n "$TC" ]] && TASK_CLASS="$TC"
fi

# ── extract penalty events ────────────────────────────────────────────────────
CRITICAL_COUNT=$(extract_critical_count "$STATE_MD" "$HANDOFF_DIR")
REVIEW_ROUND=$(extract_review_round "$STATE_MD" "$HANDOFF_DIR")
RECOVERY_FLAG=$(extract_recovery_flag "$STATE_MD")
HACK_FINDINGS=$(extract_hack_findings "$HANDOFF_DIR")
PREMORTEM_RISK=$(extract_premortem_risk "$HANDOFF_DIR")

# ── penalty weights ────────────────────────────────────────────────────────────
W_CRITICAL=20
W_REVIEW_R2=10
W_RECOVERY=15
W_HACK=5
W_PREMORTEM=3

PENALTY_CRITICAL=$(( CRITICAL_COUNT * W_CRITICAL ))
PENALTY_REVIEW=$(( REVIEW_ROUND * W_REVIEW_R2 ))
PENALTY_RECOVERY=$(( RECOVERY_FLAG * W_RECOVERY ))
PENALTY_HACK=$(( HACK_FINDINGS * W_HACK ))
PENALTY_PREMORTEM=$(( PREMORTEM_RISK * W_PREMORTEM ))

TOTAL_PENALTY=$(( PENALTY_CRITICAL + PENALTY_REVIEW + PENALTY_RECOVERY + PENALTY_HACK + PENALTY_PREMORTEM ))
SCORE=$(( 100 - TOTAL_PENALTY ))
[[ $SCORE -lt 0 ]] && SCORE=0

COMPUTED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# ── build JSON ────────────────────────────────────────────────────────────────
SCORE_JSON=$(jq -n \
  --arg task_id        "$TASK_ID" \
  --arg task_class     "$TASK_CLASS" \
  --arg computed_at    "$COMPUTED_AT" \
  --argjson score      "$SCORE" \
  --argjson c_count    "$CRITICAL_COUNT" \
  --argjson c_pen      "$PENALTY_CRITICAL" \
  --argjson c_w        "$W_CRITICAL" \
  --argjson rr_flag    "$REVIEW_ROUND" \
  --argjson rr_pen     "$PENALTY_REVIEW" \
  --argjson rr_w       "$W_REVIEW_R2" \
  --argjson rv_flag    "$RECOVERY_FLAG" \
  --argjson rv_pen     "$PENALTY_RECOVERY" \
  --argjson rv_w       "$W_RECOVERY" \
  --argjson hk_count   "$HACK_FINDINGS" \
  --argjson hk_pen     "$PENALTY_HACK" \
  --argjson hk_w       "$W_HACK" \
  --argjson pm_flag    "$PREMORTEM_RISK" \
  --argjson pm_pen     "$PENALTY_PREMORTEM" \
  --argjson pm_w       "$W_PREMORTEM" \
  --argjson total_pen  "$TOTAL_PENALTY" \
  '{
    task_id:    $task_id,
    task_class: $task_class,
    computed_at: $computed_at,
    score:      $score,
    penalties: [
      { event: "critical_in_deploy_gate", weight: $c_w, count: $c_count, total: $c_pen },
      { event: "r2_review_round",         weight: $rr_w, count: $rr_flag, total: $rr_pen },
      { event: "recovery_triggered",      weight: $rv_w, count: $rv_flag, total: $rv_pen },
      { event: "hack_detection_finding",  weight: $hk_w, count: $hk_count, total: $hk_pen },
      { event: "premortem_high_risk",     weight: $pm_w, count: $pm_flag, total: $pm_pen }
    ],
    evidence: {
      critical_in_deploy_gate: {
        source: "STATE.md grep severity:critical + handoff critic.summary.md",
        details: ("found " + ($c_count|tostring) + " critical severity markers")
      },
      r2_review_round: {
        source: "STATE.md review_round key + handoff r2-*.md files",
        details: (if $rr_flag == 1 then "review went to round >= 2" else "single review round" end)
      },
      recovery_triggered: {
        source: "STATE.md recovery.triggered",
        details: (if $rv_flag == 1 then "recovery was triggered" else "no recovery triggered" end)
      },
      hack_detection_finding: {
        source: "handoff hack-detection.full.md [FINDING] markers",
        details: ("found " + ($hk_count|tostring) + " hack findings")
      },
      premortem_high_risk: {
        source: "handoff premortem.summary.md risk_score",
        details: (if $pm_flag == 1 then "premortem risk_score >= 7" else "risk score below 7" end)
      }
    },
    extensions: {
      cache_hit_ratio: null,
      ultrathink_share: null,
      scope_clusters: null
    },
    total_penalty: $total_pen
  }')

# ── write score.json ───────────────────────────────────────────────────────────
mkdir -p "$(dirname "$SCORE_OUTPUT")"
printf -- '%s\n' "$SCORE_JSON" > "$SCORE_OUTPUT"
log "score.json written: $SCORE_OUTPUT (score=$SCORE)"

# ── emit to stdout ─────────────────────────────────────────────────────────────
printf -- '%s\n' "$SCORE_JSON"
