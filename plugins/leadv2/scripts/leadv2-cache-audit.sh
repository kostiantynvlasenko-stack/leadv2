#!/usr/bin/env bash
# leadv2-cache-audit.sh — Cache hit rate audit per task from burn DB.
#
# Usage:
#   leadv2-cache-audit.sh <task-id>
#
# Reads per-repo config via _lv2_load_quality_engine_config().
# Config keys used (l_c block):
#   burn_db_path                          — path to ~/.claude/burn/history.db
#   project_name_filter                   — SQL filter on sessions.project_name
#   warning.cache_hit_low_threshold       — warn if ratio < this (default 0.20)
#   warning.heavy_prompt_threshold_tokens — warn if prompt_tokens > this (default 50000)
#
# Burn DB schema (verified 2026-05-26):
#   sessions: session_id, project_name, project_dir, start_ts, last_asst_ts,
#             cc_total, cr_total, input_total, output_total, ...
#   turn_events: id, session_id, ts, cc, cr, input, output, model, tools_json
#
# Note: ~/.claude/burn/history.db is local-dev only. On VPS where it is absent,
# this script exits 4 with a stderr warning and leaves score.json untouched.
# This is correct behavior — cache telemetry is only meaningful from dev sessions.
#
# Task → session attribution heuristic:
#   Match sessions WHERE project_name = <filter> AND last_asst_ts BETWEEN started_at AND closed_at
#   If project_dir is available in DB, also filter by project_dir to avoid cross-repo overlap.
#
# Output (stdout, JSON):
#   { "task_id": "X", "task_window": {...}, "sessions_attributed": [...],
#     "cache_read_tokens": N, "prompt_tokens_uncached": N, "cache_creation_tokens": N,
#     "cache_hit_ratio": 0.34 | null, "warning": null | "cache_hit_low_with_heavy_prompt" | "no_session_data" }
#
# Side effect: if score.json exists, merges extensions.cache_hit_ratio
#
# Exit codes:
#   0 = ok
#   2 = usage error
#   4 = disabled or burn DB missing (no-op)

set -euo pipefail

# shellcheck source=./leadv2-helpers.sh
source "$(dirname "$(readlink -f "$0")")/leadv2-helpers.sh"

_lv2_load_quality_engine_config "l_c" || exit 4

log()       { printf -- '[leadv2-cache-audit] %s\n' "$*" >&2; }
log_warn()  { printf -- '[leadv2-cache-audit] WARN: %s\n' "$*" >&2; }

# ── argument parsing ──────────────────────────────────────────────────────────
TASK_ID="${1:-}"
if [[ -z "$TASK_ID" ]]; then
  printf -- 'Usage: leadv2-cache-audit.sh <task-id>\n' >&2
  exit 2
fi

# ── config ────────────────────────────────────────────────────────────────────
BURN_DB="${LV2_QE_L_C_BURN_DB_PATH:-${HOME}/.claude/burn/history.db}"
# Expand ~ manually (in case config has literal ~)
BURN_DB="${BURN_DB/#\~/$HOME}"

PROJECT_FILTER="${LV2_QE_L_C_PROJECT_NAME_FILTER:-}"
CACHE_LOW_THRESHOLD="${LV2_QE_L_C_WARNING_CACHE_HIT_LOW_THRESHOLD:-0.20}"
HEAVY_PROMPT_THRESHOLD="${LV2_QE_L_C_WARNING_HEAVY_PROMPT_THRESHOLD_TOKENS:-50000}"

# ── check DB exists ───────────────────────────────────────────────────────────
if [[ ! -f "$BURN_DB" ]]; then
  log_warn "burn_db_not_found: $BURN_DB — cache audit skipped (exit 4)"
  exit 4
fi

if ! command -v sqlite3 &>/dev/null; then
  log_warn "sqlite3 not in PATH — cache audit skipped (exit 4)"
  exit 4
fi

# ── read task window from STATE.md / closed YAML ──────────────────────────────
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

python3 - "$TASK_ID" "$BURN_DB" "$PROJECT_FILTER" \
          "$CACHE_LOW_THRESHOLD" "$HEAVY_PROMPT_THRESHOLD" \
          "$STATE_MD" "$CLOSED_YAML" "$SCORE_OUTPUT" \
          "$LEADV2_PROJECT_ROOT" \
          <<'PYEOF'
import sys
import os
import json
import sqlite3
import re

task_id            = sys.argv[1]
burn_db            = sys.argv[2]
project_filter     = sys.argv[3]
cache_low_thr      = float(sys.argv[4])
heavy_prompt_thr   = int(sys.argv[5])
state_md           = sys.argv[6]
closed_yaml        = sys.argv[7]
score_output       = sys.argv[8]
project_root       = sys.argv[9]

try:
    import yaml
    has_yaml = True
except ImportError:
    has_yaml = False

def read_yaml_field(filepath: str, field: str) -> str | None:
    if not os.path.isfile(filepath):
        return None
    if has_yaml:
        try:
            with open(filepath) as fh:
                d = yaml.safe_load(fh) or {}
            return d.get(field)
        except Exception:
            pass
    # Fallback: grep for field:
    try:
        with open(filepath) as fh:
            for line in fh:
                m = re.match(rf'^{re.escape(field)}\s*:\s*(.+)', line.strip())
                if m:
                    return m.group(1).strip().strip('"\'')
    except Exception:
        pass
    return None

# Get task time window
started_at = read_yaml_field(state_md, "started_at") or read_yaml_field(closed_yaml, "started_at")
closed_at  = read_yaml_field(closed_yaml, "closed_at") or read_yaml_field(closed_yaml, "completed_at")

if not started_at and os.path.isfile(state_md):
    import datetime
    mtime = os.path.getmtime(state_md)
    started_at = datetime.datetime.utcfromtimestamp(mtime).strftime("%Y-%m-%dT%H:%M:%SZ")

if not closed_at:
    import datetime
    closed_at = datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None).strftime("%Y-%m-%dT%H:%M:%SZ")

task_window = {"start": started_at, "end": closed_at}

# Query burn DB
try:
    conn = sqlite3.connect(burn_db)
    cur = conn.cursor()

    # Build query with optional project filter
    sql_parts = ["SELECT session_id, cc_total, cr_total, input_total, project_dir FROM sessions"]
    conditions = []
    params = []

    if project_filter:
        conditions.append("project_name = ?")
        params.append(project_filter)

    if started_at:
        conditions.append("last_asst_ts >= ?")
        params.append(started_at)

    if closed_at:
        conditions.append("last_asst_ts <= ?")
        params.append(closed_at)

    if conditions:
        sql_parts.append("WHERE " + " AND ".join(conditions))

    sql = " ".join(sql_parts)
    cur.execute(sql, params)
    rows = cur.fetchall()
    conn.close()
except sqlite3.Error as e:
    print(json.dumps({
        "task_id": task_id, "task_window": task_window,
        "sessions_attributed": [], "cache_read_tokens": 0,
        "prompt_tokens_uncached": 0, "cache_creation_tokens": 0,
        "cache_hit_ratio": None, "warning": "burn_db_error",
        "error": str(e)
    }))
    sys.exit(0)

# Optionally filter by project_dir for cross-repo isolation
if rows and project_root:
    filtered = [r for r in rows if not r[4] or os.path.normpath(r[4]) == os.path.normpath(project_root)]
    if filtered:
        rows = filtered
    # else: no matching project_dir, keep all (DB might not have project_dir populated)

if not rows:
    print(json.dumps({
        "task_id": task_id, "task_window": task_window,
        "sessions_attributed": [], "cache_read_tokens": 0,
        "prompt_tokens_uncached": 0, "cache_creation_tokens": 0,
        "cache_hit_ratio": None, "warning": "no_session_data"
    }))
    sys.exit(0)

session_ids    = [r[0] for r in rows]
cc_total       = sum(r[1] or 0 for r in rows)
cr_total       = sum(r[2] or 0 for r in rows)
input_total    = sum(r[3] or 0 for r in rows)

# cache_hit_ratio = cr / (cr + input)
denominator = cr_total + input_total
cache_hit_ratio = round(cr_total / denominator, 4) if denominator > 0 else None

# Warning logic
warning = None
if cache_hit_ratio is not None and cache_hit_ratio < cache_low_thr and input_total > heavy_prompt_thr:
    warning = "cache_hit_low_with_heavy_prompt"

result = {
    "task_id":                task_id,
    "task_window":            task_window,
    "sessions_attributed":    session_ids,
    "cache_read_tokens":      cr_total,
    "prompt_tokens_uncached": input_total,
    "cache_creation_tokens":  cc_total,
    "cache_hit_ratio":        cache_hit_ratio,
    "warning":                warning
}
print(json.dumps(result))

# Merge into score.json if it exists
if os.path.isfile(score_output):
    try:
        with open(score_output) as fh:
            score_data = json.load(fh)
        exts = score_data.setdefault("extensions", {})
        exts["cache_hit_ratio"] = cache_hit_ratio
        with open(score_output, "w") as fh:
            json.dump(score_data, fh)
        print(f"[leadv2-cache-audit] merged cache_hit_ratio={cache_hit_ratio} into {score_output}", file=sys.stderr)
    except Exception as e:
        print(f"[leadv2-cache-audit] WARN: could not merge into score.json: {e}", file=sys.stderr)

sys.exit(0)
PYEOF
