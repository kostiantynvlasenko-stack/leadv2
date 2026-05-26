#!/usr/bin/env bash
# leadv2-scope-check.sh — Detect scope creep by clustering changed files.
#
# Usage:
#   leadv2-scope-check.sh <task-id> [--base <sha>] [--head <sha>]
#
# Reads per-repo config via _lv2_load_quality_engine_config().
# Config keys used (l_e block):
#   cluster_map           — dict of cluster_name → path_prefix (YAML object)
#   warning_cluster_count — warn if >= this many distinct clusters touched (default: 4)
#
# Git diff strategy (in order):
#   1. --base and --head args: use directly
#   2. STATE.md phase_4_start_sha: diff phase_4_start_sha..HEAD
#   3. closed YAML commit field: use as head, search git log --grep for task start
#   4. Fallback: git log --all --grep="<task-id>" to find first commit
#
# Output (stdout, JSON):
#   { "task_id": "X", "phase_4_start": "abc", "close_commit": "def",
#     "files_changed": N, "clusters": {"web": 5, ...}, "cluster_count": 4,
#     "warning": "scope_creep" | null,
#     "recommendation": "Split this task into per-cluster sub-tasks next time" }
#
# Side effect: merges extensions.scope_clusters into score.json
#
# Exit codes:
#   0 = ok (including no warning)
#   1 = ok + scope_creep warning
#   2 = usage error
#   3 = git error
#   4 = disabled or cluster_map missing

set -euo pipefail

# shellcheck source=./leadv2-helpers.sh
source "$(dirname "$(readlink -f "$0")")/leadv2-helpers.sh"

_lv2_load_quality_engine_config "l_e" || exit 4

log()       { printf -- '[leadv2-scope-check] %s\n' "$*" >&2; }
log_warn()  { printf -- '[leadv2-scope-check] WARN: %s\n' "$*" >&2; }
log_error() { printf -- '[leadv2-scope-check] ERROR: %s\n' "$*" >&2; }

# ── argument parsing ──────────────────────────────────────────────────────────
TASK_ID=""
BASE_SHA=""
HEAD_SHA=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base) BASE_SHA="$2"; shift 2 ;;
    --head) HEAD_SHA="$2"; shift 2 ;;
    -h|--help)
      printf -- 'Usage: leadv2-scope-check.sh <task-id> [--base <sha>] [--head <sha>]\n' >&2
      exit 0
      ;;
    -*)
      log_error "unknown flag: $1"; exit 2
      ;;
    *)
      if [[ -z "$TASK_ID" ]]; then
        TASK_ID="$1"
      else
        log_error "unexpected argument: $1"; exit 2
      fi
      shift
      ;;
  esac
done

if [[ -z "$TASK_ID" ]]; then
  printf -- 'Usage: leadv2-scope-check.sh <task-id> [--base <sha>] [--head <sha>]\n' >&2
  exit 2
fi

# ── config ────────────────────────────────────────────────────────────────────
WARNING_CLUSTER_COUNT="${LV2_QE_L_E_WARNING_CLUSTER_COUNT:-4}"
CLUSTER_MAP_JSON="${LV2_QE_L_E_CLUSTER_MAP_JSON:-}"

# Fail if no cluster map
if [[ -z "$CLUSTER_MAP_JSON" ]]; then
  log_warn "no cluster_map configured in quality-engine.yaml l_e block — exit 4"
  exit 4
fi

# Paths
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

# ── resolve git refs ──────────────────────────────────────────────────────────
cd "$LEADV2_PROJECT_ROOT"

if ! git rev-parse --git-dir &>/dev/null; then
  log_error "not a git repository: $LEADV2_PROJECT_ROOT"
  exit 3
fi

# HEAD ref
if [[ -z "$HEAD_SHA" ]]; then
  # Try from closed YAML
  if [[ -f "$CLOSED_YAML" ]]; then
    HEAD_SHA=$(grep -oE 'commit[[:space:]]*:[[:space:]]*[0-9a-f]{7,40}' "$CLOSED_YAML" 2>/dev/null \
      | grep -oE '[0-9a-f]{7,40}$' | head -1 || true)
  fi
  [[ -z "$HEAD_SHA" ]] && HEAD_SHA=$(git rev-parse HEAD 2>/dev/null || true)
fi

# BASE ref (phase_4_start_sha)
if [[ -z "$BASE_SHA" ]]; then
  if [[ -f "$STATE_MD" ]]; then
    BASE_SHA=$(grep -oE 'phase_4_start_sha[[:space:]]*:[[:space:]]*[0-9a-f]{7,40}' "$STATE_MD" 2>/dev/null \
      | grep -oE '[0-9a-f]{7,40}$' | head -1 || true)
  fi

  # Fallback: find first commit for this task via git log --grep
  if [[ -z "$BASE_SHA" ]]; then
    log_warn "phase_4_start_sha not in STATE.md — falling back to git log --grep='$TASK_ID'"
    BASE_SHA=$(git log --all --grep="$TASK_ID" --oneline 2>/dev/null \
      | tail -1 | awk '{print $1}' || true)
  fi

  # Last resort: parent of HEAD
  if [[ -z "$BASE_SHA" ]]; then
    BASE_SHA=$(git rev-parse HEAD~1 2>/dev/null || git rev-parse HEAD 2>/dev/null || true)
  fi
fi

log "diff range: ${BASE_SHA}..${HEAD_SHA}"

# ── get changed files ─────────────────────────────────────────────────────────
DIFF_FILES=""
if [[ -n "$BASE_SHA" ]] && [[ -n "$HEAD_SHA" ]]; then
  DIFF_FILES=$(git diff --name-only "${BASE_SHA}..${HEAD_SHA}" 2>/dev/null || true)
fi

if [[ -z "$DIFF_FILES" ]]; then
  log_warn "no changed files found in diff range"
  DIFF_FILES=""
fi

# ── cluster and emit ──────────────────────────────────────────────────────────
python3 - "$TASK_ID" "$BASE_SHA" "$HEAD_SHA" \
          "$WARNING_CLUSTER_COUNT" "$SCORE_OUTPUT" \
          <<PYEOF
import sys
import os
import json

task_id               = sys.argv[1]
base_sha              = sys.argv[2]
head_sha              = sys.argv[3]
warning_cluster_count = int(sys.argv[4])
score_output          = sys.argv[5]

diff_files_raw = r"""${DIFF_FILES}"""
files = [f.strip() for f in diff_files_raw.splitlines() if f.strip()]

# Parse cluster map from JSON env var
cluster_map_json = r"""${CLUSTER_MAP_JSON}"""
try:
    cluster_map = json.loads(cluster_map_json)
except json.JSONDecodeError:
    cluster_map = {}

def classify_file(path: str, cluster_map: dict) -> str:
    """Return cluster name for a file path, or 'other'."""
    for cluster_name, prefix in cluster_map.items():
        # Normalize: ensure prefix ends with /
        p = prefix if prefix.endswith("/") else prefix + "/"
        if path.startswith(p) or path == prefix.rstrip("/"):
            return cluster_name
    return "other"

# Count files per cluster
cluster_counts: dict[str, int] = {}
for f in files:
    cluster = classify_file(f, cluster_map)
    cluster_counts[cluster] = cluster_counts.get(cluster, 0) + 1

cluster_count = len(cluster_counts)
scope_warning = "scope_creep" if cluster_count >= warning_cluster_count else None
recommendation = (
    "Split this task into per-cluster sub-tasks next time"
    if scope_warning else None
)

result = {
    "task_id":        task_id,
    "phase_4_start":  base_sha,
    "close_commit":   head_sha,
    "files_changed":  len(files),
    "clusters":       cluster_counts,
    "cluster_count":  cluster_count,
    "warning":        scope_warning,
    "recommendation": recommendation
}
print(json.dumps(result))

# Merge into score.json
if os.path.isfile(score_output):
    try:
        with open(score_output) as fh:
            score_data = json.load(fh)
        exts = score_data.setdefault("extensions", {})
        exts["scope_clusters"] = cluster_count
        exts["scope_warning"]  = scope_warning
        with open(score_output, "w") as fh:
            json.dump(score_data, fh)
        print(f"[leadv2-scope-check] merged scope_clusters={cluster_count} into {score_output}", file=sys.stderr)
    except Exception as e:
        print(f"[leadv2-scope-check] WARN: could not merge into score.json: {e}", file=sys.stderr)

sys.exit(1 if scope_warning else 0)
PYEOF

EXIT_CODE=$?
exit $EXIT_CODE
