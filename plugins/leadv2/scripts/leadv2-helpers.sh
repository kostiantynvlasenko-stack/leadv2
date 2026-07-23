#!/bin/bash
# leadv2-helpers.sh — shared helper functions for /leadv2 orchestrator.
# Source this file, don't exec. Functions: validate yaml, rotate history, lockfile,
# archive old handoff, cost check, dry-run gate, status summary.
#
# Usage (from lead main session or other scripts):
#   source .claude/scripts/leadv2-helpers.sh
#   leadv2_validate_yaml docs/handoff/P42/context.yaml || fail

set -euo pipefail

_LV2_D="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Fail-safe paths anchored to project root.
# Resolution order (PO-060):
#   1. Already-exported LEADV2_PROJECT_ROOT (tests / CI set this explicitly).
#   2. Already-exported PROJECT_ROOT (legacy env var).
#   3. git rev-parse --show-toplevel (correct in worktrees: returns worktree root,
#      which IS the right repo root for that checkout — see note below).
#   4. $(pwd) as last resort.
#
# Worktree note: when inside .claude/worktrees/<id>/, git --show-toplevel returns
# the worktree checkout path (not the main repo), which is what we want because
# all docs/handoff/<id>/ paths are relative to THAT checkout.  We detect the
# worktree case and log it so future debugging is easier.
if [[ -z "${LEADV2_PROJECT_ROOT:-}" && -z "${PROJECT_ROOT:-}" ]]; then
  _git_toplevel="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  if [[ -n "$_git_toplevel" ]]; then
    # Detect worktree: .git is a file (not a dir) and its path contains "worktrees/"
    _git_dir="$(git rev-parse --git-dir 2>/dev/null || true)"
    if [[ "$_git_dir" == *"worktrees/"* ]]; then
      printf -- '[helpers] INFO: running inside git worktree (%s) — using worktree root as PROJECT_ROOT\n' \
        "$_git_toplevel" >&2
    fi
    LEADV2_PROJECT_ROOT="$_git_toplevel"
  else
    LEADV2_PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  fi
else
  # Resolution order: explicit override → CLAUDE_PROJECT_DIR (v2.1.144+) → PROJECT_ROOT → git toplevel → cwd
  LEADV2_PROJECT_ROOT="${LEADV2_PROJECT_ROOT:-${CLAUDE_PROJECT_DIR:-${PROJECT_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}}}"
fi
unset _git_toplevel _git_dir

LEADV2_STATE="$LEADV2_PROJECT_ROOT/docs/LEAD_V2_STATE.md"
LEADV2_HISTORY="$LEADV2_PROJECT_ROOT/docs/ops/LEAD_HISTORY.md"
LEADV2_LOCK="$LEADV2_PROJECT_ROOT/docs/.leadv2.lock"
# shellcheck disable=SC2034  # exported for external callers that source this script
LEADV2_LIVE="$LEADV2_PROJECT_ROOT/docs/LEAD_V2_LIVE.md"
LEADV2_HANDOFF_DIR="$LEADV2_PROJECT_ROOT/docs/handoff"

# ── Script resolver (A2/A3 transition indirection) ───────────────────────
# lv2_script BASENAME  — echoes the first existing path among:
#   1. $CLAUDE_PLUGIN_ROOT/scripts/$1   (plugin canonical, preferred)
#   2. $LEADV2_PROJECT_ROOT/.claude/leadv2-overrides/scripts/$1  (project override)
#   3. $LEADV2_PROJECT_ROOT/.claude/scripts/$1  (legacy fallback until A6 cleanup)
# Returns 1 (non-zero) and emits an error if none found.
# Guard: CLAUDE_PLUGIN_ROOT and LEADV2_PROJECT_ROOT must be set; unset = fall through.
lv2_script() {
  local _basename="${1:?lv2_script: BASENAME argument required}"
  local _plugin_root="${CLAUDE_PLUGIN_ROOT:-}"
  local _project_root="${LEADV2_PROJECT_ROOT:-}"
  local _candidate

  # 1. Plugin canonical
  if [[ -n "$_plugin_root" ]]; then
    _candidate="$_plugin_root/scripts/$_basename"
    if [[ -f "$_candidate" ]]; then printf -- '%s' "$_candidate"; return 0; fi
  fi

  # 2. Project override
  if [[ -n "$_project_root" ]]; then
    _candidate="$_project_root/.claude/leadv2-overrides/scripts/$_basename"
    if [[ -f "$_candidate" ]]; then printf -- '%s' "$_candidate"; return 0; fi

    # 3. Legacy fallback (.claude/scripts/ — kept until A6 cleanup)
    _candidate="$_project_root/.claude/scripts/$_basename"
    if [[ -f "$_candidate" ]]; then printf -- '%s' "$_candidate"; return 0; fi
  fi

  printf -- '[lv2_script] ERROR: %s not found in plugin, overrides, or .claude/scripts\n' \
    "$_basename" >&2
  return 1
}

# ── Path loader — reads .claude/leadv2-overrides/state-paths.yaml ────────
# Exports LEADV2_BOARD_PATH, LEADV2_DIALOGUE_PATH, LEADV2_QUEUE_PATH,
# LEADV2_LEAD_STATE_PATH, LEADV2_HANDOFF_DIR, LEADV2_LEADV2_DIR.
# Callers that need portable paths must call _lv2_load_paths at top.
# Values from yaml override defaults; existing env vars are preserved.
# Nullable paths (yaml value: null / ~) are exported as empty string.
_lv2_load_paths() {
  local _overrides_yaml="${LEADV2_PROJECT_ROOT}/.claude/leadv2-overrides/state-paths.yaml"
  local _py_script
  # Inline Python as a string to avoid heredoc-in-command-substitution warnings.
  _py_script='
import sys, yaml, os
yaml_path = sys.argv[1]; project_root = sys.argv[2]
def resolve(val, default, is_path=True):
    if val is None: return ""
    s = str(val).strip()
    if s in ("null", "~", ""): return ""
    if not is_path: return s
    return s if s.startswith("/") else project_root.rstrip("/") + "/" + s
with open(yaml_path) as f:
    d = yaml.safe_load(f) or {}
# Path keys — resolved relative to project_root
path_defaults = {
    "LEADV2_BOARD_PATH":        project_root + "/docs/BOARD.md",
    "LEADV2_DIALOGUE_PATH":     project_root + "/docs/agents/product-owner/DIALOGUE.md",
    "LEADV2_QUEUE_PATH":        project_root + "/docs/agents/product-owner/QUEUE.md",
    "LEADV2_LEAD_STATE_PATH":   project_root + "/docs/LEAD_V2_STATE.md",
    "LEADV2_HANDOFF_DIR":       project_root + "/docs/handoff",
    "LEADV2_LEADV2_DIR":        project_root + "/docs/leadv2",
    "LEADV2_QUEUE_ARCHIVE_DIR": project_root + "/docs/agents/product-owner/queue/_archive",
    "LEADV2_TASKS_DIR":         project_root + "/docs/leadv2/tasks",
}
path_key_map = {
    "board_path":        "LEADV2_BOARD_PATH",
    "dialogue_path":     "LEADV2_DIALOGUE_PATH",
    "queue_path":        "LEADV2_QUEUE_PATH",
    "lead_state_path":   "LEADV2_LEAD_STATE_PATH",
    "handoff_dir":       "LEADV2_HANDOFF_DIR",
    "leadv2_dir":        "LEADV2_LEADV2_DIR",
    "queue_archive_dir": "LEADV2_QUEUE_ARCHIVE_DIR",
    "leadv2_tasks_dir":  "LEADV2_TASKS_DIR",
}
# Non-path keys — for project-specific extensions via state-paths.yaml.
str_key_map = {}
out = dict(path_defaults)
for yk, ek in path_key_map.items():
    if yk in d:
        out[ek] = resolve(d[yk], path_defaults[ek], is_path=True)
for yk, ek in str_key_map.items():
    if yk in d:
        out[ek] = resolve(d[yk], "", is_path=False)
for ek, val in out.items():
    print(f"{ek}={val}")
'
  local _parsed=""
  if [[ -f "$_overrides_yaml" ]] && command -v python3 &>/dev/null; then
    _parsed=$(python3 -c "$_py_script" "$_overrides_yaml" "$LEADV2_PROJECT_ROOT" 2>/dev/null || true)
  fi

  # Track which keys were produced by Python (including nullable="" ones).
  # Format: KEY= (empty value is valid for nullable paths).
  declare -A _lv2_produced=() 2>/dev/null || true
  while IFS='=' read -r _k _v; do
    [[ -z "$_k" ]] && continue
    # Only set if not already exported by caller (caller override wins).
    if [[ -z "${!_k+x}" ]]; then
      export "${_k}=${_v}"
    fi
    _lv2_produced["$_k"]="1" 2>/dev/null || true
  done <<< "$_parsed"

  # Hard defaults only for keys NOT produced by Python (no yaml / no python).
  [[ -z "${_lv2_produced[LEADV2_BOARD_PATH]+x}"        ]] && : "${LEADV2_BOARD_PATH:=${LEADV2_PROJECT_ROOT}/docs/BOARD.md}"
  [[ -z "${_lv2_produced[LEADV2_DIALOGUE_PATH]+x}"     ]] && : "${LEADV2_DIALOGUE_PATH:=${LEADV2_PROJECT_ROOT}/docs/agents/product-owner/DIALOGUE.md}"
  [[ -z "${_lv2_produced[LEADV2_QUEUE_PATH]+x}"        ]] && : "${LEADV2_QUEUE_PATH:=${LEADV2_PROJECT_ROOT}/docs/agents/product-owner/QUEUE.md}"
  [[ -z "${_lv2_produced[LEADV2_LEAD_STATE_PATH]+x}"   ]] && : "${LEADV2_LEAD_STATE_PATH:=${LEADV2_PROJECT_ROOT}/docs/LEAD_V2_STATE.md}"
  [[ -z "${_lv2_produced[LEADV2_HANDOFF_DIR]+x}"       ]] && : "${LEADV2_HANDOFF_DIR:=${LEADV2_PROJECT_ROOT}/docs/handoff}"
  [[ -z "${_lv2_produced[LEADV2_LEADV2_DIR]+x}"        ]] && : "${LEADV2_LEADV2_DIR:=${LEADV2_PROJECT_ROOT}/docs/leadv2}"
  [[ -z "${_lv2_produced[LEADV2_QUEUE_ARCHIVE_DIR]+x}" ]] && : "${LEADV2_QUEUE_ARCHIVE_DIR:=${LEADV2_PROJECT_ROOT}/docs/agents/product-owner/queue/_archive}"
  [[ -z "${_lv2_produced[LEADV2_TASKS_DIR]+x}"         ]] && : "${LEADV2_TASKS_DIR:=${LEADV2_PROJECT_ROOT}/docs/leadv2/tasks}"
  export LEADV2_BOARD_PATH LEADV2_DIALOGUE_PATH LEADV2_QUEUE_PATH \
         LEADV2_LEAD_STATE_PATH LEADV2_HANDOFF_DIR LEADV2_LEADV2_DIR \
         LEADV2_QUEUE_ARCHIVE_DIR LEADV2_TASKS_DIR
}

# ── Codex policy ──────────────────────────────────────────────────────────
# Reads <repo>/.claude/leadv2-overrides/codex-policy.yaml:
#   codex_enabled: true | false
# Returns 0 if Codex is allowed in this repo, 1 if missing/disabled.
# DEFAULT: false (disabled) if file is missing — opt-in only.
_lv2_codex_enabled() {
  : "${LEADV2_PROJECT_ROOT:=$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
  local _policy="${LEADV2_PROJECT_ROOT}/.claude/leadv2-overrides/codex-policy.yaml"
  if [[ ! -f "$_policy" ]]; then
    return 1  # default: disabled
  fi
  local _val
  _val=$(python3 -c "
import sys, yaml
try:
    d = yaml.safe_load(open(sys.argv[1])) or {}
    print('true' if d.get('codex_enabled', False) else 'false')
except Exception:
    print('false')
" "$_policy" 2>/dev/null || echo "false")
  [[ "$_val" == "true" ]]
}

# ── Quality engine config loader ─────────────────────────────────────────────
# _lv2_load_quality_engine_config <feature_key>
#
# Reads <repo>/.claude/leadv2-overrides/quality-engine.yaml.
# Checks master `enabled: true` AND per-feature block `<feature_key>.enabled: true`.
# On success: exports LV2_QE_* env vars for the calling script.
# On missing file or disabled: returns exit 4 (silent no-op).
#
# Feature key: l_a | l_b | l_c | l_d | l_e
#
# Exported variables (examples for l_a):
#   LV2_QE_L_A_RULES_DIR, LV2_QE_L_A_RULE_GLOB,
#   LV2_QE_L_A_SEVERITY_FLOOR, LV2_QE_L_A_DEFAULT_ACTION
# For l_b: LV2_QE_L_B_STATE_PATH_TMPL, LV2_QE_L_B_CLOSED_YAML_TMPL,
#           LV2_QE_L_B_SCORE_OUTPUT_TMPL, LV2_QE_L_B_HISTORY_WINDOW,
#           LV2_QE_L_B_MIN_TASKS_FOR_TREND
# For l_c: LV2_QE_L_C_BURN_DB_PATH, LV2_QE_L_C_PROJECT_NAME_FILTER,
#           LV2_QE_L_C_WARNING_CACHE_HIT_LOW_THRESHOLD,
#           LV2_QE_L_C_WARNING_HEAVY_PROMPT_THRESHOLD_TOKENS
# For l_d: LV2_QE_L_D_MISSION_GLOB, LV2_QE_L_D_WARNING_THRESHOLD
# For l_e: LV2_QE_L_E_WARNING_CLUSTER_COUNT, LV2_QE_L_E_CLUSTER_MAP_JSON
#
# Exit codes:
#   0 — config loaded, feature enabled, vars exported
#   4 — config missing, master disabled, or feature disabled (caller should exit 4)
_lv2_load_quality_engine_config() {
  local _feature_key="${1:-}"
  if [[ -z "$_feature_key" ]]; then
    printf -- '[helpers] _lv2_load_quality_engine_config: feature_key required\n' >&2
    return 4
  fi

  : "${LEADV2_PROJECT_ROOT:=$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
  local _cfg="${LEADV2_PROJECT_ROOT}/.claude/leadv2-overrides/quality-engine.yaml"

  if [[ ! -f "$_cfg" ]]; then
    return 4  # no config → no-op (not an error)
  fi

  # Use yq if available, else fall back to python3+yaml
  local _py_script
  _py_script='
import sys, json, os

yaml_path    = sys.argv[1]
feature_key  = sys.argv[2]  # e.g. "l_a"
project_root = sys.argv[3]

try:
    import yaml
except ImportError:
    # Without yaml we cannot parse — treat as not-configured
    sys.exit(4)

try:
    with open(yaml_path) as fh:
        cfg = yaml.safe_load(fh) or {}
except Exception:
    sys.exit(4)

# Master switch
if not cfg.get("enabled", True):
    sys.exit(4)

# Per-feature block
block = cfg.get(feature_key, {})
if not isinstance(block, dict):
    sys.exit(4)
if not block.get("enabled", True):
    sys.exit(4)

KEY = feature_key.upper().replace("-", "_")  # e.g. L_A

def rel_to_abs(val):
    """Convert relative path to absolute using project_root."""
    if val and not str(val).startswith("/"):
        return project_root.rstrip("/") + "/" + str(val)
    return val

exports = {}

if feature_key == "l_a":
    exports[f"LV2_QE_{KEY}_RULES_DIR"]       = rel_to_abs(block.get("rules_dir", ".claude/leadv2-overrides/rules"))
    exports[f"LV2_QE_{KEY}_RULE_GLOB"]        = block.get("rule_glob", "*.rule.md")
    exports[f"LV2_QE_{KEY}_SEVERITY_FLOOR"]   = block.get("severity_floor", "medium")
    exports[f"LV2_QE_{KEY}_DEFAULT_ACTION"]   = block.get("default_action", "warn")

elif feature_key == "l_b":
    exports[f"LV2_QE_{KEY}_STATE_PATH_TMPL"]    = block.get("state_path_tmpl", "docs/leadv2/tasks/{task_id}/STATE.md")
    exports[f"LV2_QE_{KEY}_CLOSED_YAML_TMPL"]   = block.get("closed_yaml_tmpl", "docs/leadv2/closed/{task_id}.yaml")
    exports[f"LV2_QE_{KEY}_SCORE_OUTPUT_TMPL"]  = block.get("score_output_tmpl", "docs/leadv2/tasks/{task_id}/score.json")
    exports[f"LV2_QE_{KEY}_HISTORY_WINDOW"]     = str(block.get("history_window", 10))
    exports[f"LV2_QE_{KEY}_MIN_TASKS_FOR_TREND"] = str(block.get("min_tasks_for_trend", 20))

elif feature_key == "l_c":
    burn_db = block.get("burn_db_path", "~/.claude/burn/history.db")
    # Expand ~ relative to HOME
    if burn_db and burn_db.startswith("~"):
        burn_db = os.path.expanduser(burn_db)
    exports[f"LV2_QE_{KEY}_BURN_DB_PATH"]       = burn_db
    exports[f"LV2_QE_{KEY}_PROJECT_NAME_FILTER"] = block.get("project_name_filter", "")
    warn = block.get("warning", {}) or {}
    exports[f"LV2_QE_{KEY}_WARNING_CACHE_HIT_LOW_THRESHOLD"]       = str(warn.get("cache_hit_low_threshold", 0.20))
    exports[f"LV2_QE_{KEY}_WARNING_HEAVY_PROMPT_THRESHOLD_TOKENS"] = str(warn.get("heavy_prompt_threshold_tokens", 50000))

elif feature_key == "l_d":
    exports[f"LV2_QE_{KEY}_MISSION_GLOB"]        = block.get("mission_glob", "docs/handoff/{task_id}/*mission*.md")
    exports[f"LV2_QE_{KEY}_WARNING_THRESHOLD"]   = str(block.get("warning_threshold", 0.50))

elif feature_key == "l_e":
    exports[f"LV2_QE_{KEY}_WARNING_CLUSTER_COUNT"] = str(block.get("warning_cluster_count", 4))
    cluster_map = block.get("cluster_map", {})
    exports[f"LV2_QE_{KEY}_CLUSTER_MAP_JSON"] = json.dumps(cluster_map) if isinstance(cluster_map, dict) else "{}"

else:
    # Unknown feature key — pass through any flat string values
    for k, v in block.items():
        env_name = f"LV2_QE_{KEY}_{k.upper()}"
        exports[env_name] = str(v) if v is not None else ""

for k, v in exports.items():
    print(f"{k}={v}")
sys.exit(0)
'

  local _parsed=""
  _parsed=$(python3 -c "$_py_script" "$_cfg" "$_feature_key" "$LEADV2_PROJECT_ROOT" 2>/dev/null)
  local _rc=$?

  if [[ $_rc -ne 0 ]]; then
    return 4
  fi

  # Export each KEY=value pair
  while IFS='=' read -r _k _v; do
    [[ -z "$_k" ]] && continue
    # Only export if not already set by caller
    if [[ -z "${!_k+x}" ]]; then
      export "${_k}=${_v}"
    fi
  done <<< "$_parsed"

  return 0
}

# ── stack.yaml reader (grep/sed/awk only — no python3 dependency) ─────────
#
# _lv2_stack_scalar <key> <default>
#   Reads a top-level scalar from .claude/leadv2-overrides/stack.yaml.
#   Prints the value (or <default> if file/key absent). Never crashes.
#   Handles: key: value  AND  key: "value"  AND  key: 'value'.
#
# _lv2_stack_list <key> <default_space_separated>
#   Reads a top-level YAML sequence from stack.yaml (compact inline OR
#   block form).  Prints items space-separated on one line, or <default>.
#
#   Inline:  key: [a, b, c]           → "a b c"
#   Block:
#     key:
#       - a
#       - b                            → "a b"
#
#   Limitations: values must not contain commas (inline) or leading
#   spaces+dash sequences beyond column-2 (block). Sufficient for path
#   strings and glob patterns.

_lv2_stack_scalar() {
  local _key="${1:-}" _default="${2:-}"
  : "${LEADV2_PROJECT_ROOT:=$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
  local _yaml="${LEADV2_PROJECT_ROOT}/.claude/leadv2-overrides/stack.yaml"
  if [[ ! -f "$_yaml" ]]; then
    printf -- '%s' "$_default"
    return 0
  fi
  local _val
  # Match "key: value" or "key: 'value'" or 'key: "value"'; strip quotes.
  _val=$(grep -E "^[[:space:]]*${_key}[[:space:]]*:" "$_yaml" 2>/dev/null \
    | head -1 \
    | sed -E "s/^[[:space:]]*${_key}[[:space:]]*:[[:space:]]*//" \
    | sed -E "s/^['\"]//; s/['\"][[:space:]]*$//" \
    | tr -d '\r' \
    || true)
  if [[ -z "$_val" || "$_val" == "null" || "$_val" == "~" ]]; then
    printf -- '%s' "$_default"
  else
    printf -- '%s' "$_val"
  fi
}

_lv2_stack_list() {
  local _key="${1:-}" _default="${2:-}"
  : "${LEADV2_PROJECT_ROOT:=$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
  local _yaml="${LEADV2_PROJECT_ROOT}/.claude/leadv2-overrides/stack.yaml"
  if [[ ! -f "$_yaml" ]]; then
    printf -- '%s' "$_default"
    return 0
  fi
  # Try inline form: key: [a, b, c]
  local _inline
  _inline=$(grep -E "^[[:space:]]*${_key}[[:space:]]*:[[:space:]]*\[" "$_yaml" 2>/dev/null \
    | head -1 \
    | sed -E "s/^[[:space:]]*${_key}[[:space:]]*:[[:space:]]*//" \
    | sed -E 's/^\[//; s/\][[:space:]]*$//' \
    | tr ',' ' ' \
    | sed -E "s/['\"]//g" \
    | tr -s ' ' \
    | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' \
    || true)
  if [[ -n "$_inline" ]]; then
    printf -- '%s' "$_inline"
    return 0
  fi
  # Try block form: lines after "key:" that start with "  - "
  local _block
  _block=$(awk -v key="${_key}" '
    found && /^[[:space:]]*-[[:space:]]/ {
      gsub(/^[[:space:]]*-[[:space:]]/, ""); gsub(/^'"'"'|'"'"'$|^"|"$/, ""); printf "%s ", $0
    }
    /^[[:space:]]*'"${_key}"'[[:space:]]*:/ { found=1; next }
    found && !/^[[:space:]]*-/ { exit }
  ' "$_yaml" 2>/dev/null | sed -E 's/[[:space:]]+$//' || true)
  if [[ -n "$_block" ]]; then
    printf -- '%s' "$_block"
    return 0
  fi
  printf -- '%s' "$_default"
}

# ── state-paths.yaml reader (grep/sed only — no python3 dependency) ───────
#
# _lv2_statepath <key> <default>
#   Reads a top-level scalar from .claude/leadv2-overrides/state-paths.yaml.
#   Prints the value (or <default> if file/key absent). Never crashes.
#   Handles: key: value  AND  key: "value"  AND  key: 'value'.
#   Returns <default> on missing file, missing key, null, or ~.
#
# Keys defined in state-paths.yaml (with PE fallback defaults):
#   leadv2_dir  → docs/leadv2
#   handoff_dir → docs/handoff
#   board_path  → docs/BOARD.md
_lv2_statepath() {
  local _key="${1:-}" _default="${2:-}"
  : "${LEADV2_PROJECT_ROOT:=$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
  local _yaml="${LEADV2_PROJECT_ROOT}/.claude/leadv2-overrides/state-paths.yaml"
  if [[ ! -f "$_yaml" ]]; then
    printf -- '%s' "$_default"
    return 0
  fi
  local _val
  # Match "key: value" or "key: 'value'" or 'key: "value"'; strip quotes.
  _val=$(grep -E "^[[:space:]]*${_key}[[:space:]]*:" "$_yaml" 2>/dev/null \
    | head -1 \
    | sed -E "s/^[[:space:]]*${_key}[[:space:]]*:[[:space:]]*//" \
    | sed -E "s/^['\"]//; s/['\"][[:space:]]*$//" \
    | tr -d '\r' \
    || true)
  if [[ -z "$_val" || "$_val" == "null" || "$_val" == "~" ]]; then
    printf -- '%s' "$_default"
  else
    printf -- '%s' "$_val"
  fi
}

# ── YAML validation ───────────────────────────────────────────────────────
leadv2_validate_yaml() {
  local file="$1"
  [[ -f "$file" ]] || { echo "[helpers] file not found: $file" >&2; return 1; }
  python3 -c "import yaml, sys; yaml.safe_load(open(sys.argv[1]))" "$file" 2>&1
}

# ── Python version check (cached per shell session) ───────────────────────
# Set to "1" once verified; reset to anything else to force re-check.
# External callers can set LEADV2_PYTHON_VERSION_OK=__force_recheck__ to
# test the error path without actually having Python <3.10 installed.
LEADV2_PYTHON_VERSION_OK="${LEADV2_PYTHON_VERSION_OK:-}"

_leadv2_check_python_version() {
  # Already verified in this shell session — skip.
  if [[ "${LEADV2_PYTHON_VERSION_OK:-}" == "1" ]]; then
    return 0
  fi
  # Detect version; python3 -c exits 1 when condition is false.
  local ver
  ver=$(python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2>/dev/null) || {
    printf -- 'leadv2_validate_handoff: python3 not found on PATH\n' >&2
    return 1
  }
  if ! python3 -c "import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)" 2>/dev/null; then
    printf -- 'leadv2_validate_handoff: needs Python >=3.10, found %s\n' "$ver" >&2
    return 1
  fi
  LEADV2_PYTHON_VERSION_OK="1"
  return 0
}

# ── Semantic handoff schema validation ────────────────────────────────────
# Stricter than leadv2_validate_yaml: validates structure + field types
# against the Pydantic v2 models in platform/leadv2/handoff_schemas.py.
#
# Usage:
#   leadv2_validate_handoff <yaml_path> <schema>
#   schema: context | build_summary | review_disposition
#
# Exit codes:
#   0 — valid
#   1 — invalid (error printed to stderr, suitable for LLM re-prompt)
#   2 — usage error (wrong number of args)
#
# Example:
#   source .claude/scripts/leadv2-helpers.sh
#   leadv2_validate_handoff docs/handoff/PO-001/context.yaml context \
#     || ask-lead.sh PO-001 "Fix context.yaml: $(leadv2_validate_handoff ... 2>&1)"
leadv2_validate_handoff() {
  if [[ $# -ne 2 ]]; then
    printf -- '[helpers] usage: leadv2_validate_handoff <yaml_path> <schema>\n' >&2
    return 2
  fi
  local yaml_path="$1" schema="$2"

  # Enforce Python >=3.10 before attempting Pydantic validation.
  _leadv2_check_python_version || return 1

  # Resolve project root from this script's location (works when sourced from any cwd)
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local project_root
  project_root="$(cd "$script_dir/../.." && pwd)"

  python3 - "$yaml_path" "$schema" "$project_root" <<'PYEOF'
import sys, importlib.util

yaml_path, schema, project_root = sys.argv[1], sys.argv[2], sys.argv[3]

# Load handoff_validate without adding platform/ to sys.path
# (platform/ shadows stdlib platform module — use importlib by file path)
def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)
    return mod

pkg = project_root + "/platform/leadv2"
_load("platform.leadv2.handoff_schemas", pkg + "/handoff_schemas.py")
_load("platform.leadv2.handoff_validate", pkg + "/handoff_validate.py")

from pathlib import Path
from platform.leadv2.handoff_validate import validate_handoff
ok, err, _ = validate_handoff(Path(yaml_path), schema)
if ok:
    sys.exit(0)
print(err, file=sys.stderr)
sys.exit(1)
PYEOF
}

# ── History rotation ──────────────────────────────────────────────────────
# If LEAD_V2_STATE.history has > 20 entries, move oldest to LEAD_HISTORY.md.
leadv2_rotate_history() {
  [[ -f "$LEADV2_STATE" ]] || return 0
  mkdir -p "$(dirname "$LEADV2_HISTORY")"

  python3 - <<PY "$LEADV2_STATE" "$LEADV2_HISTORY"
import sys, os, yaml
state_file, history_file = sys.argv[1], sys.argv[2]
with open(state_file) as f:
    d = yaml.safe_load(f) or {}
h = d.get('history') or []
if len(h) <= 20:
    sys.exit(0)
old = h[:-20]
d['history'] = h[-20:]
mode = 'a' if os.path.exists(history_file) else 'w'
with open(history_file, mode) as f:
    if mode == 'w':
        f.write("# Lead v2 History (archived reflections)\n\n")
    for e in old:
        f.write("\n---\n")
        yaml.dump(e, f, default_flow_style=False, sort_keys=False)
with open(state_file, 'w') as f:
    yaml.dump(d, f, default_flow_style=False, sort_keys=False)
print(f"[helpers] rotated {len(old)} history entries to {history_file}")
PY
}

# ── Lockfile for concurrent safety ────────────────────────────────────────
# NOTE: These functions are kept for backward compatibility.
# They now delegate to leadv2_active_register / leadv2_active_unregister
# from leadv2-active-registry.sh (sourced above).
leadv2_lock_acquire() {
  # Delegate to active registry when LEADV2_TASK_ID is set.
  if [[ -n "${LEADV2_TASK_ID:-}" ]]; then
    local cls="${LEADV2_TASK_CLASS:-Standard}"
    local worktree="${LEADV2_PROJECT_ROOT}"
    leadv2_active_register "${LEADV2_TASK_ID}" "$cls" "$worktree" "" "${LEADV2_DAEMON:-false}" >/dev/null 2>&1 || true
    return 0
  fi
  # Legacy file-lock fallback when no task ID is set.
  mkdir -p "$(dirname "$LEADV2_LOCK")"
  if [[ -f "$LEADV2_LOCK" ]]; then
    local pid
    pid=$(cat "$LEADV2_LOCK" 2>/dev/null || echo "")
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      echo "[helpers] lock held by PID $pid — another /leadv2 is active" >&2
      return 1
    fi
    echo "[helpers] stale lock found (PID $pid dead), clearing" >&2
    rm -f "$LEADV2_LOCK"
  fi
  echo "$$" > "$LEADV2_LOCK"
  return 0
}

leadv2_lock_release() {
  # Delegate to active registry when LEADV2_TASK_ID is set.
  if [[ -n "${LEADV2_TASK_ID:-}" ]]; then
    leadv2_active_unregister "${LEADV2_TASK_ID}" 2>/dev/null || true
    return 0
  fi
  # Legacy fallback.
  rm -f "$LEADV2_LOCK"
}

# ── Archive old handoff dirs ──────────────────────────────────────────────
# Move handoff dirs older than N days (default 7) to archive/
# Delete archive dirs older than M days (default 30)
leadv2_archive_old_handoff() {
  local archive_days="${1:-7}"
  local delete_days="${2:-30}"
  mkdir -p "$LEADV2_HANDOFF_DIR/archive"

  # Move 7+ day old task dirs to archive
  if [[ -d "$LEADV2_HANDOFF_DIR" ]]; then
    local d archived=0 deleted=0
    while IFS= read -r -d '' d; do
      local base=$(basename "$d")
      [[ "$base" == "archive" ]] && continue
      mv "$d" "$LEADV2_HANDOFF_DIR/archive/" 2>/dev/null && archived=$((archived+1))
    done < <(find "$LEADV2_HANDOFF_DIR" -maxdepth 1 -mindepth 1 -type d -mtime +"$archive_days" -not -name archive -print0 2>/dev/null)

    # Delete 30+ day archive entries
    while IFS= read -r -d '' d; do
      rm -rf "$d" && deleted=$((deleted+1))
    done < <(find "$LEADV2_HANDOFF_DIR/archive" -maxdepth 1 -mindepth 1 -type d -mtime +"$delete_days" -print0 2>/dev/null)

    echo "[helpers] archive: moved $archived, deleted $deleted"
  fi
}

# ── Cost check ─────────────────────────────────────────────────────────────
# Read from ~/.claude/burn/ if available. Best-effort.
leadv2_cost_check() {
  local burn_dir="$HOME/.claude/burn"
  if [[ -d "$burn_dir" ]]; then
    # Look for recent digest files (common names: digest.json, burn-*.json)
    local latest
    latest=$(ls -t "$burn_dir"/*.json 2>/dev/null | head -1 || echo "")
    if [[ -n "$latest" ]]; then
      python3 - <<PY "$latest" 2>/dev/null
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
    burn_24h = d.get('burn_24h') or d.get('daily') or d.get('tokens_24h')
    if burn_24h:
        print(f"[helpers] burn 24h: {burn_24h}")
except Exception:
    pass
PY
    fi
  fi
}

# ── Dry-run gate ──────────────────────────────────────────────────────────
leadv2_dry_run_enabled() {
  [[ "${LEADV2_DRY_RUN:-0}" == "1" ]]
}

leadv2_maybe_dry_run_echo() {
  if leadv2_dry_run_enabled; then
    echo "[DRY-RUN] would execute: $*" >&2
    return 0
  fi
  return 1
}
# leadv2_dry_run_guard — D5 single chokepoint for all side-effect entrypoints.
#
# Usage (at the TOP of any side-effect function/script):
#   leadv2_dry_run_guard "description of side effect" || return 0
#
# When LEADV2_DRY_RUN=1:
#   - Prints "[DRY_RUN] <description>" to stderr.
#   - Returns 0 so the caller can || return 0 / || exit 0 to skip the
#     side effect cleanly.
# When LEADV2_DRY_RUN is absent or 0:
#   - Prints nothing, returns 1 so || return 0 does NOT short-circuit.
#
# Exactly 4 call sites per D5:
#   1. claude-subsession.sh — subsession spawn (sources this file; guard before run_subsession)
#   2. leadv2_git_op wrapper (below)
#   3. sb_* Supabase call sites (guard at top of any sb_* wrapper that performs writes)
#   4. deploy entrypoints (leadv2_deploy_via_override — uses leadv2_dry_run_guard directly)
#
# Absent LEADV2_DRY_RUN leaves the flow byte-identical (D6).
leadv2_dry_run_guard() {
  if [[ "${LEADV2_DRY_RUN:-0}" == "1" ]]; then
    printf -- '[DRY_RUN] %s\n' "${*:-side-effect blocked}" >&2
    return 0
  fi
  return 1
}

# leadv2_git_op — wrapper around git commands that respects LEADV2_DRY_RUN.
# Call site 2 of 4 for leadv2_dry_run_guard (per D5).
#
# Usage:
#   leadv2_git_op commit -m "message"
#   leadv2_git_op push origin main
#
# Under LEADV2_DRY_RUN=1: logs the command, does not execute it.
leadv2_git_op() {
  if leadv2_dry_run_guard "git $*"; then
    return 0
  fi
  git "$@"
}

# ── Supabase write wrappers (call site 3 of 4 for leadv2_dry_run_guard, per D5) ──
#
# sb_write — thin wrapper around Supabase REST writes that respects LEADV2_DRY_RUN.
# Any code performing a Supabase mutation (INSERT / UPSERT / UPDATE / DELETE)
# should call this wrapper so LEADV2_DRY_RUN=1 blocks the write at a single
# chokepoint.
#
# Usage:
#   sb_write <table> <json_payload>
#   sb_write_rpc <function_name> <json_payload>
#
# Under LEADV2_DRY_RUN=1: logs "[DRY_RUN] supabase write: <table>" and returns 0
# without any network call.  When LEADV2_DRY_RUN is absent or 0: executes write.
#
# Requires SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY in environment.
# Python callers using supabase-py directly should guard inline:
#   leadv2_dry_run_guard "supabase write: <table>" || return 0
sb_write() {
  local table="${1:?sb_write requires table name as first arg}"
  local payload="${2:?sb_write requires JSON payload as second arg}"
  if leadv2_dry_run_guard "supabase write: ${table}"; then
    return 0
  fi
  if [[ -z "${SUPABASE_URL:-}" || -z "${SUPABASE_SERVICE_ROLE_KEY:-}" ]]; then
    printf -- '[sb_write] ERROR: SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY not set\n' >&2
    return 1
  fi
  curl --silent --show-error --fail \
    -X POST \
    -H "apikey: ${SUPABASE_SERVICE_ROLE_KEY}" \
    -H "Authorization: Bearer ${SUPABASE_SERVICE_ROLE_KEY}" \
    -H "Content-Type: application/json" \
    -H "Prefer: return=minimal" \
    -d "${payload}" \
    "${SUPABASE_URL}/rest/v1/${table}"
}

# ── Named Supabase write wrappers (D5: every write routes through guard) ──────
# sb_upsert / sb_insert / sb_patch / sb_delete — named-method aliases.
# New code MUST call one of these (never raw curl). LEADV2_DRY_RUN=1 blocks all.
#
# sb_upsert <table> <json>              — POST with merge-duplicates resolution
# sb_insert <table> <json>             — POST (plain insert, fails on conflict)
# sb_patch  <table> <json> <qs>        — PATCH with ?<qs> row filter
# sb_delete <table> <qs>               — DELETE with ?<qs> row filter
sb_upsert() {
  local table="${1:?sb_upsert requires table}" payload="${2:?sb_upsert requires payload}"
  if leadv2_dry_run_guard "supabase upsert: ${table}"; then return 0; fi
  if [[ -z "${SUPABASE_URL:-}" || -z "${SUPABASE_SERVICE_ROLE_KEY:-}" ]]; then
    printf -- '[sb_upsert] ERROR: SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY not set\n' >&2; return 1
  fi
  curl --silent --show-error --fail \
    -X POST \
    -H "apikey: ${SUPABASE_SERVICE_ROLE_KEY}" \
    -H "Authorization: Bearer ${SUPABASE_SERVICE_ROLE_KEY}" \
    -H "Content-Type: application/json" \
    -H "Prefer: resolution=merge-duplicates,return=minimal" \
    -d "${payload}" \
    "${SUPABASE_URL}/rest/v1/${table}"
}

sb_insert() {
  local table="${1:?sb_insert requires table}" payload="${2:?sb_insert requires payload}"
  if leadv2_dry_run_guard "supabase insert: ${table}"; then return 0; fi
  if [[ -z "${SUPABASE_URL:-}" || -z "${SUPABASE_SERVICE_ROLE_KEY:-}" ]]; then
    printf -- '[sb_insert] ERROR: SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY not set\n' >&2; return 1
  fi
  curl --silent --show-error --fail \
    -X POST \
    -H "apikey: ${SUPABASE_SERVICE_ROLE_KEY}" \
    -H "Authorization: Bearer ${SUPABASE_SERVICE_ROLE_KEY}" \
    -H "Content-Type: application/json" \
    -H "Prefer: return=minimal" \
    -d "${payload}" \
    "${SUPABASE_URL}/rest/v1/${table}"
}

sb_patch() {
  local table="${1:?sb_patch requires table}" payload="${2:?sb_patch requires payload}" qs="${3:?sb_patch requires query_string filter}"
  if leadv2_dry_run_guard "supabase patch: ${table}?${qs}"; then return 0; fi
  if [[ -z "${SUPABASE_URL:-}" || -z "${SUPABASE_SERVICE_ROLE_KEY:-}" ]]; then
    printf -- '[sb_patch] ERROR: SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY not set\n' >&2; return 1
  fi
  curl --silent --show-error --fail \
    -X PATCH \
    -H "apikey: ${SUPABASE_SERVICE_ROLE_KEY}" \
    -H "Authorization: Bearer ${SUPABASE_SERVICE_ROLE_KEY}" \
    -H "Content-Type: application/json" \
    -H "Prefer: return=minimal" \
    -d "${payload}" \
    "${SUPABASE_URL}/rest/v1/${table}?${qs}"
}

sb_delete() {
  local table="${1:?sb_delete requires table}" qs="${2:?sb_delete requires query_string filter}"
  if leadv2_dry_run_guard "supabase delete: ${table}?${qs}"; then return 0; fi
  if [[ -z "${SUPABASE_URL:-}" || -z "${SUPABASE_SERVICE_ROLE_KEY:-}" ]]; then
    printf -- '[sb_delete] ERROR: SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY not set\n' >&2; return 1
  fi
  curl --silent --show-error --fail \
    -X DELETE \
    -H "apikey: ${SUPABASE_SERVICE_ROLE_KEY}" \
    -H "Authorization: Bearer ${SUPABASE_SERVICE_ROLE_KEY}" \
    "${SUPABASE_URL}/rest/v1/${table}?${qs}"
}

sb_write_rpc() {
  local fn_name="${1:?sb_write_rpc requires function name as first arg}"
  local payload="${2:-{}}"
  if leadv2_dry_run_guard "supabase rpc: ${fn_name}"; then
    return 0
  fi
  if [[ -z "${SUPABASE_URL:-}" || -z "${SUPABASE_SERVICE_ROLE_KEY:-}" ]]; then
    printf -- '[sb_write_rpc] ERROR: SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY not set\n' >&2
    return 1
  fi
  curl --silent --show-error --fail \
    -X POST \
    -H "apikey: ${SUPABASE_SERVICE_ROLE_KEY}" \
    -H "Authorization: Bearer ${SUPABASE_SERVICE_ROLE_KEY}" \
    -H "Content-Type: application/json" \
    -d "${payload}" \
    "${SUPABASE_URL}/rest/v1/rpc/${fn_name}"
}

# ── LIVE state updater ────────────────────────────────────────────────────
leadv2_live_update() {
  local phase="$1" step="$2" note="${3:-}"
  local ts
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  # H2 fix: compute path at call time from LEADV2_TASK_ID (not the global
  # captured at source time), so concurrent tasks write to their own LIVE.md.
  local _live_target
  _live_target="$(leadv2_live_path)"
  mkdir -p "$(dirname "$_live_target")"
  {
    echo "# Lead v2 LIVE"
    echo ""
    echo "Updated: $ts"
    echo ""
    echo "**Phase:** $phase"
    echo "**Step:** $step"
    [[ -n "$note" ]] && echo "**Note:** $note"
    echo ""
    echo "*(this file updates throughout task execution — watch with: tail -F docs/LEAD_V2_LIVE.md)*"
  } > "$_live_target"
}

# ── Status summary ────────────────────────────────────────────────────────
leadv2_status_summary() {
  echo "== /leadv2 status =="
  # H2 fix: compute state path at call time from LEADV2_TASK_ID.
  local _state_target
  _state_target="$(leadv2_state_path)"
  [[ -f "$_state_target" ]] || { echo "no LEAD_V2_STATE.md"; return; }

  python3 - <<PY "$_state_target"
import sys, yaml
with open(sys.argv[1]) as f:
    d = yaml.safe_load(f) or {}
print(f"status:  {d.get('status', '?')}")
print(f"task:    {d.get('task', '~')}")
print(f"phase:   {d.get('phase', '~')}")
print(f"step:    {d.get('step', '~')}")
print(f"note:    {d.get('note', '~')}")
pers = d.get('personas') or {}
for name, info in pers.items():
    last = info.get('last_meeting', '?')
    since = info.get('sessions_since', '?')
    print(f"persona {name}: last {last}, sessions_since {since}")
active = d.get('active_subsessions') or []
print(f"active subsessions: {len(active)}")
for s in active:
    print(f"  - {s.get('role')} / {s.get('session_id')} / PID {s.get('pid')}")
history = d.get('history') or []
print(f"history entries: {len(history)}")
if history:
    last = history[-1]
    print(f"  last task: {last.get('task')} closed at {last.get('closed_at')}")
PY

  # Lock state
  if [[ -f "$LEADV2_LOCK" ]]; then
    local pid=$(cat "$LEADV2_LOCK")
    if kill -0 "$pid" 2>/dev/null; then
      echo "lock: held by PID $pid (active)"
    else
      echo "lock: stale (PID $pid dead)"
    fi
  else
    echo "lock: none"
  fi

  # Daemon
  if [[ -f /tmp/leadv2-daemon.pid ]]; then
    local dpid=$(cat /tmp/leadv2-daemon.pid)
    if kill -0 "$dpid" 2>/dev/null; then
      echo "daemon: running PID $dpid"
    fi
  fi

  # Cost
  leadv2_cost_check
}

# ── Codex availability check ──────────────────────────────────────────────
leadv2_codex_ready() {
  ~/.claude/scripts/codex-task.sh setup 2>&1 | grep -q "Status: ready"
}

# ── Deploy helpers for both VPS ───────────────────────────────────────────
# VPS constants are loaded from .claude/leadv2-overrides/state-paths.yaml
# (nik_host, nik_repo, nik_root, respiro_host, respiro_repo, respiro_root)
# via _lv2_load_paths(). Call _lv2_load_paths before using these variables.
# PE values live in state-paths.yaml; other repos leave these keys absent.
# shellcheck disable=SC2034  # exported for VPS helper callers

# Deploy via project-specific override script.
# Reads .claude/leadv2-overrides/deploy.sh, executes with LEAD_V2_TASK_ID env.
# Returns deploy.sh's exit code (0 = success). If override missing, returns 2.
leadv2_deploy_via_override() {
  local project_root override
  project_root="${CLAUDE_PROJECT_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
  override="$project_root/.claude/leadv2-overrides/deploy.sh"

  # Call site 4 of 4 for leadv2_dry_run_guard (D5 single chokepoint).
  if leadv2_dry_run_guard "deploy via $override"; then
    return 0
  fi

  if [[ ! -x "$override" ]]; then
    echo "[helpers] deploy override not found or not executable: $override" >&2
    echo "[helpers] run /leadv2 first to scaffold overrides, then fill in deploy.sh" >&2
    return 2
  fi

  if "$override"; then
    echo "[helpers] deploy: ✓"
    return 0
  else
    local rc=$?
    echo "[helpers] deploy failed (exit $rc)" >&2
    return "$rc"
  fi
}

# ── Atomic YAML write (PO-057) ────────────────────────────────────────────
#
# Write YAML content to a file atomically: write to a tmp sibling, sync,
# then rename into place. Prevents partial-file reads if writer crashes.
# Immediately validates the written file against a schema using
# leadv2_validate_handoff. Returns 2 on schema violation so callers can
# distinguish schema errors from I/O errors.
#
# Usage:
#   _atomic_write_yaml <path> <content> [<schema>]
#
# Arguments:
#   path    — destination file (parent dir must exist or will be created)
#   content — YAML string to write
#   schema  — optional; one of: context | build_summary | review_disposition
#             If omitted or empty, only syntactic YAML validity is checked.
#
# Exit codes:
#   0 — written + validated
#   1 — I/O or syntactic YAML error
#   2 — schema validation failed (file was written but content is invalid)
#
# Required YAML fields per schema (canonical reference; see
# platform/leadv2/handoff_schemas.py for machine-readable definitions):
#
#   context:
#     task.id, task.class, task.mission, task.started_at,
#     decisions (list), off_limits (list), plan.steps (list)
#
#   build_summary:
#     verdict (APPROVE|REVISE|NEEDS-INFO|BLOCK),
#     summary_for_lead (string ≤30 words)
#
#   review_disposition:
#     verdict (APPROVE|REVISE|NEEDS-INFO|BLOCK),
#     summary_for_lead (string ≤30 words),
#     findings (list)
#
_atomic_write_yaml() {
  local path="$1"
  local content="$2"
  local schema="${3:-}"

  local dir
  dir="$(dirname "$path")"
  mkdir -p "$dir"

  # Write to a tmp sibling so mv is atomic on the same filesystem.
  # P0 portable-temp fix: BSD mktemp only randomizes a trailing XXXXXX run; a
  # literal ".yaml" suffix after it is not randomized -> deterministic
  # collision. Extension is not load-bearing on this scratch file.
  local tmp
  tmp="$(mktemp "${dir}/.atomic_write_XXXXXX")" || {
    printf '[helpers] _atomic_write_yaml: mktemp failed in %s\n' "$dir" >&2
    return 1
  }

  # Trap to clean up tmp on unexpected exit.
  local _aw_cleanup_tmp="$tmp"
  trap 'rm -f "$_aw_cleanup_tmp"' RETURN

  printf -- '%s\n' "$content" > "$tmp" || {
    printf -- '[helpers] _atomic_write_yaml: write to tmp failed: %s\n' "$tmp" >&2
    return 1
  }

  # Sync to ensure data hits disk before rename.
  sync "$tmp" 2>/dev/null || true

  # Rename into place (atomic on POSIX).
  mv -f "$tmp" "$path" || {
    printf -- '[helpers] _atomic_write_yaml: mv failed: %s -> %s\n' "$tmp" "$path" >&2
    return 1
  }

  # Syntactic YAML check always.
  if ! leadv2_validate_yaml "$path" >/dev/null 2>&1; then
    printf -- '[helpers] _atomic_write_yaml: YAML syntax invalid: %s\n' "$path" >&2
    return 1
  fi

  # Schema validation if schema arg provided.
  if [[ -n "$schema" ]]; then
    if ! leadv2_validate_handoff "$path" "$schema" 2>&1; then
      printf -- '[helpers] _atomic_write_yaml: schema "%s" invalid: %s\n' "$schema" "$path" >&2
      return 2
    fi
  fi

  return 0
}

# ── Probe result validator (PO-058) ──────────────────────────────────────
#
# Validate a verify-probe-result.yaml file against the contract defined in
# docs/specs/leadv2-verify-contract.md.
#
# Required fields:
#   outcome       — enum: probe_ok | probe_timeout | probe_negative
#   evidence      — non-empty string
#   attempted_at  — ISO-8601 timestamp
#   latency_ms    — non-negative integer
#   signal_source — enum: log | endpoint | supabase | file | systemd
#
# Usage:
#   _validate_probe_result <yaml_path>
#
# Exit codes:
#   0 — valid
#   1 — invalid (error printed to stderr)
#   2 — file not found
#
_validate_probe_result() {
  local path="$1"

  [[ -f "$path" ]] || {
    printf -- '[helpers] _validate_probe_result: file not found: %s\n' "$path" >&2
    return 2
  }

  _leadv2_check_python_version || return 1

  python3 - "$path" <<'PYEOF'
import sys, yaml

path = sys.argv[1]
try:
    with open(path) as fh:
        d = yaml.safe_load(fh) or {}
except Exception as e:
    print(f"[helpers] probe result YAML parse error: {e}", file=sys.stderr)
    sys.exit(1)

errors = []

# outcome
valid_outcomes = {"probe_ok", "probe_timeout", "probe_negative"}
outcome = d.get("outcome")
if outcome not in valid_outcomes:
    errors.append(f"outcome must be one of {sorted(valid_outcomes)}, got: {outcome!r}")

# evidence
evidence = d.get("evidence")
if not isinstance(evidence, str) or not evidence.strip():
    errors.append(f"evidence must be a non-empty string, got: {evidence!r}")

# attempted_at
attempted_at = d.get("attempted_at")
if not attempted_at:
    errors.append("attempted_at is required (ISO-8601 timestamp)")
else:
    import re
    if not re.match(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}', str(attempted_at)):
        errors.append(f"attempted_at must be ISO-8601, got: {attempted_at!r}")

# latency_ms
latency_ms = d.get("latency_ms")
if not isinstance(latency_ms, (int, float)) or latency_ms < 0:
    errors.append(f"latency_ms must be a non-negative number, got: {latency_ms!r}")

# signal_source
valid_sources = {"log", "endpoint", "supabase", "file", "systemd"}
signal_source = d.get("signal_source")
if signal_source not in valid_sources:
    errors.append(f"signal_source must be one of {sorted(valid_sources)}, got: {signal_source!r}")

if errors:
    for e in errors:
        print(f"[helpers] probe result invalid: {e}", file=sys.stderr)
    sys.exit(1)

sys.exit(0)
PYEOF
}

# ── Task-scoped state helpers (M1: multi-session foundation) ──────────────
# All functions respect LEADV2_TASK_ID env var.
# If LEADV2_TASK_ID is unset/empty → fall back to legacy global paths.
# Set PROJECT_ROOT before sourcing, or it defaults to $(pwd).

leadv2_task_id() {
  # Echo current task id; empty string when not set.
  printf -- '%s' "${LEADV2_TASK_ID:-}"
}

leadv2_task_dir() {
  # Echo absolute path to <tasks-dir>/<id>/
  # Uses LEADV2_TASKS_DIR if set (populated by _lv2_load_paths from state-paths.yaml
  # leadv2_tasks_dir override); falls back to docs/leadv2/tasks for backward compat.
  # Accepts task id from $1 OR LEADV2_TASK_ID env var ($1 takes priority).
  # Creates the directory if it does not yet exist.
  # Prints nothing when no task id is available — caller must handle fallback.
  local tid
  tid="${1:-${LEADV2_TASK_ID:-}}"
  if [[ -z "$tid" ]]; then
    printf -- ''
    return 0
  fi
  local _tasks_base
  _tasks_base="${LEADV2_TASKS_DIR:-${LEADV2_PROJECT_ROOT}/docs/leadv2/tasks}"
  local dir
  dir="${_tasks_base}/${tid}"
  mkdir -p "$dir"
  printf -- '%s' "$dir"
}

leadv2_state_path() {
  # Returns path to the STATE.md for the current task.
  # Task-scoped when LEADV2_TASK_ID is set; legacy global path otherwise.
  # Respects LEADV2_TASKS_DIR override (set by _lv2_load_paths from state-paths.yaml).
  local tid
  tid="${LEADV2_TASK_ID:-}"
  if [[ -n "$tid" ]]; then
    local _tasks_base dir
    _tasks_base="${LEADV2_TASKS_DIR:-${LEADV2_PROJECT_ROOT}/docs/leadv2/tasks}"
    dir="${_tasks_base}/${tid}"
    mkdir -p "$dir"
    printf -- '%s/STATE.md' "$dir"
  else
    printf -- '%s/docs/LEAD_V2_STATE.md' "${LEADV2_PROJECT_ROOT}"
  fi
}

leadv2_live_path() {
  # Returns path to the LIVE.md for the current task.
  # Task-scoped when LEADV2_TASK_ID is set; legacy global path otherwise.
  local tid
  tid="${LEADV2_TASK_ID:-}"
  if [[ -n "$tid" ]]; then
    local dir
    dir="${LEADV2_PROJECT_ROOT}/docs/leadv2/tasks/${tid}"
    mkdir -p "$dir"
    printf -- '%s/LIVE.md' "$dir"
  else
    printf -- '%s/docs/LEAD_V2_LIVE.md' "${LEADV2_PROJECT_ROOT}"
  fi
}

leadv2_lock_path() {
  # Returns path to the lockfile for the current task.
  # Task-scoped when LEADV2_TASK_ID is set; legacy /tmp/leadv2-daemon.lock otherwise.
  local tid
  tid="${LEADV2_TASK_ID:-}"
  if [[ -n "$tid" ]]; then
    local dir
    dir="${LEADV2_PROJECT_ROOT}/docs/leadv2/tasks/${tid}"
    mkdir -p "$dir"
    printf -- '%s/lock' "$dir"
  else
    printf -- '/tmp/leadv2-daemon.lock'
  fi
}

# ── Active task registry helpers ──────────────────────────────────────────
# docs/leadv2/active.md — Markdown table of running tasks.
# Format:
#   | task_id | started_at | phase | pid | session_label |
#   |---|---|---|---|---|
#   | PO-022 | 2026-04-26T12:00:00Z | verify | 12345 | nik-respiro |
#
# All writes use write-temp+rename for atomicity.
# Row operations are serialised via Python fcntl.flock (works on Linux + macOS).
# flock(2) is called by python3 which is always present; avoids the Linux-only
# `flock` util that is absent on macOS BSD base.

_leadv2_active_file() {
  printf -- '%s/docs/leadv2/active.md' "${LEADV2_PROJECT_ROOT}"
}

_leadv2_active_lockfile() {
  printf -- '%s/docs/leadv2/active.md.lock' "${LEADV2_PROJECT_ROOT}"
}

_leadv2_active_ensure_header() {
  # Create the active.md with header if it does not yet exist.
  local active
  active="$(_leadv2_active_file)"
  mkdir -p "$(dirname "$active")"
  if [[ ! -f "$active" ]]; then
    printf -- '| task_id | started_at | phase | pid | session_label |\n' > "$active"
    printf -- '|---|---|---|---|---|\n' >> "$active"
  fi
}

# _leadv2_active_py_lock <lockfile> <active_file> <op> [args...]
# Runs the critical section inside python3 using fcntl.flock for portability.
# op: register <task_id> <ts> <phase> <pid> <session_label>
#     update_phase <task_id> <new_phase>
#     unregister <task_id>
#
# H1 fix: lock is acquired BEFORE any existence check or file creation.
#   The header (if missing) is written inside the locked section.
# H3 fix: register refreshes rows with dead PIDs rather than silently
#   treating them as successful registrations.
_leadv2_active_py_lock() {
  python3 - "$@" <<'PYEOF'
import sys, os, fcntl, tempfile

lockfile_path = sys.argv[1]
active_path   = sys.argv[2]
op            = sys.argv[3]
args          = sys.argv[4:]

HEADER = (
    "| task_id | started_at | phase | pid | session_label |\n"
    "|---|---|---|---|---|\n"
)

def _pid_alive(pid_str: str) -> bool:
    """Return True if the process with the given PID string is alive."""
    try:
        pid = int(pid_str)
        os.kill(pid, 0)
        return True
    except (ValueError, ProcessLookupError, PermissionError):
        return False

# H1 fix: acquire the exclusive flock BEFORE touching the file at all —
# including before the existence check and header creation.
os.makedirs(os.path.dirname(lockfile_path), exist_ok=True)
lock_fd = open(lockfile_path, "a+")
try:
    fcntl.flock(lock_fd, fcntl.LOCK_EX)

    # Create active.md with header inside the locked section (H1).
    os.makedirs(os.path.dirname(active_path), exist_ok=True)
    if not os.path.exists(active_path):
        with open(active_path, "w", encoding="utf-8") as fh:
            fh.write(HEADER)

    with open(active_path, encoding="utf-8") as fh:
        lines = fh.readlines()

    if op == "register":
        task_id, ts, phase, pid, session_label = args

        # H3 fix: find any existing row for task_id and check PID liveness.
        existing_idx = None
        existing_pid = None
        for i, ln in enumerate(lines):
            if (ln.startswith("|") and "|---|" not in ln
                    and "task_id" not in ln
                    and f"| {task_id} |" in ln):
                cols = [c.strip() for c in ln.split("|")]
                if len(cols) >= 6:
                    existing_idx = i
                    existing_pid = cols[4]  # pid column (0-indexed after split)
                break

        if existing_idx is not None:
            if _pid_alive(existing_pid or ""):
                # Live row already present — idempotent, skip.
                sys.exit(0)
            else:
                # Stale row (dead PID) — refresh in place (H3).
                lines[existing_idx] = (
                    f"| {task_id} | {ts} | {phase} | {pid} | {session_label} |\n"
                )
        else:
            lines.append(f"| {task_id} | {ts} | {phase} | {pid} | {session_label} |\n")

    elif op == "update_phase":
        task_id, new_phase = args
        out = []
        for line in lines:
            if (line.startswith("|") and "|---|" not in line
                    and "task_id" not in line):
                cols = [c.strip() for c in line.split("|")]
                if len(cols) >= 6 and cols[1] == task_id:
                    cols[3] = new_phase
                    line = "| " + " | ".join(cols[1:-1]) + " |\n"
            out.append(line)
        lines = out

    elif op == "unregister":
        task_id = args[0]
        lines = [
            ln for ln in lines
            if not (ln.startswith("|") and "|---|" not in ln
                    and "task_id" not in ln
                    and f"| {task_id} |" in ln)
        ]

    # Write atomically: temp file + rename
    dir_ = os.path.dirname(active_path)
    tmp_fd, tmp_path = tempfile.mkstemp(dir=dir_, suffix=".tmp")
    try:
        with os.fdopen(tmp_fd, "w", encoding="utf-8") as tf:
            tf.writelines(lines)
        os.replace(tmp_path, active_path)
    except Exception:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise

finally:
    fcntl.flock(lock_fd, fcntl.LOCK_UN)
    lock_fd.close()
PYEOF
}

leadv2_active_register() {
  # Atomic add of a row to docs/leadv2/active.md.
  # Args: phase
  # H1 fix: lock is acquired BEFORE the existence check and header write
  #   (both happen inside _leadv2_active_py_lock now).
  # H3 fix: stale rows (dead PID) are refreshed rather than silently accepted.
  local phase="${1:-intake}"
  local tid
  tid="${LEADV2_TASK_ID:-}"
  if [[ -z "$tid" ]]; then
    printf -- '[helpers] leadv2_active_register: LEADV2_TASK_ID not set — skipping\n' >&2
    return 0
  fi

  local ts pid_val session_label
  ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  pid_val="$$"
  session_label="${LEADV2_SESSION_LABEL:-$(hostname -s 2>/dev/null || printf -- 'unknown')}"

  local active lockfile
  active="$(_leadv2_active_file)"
  lockfile="$(_leadv2_active_lockfile)"

  # Do NOT call _leadv2_active_ensure_header here: header creation is now
  # serialised inside _leadv2_active_py_lock (H1 fix).
  _leadv2_active_py_lock \
    "$lockfile" "$active" register \
    "$tid" "$ts" "$phase" "$pid_val" "$session_label"
}

leadv2_active_update_phase() {
  # Atomically update the phase column for our task_id row.
  # Args: new_phase
  local new_phase="${1:-}"
  local tid
  tid="${LEADV2_TASK_ID:-}"
  if [[ -z "$tid" ]] || [[ -z "$new_phase" ]]; then
    return 0
  fi

  local active lockfile
  active="$(_leadv2_active_file)"
  lockfile="$(_leadv2_active_lockfile)"

  [[ -f "$active" ]] || return 0

  _leadv2_active_py_lock "$lockfile" "$active" update_phase "$tid" "$new_phase"

  if [[ -f "docs/handoff/${tid}/cost-estimate.yaml" ]]; then
    # FIX-7: log exit code before returning 1 so caller can diagnose budget gate failures
    bash "$(dirname "${BASH_SOURCE[0]}")/phase-advance.sh" --task-id "$tid" --phase "$new_phase" || {
      echo "[BUDGET_GATE] phase-advance.sh exited $? for task ${tid} phase ${new_phase}" >&2
      return 1
    }
  fi
}

leadv2_active_unregister() {
  # Atomically remove the row for the current task_id.
  local tid
  tid="${LEADV2_TASK_ID:-}"
  if [[ -z "$tid" ]]; then
    return 0
  fi

  local active lockfile
  active="$(_leadv2_active_file)"
  lockfile="$(_leadv2_active_lockfile)"

  [[ -f "$active" ]] || return 0

  _leadv2_active_py_lock "$lockfile" "$active" unregister "$tid"
}


leadv2_active_list() {
  # Print currently-active task rows (atomic read).
  local active
  active="$(_leadv2_active_file)"
  [[ -f "$active" ]] && cat "$active" || printf -- '(no active.md)\n'
}

# Registry sourced LAST so active.yaml functions override active.md legacy stubs above.
# ── Active registry (multi-session YAML-backed store) ─────────────────────
# Source after LEADV2_PROJECT_ROOT is set so the registry inherits the path.
# Resolution: lv2_script (needs CLAUDE_PLUGIN_ROOT) → BASH_SOURCE canonical-dir fallback
# so the registry loads even when CLAUDE_PLUGIN_ROOT is unset.
# BASH_SOURCE[0] may be a symlink (repo copy of helpers.sh); resolve to canonical dir
# via realpath/readlink -f so we get the source dir, not the symlink dir.
# shellcheck source=leadv2-active-registry.sh
_LEADV2_HELPERS_CANONICAL="$(realpath "${BASH_SOURCE[0]}" 2>/dev/null \
  || readlink -f "${BASH_SOURCE[0]}" 2>/dev/null \
  || printf -- '%s' "${BASH_SOURCE[0]}")"
_LEADV2_REGISTRY="$(lv2_script leadv2-active-registry.sh 2>/dev/null \
  || printf -- '%s' "$(dirname "${_LEADV2_HELPERS_CANONICAL}")/leadv2-active-registry.sh")"
if [[ -f "$_LEADV2_REGISTRY" ]]; then
  source "$_LEADV2_REGISTRY"
else
  printf -- '[helpers] WARNING: leadv2-active-registry.sh not found — active.yaml writes will use legacy .md stub\n' >&2
fi
unset _LEADV2_REGISTRY _LEADV2_HELPERS_CANONICAL

# ── Settings.local.json refcount (M3: concurrent subsession safety) ──────────
# Sidecar file: .claude/settings.local.json.leadv2-refcount
# Format:
#   count: N
#   sessions:
#   - id: <uuid> pid: <pid> started: <ISO>
#   - id: <uuid> pid: <pid> started: <ISO>
#
# All mutations are serialised via python3 fcntl.flock (POSIX; works on Linux + macOS).
# The GNU `flock` utility is absent on macOS, so we use fcntl in Python — consistent
# with the existing _leadv2_active_py_lock pattern in this file.
#
# Backup sentinel when no prior settings.local.json existed:
#   .claude/settings.local.json.leadv2-bak.NONE  (presence = no original file)
#   .claude/settings.local.json.leadv2-bak       (real backup when original existed)

_leadv2_refcount_file() {
  printf -- '%s/.claude/settings.local.json.leadv2-refcount' "${LEADV2_PROJECT_ROOT}"
}

_leadv2_settings_file() {
  printf -- '%s/.claude/settings.local.json' "${LEADV2_PROJECT_ROOT}"
}

_leadv2_bak_file() {
  printf -- '%s/.claude/settings.local.json.leadv2-bak' "${LEADV2_PROJECT_ROOT}"
}

_leadv2_bak_none_sentinel() {
  printf -- '%s/.claude/settings.local.json.leadv2-bak.NONE' "${LEADV2_PROJECT_ROOT}"
}

_leadv2_hook_path() {
  printf -- '%s/.claude/hooks/leadv2-compress-tool-output' "${LEADV2_PROJECT_ROOT}"
}

# _leadv2_settings_py_lock <op> [args...]
# Runs a critical section with fcntl.flock over the refcount sidecar.
# ops:
#   acquire  <session_id> <pid> <settings_path> <hook_path> <bak_path> <bak_none_sentinel>
#   release  <session_id> <settings_path> <bak_path> <bak_none_sentinel>
#   watchdog <settings_path> <hook_path>   (purge dead-PID sessions, used before acquire)
_leadv2_settings_py_lock() {
  local refcount_file
  refcount_file="$(_leadv2_refcount_file)"

  python3 - "$refcount_file" "$@" <<'PYEOF'
import sys, os, json, fcntl, tempfile, datetime
from pathlib import Path

refcount_path = Path(sys.argv[1])
op            = sys.argv[2]
args          = sys.argv[3:]

# ── helpers ──────────────────────────────────────────────────────────────
def _read_state(path: Path) -> dict:
    if not path.exists():
        return {"count": 0, "sessions": []}
    text = path.read_text(encoding="utf-8").strip()
    if not text:
        return {"count": 0, "sessions": []}
    # Parse simple YAML-like format (no pyyaml dep required)
    state: dict = {"count": 0, "sessions": []}
    lines = text.splitlines()
    i = 0
    while i < len(lines):
        ln = lines[i].rstrip()
        if ln.startswith("count:"):
            try:
                state["count"] = int(ln.split(":", 1)[1].strip())
            except ValueError:
                state["count"] = 0
        elif ln.strip().startswith("- id:"):
            # parse "- id: X pid: Y started: Z"
            # Tokens: ["id:", "X", "pid:", "Y", "started:", "Z"]
            # Keys end with ":" and the following token is the value.
            part = ln.strip()[2:].strip()  # strip "- "
            entry: dict = {}
            tokens = part.split()
            j = 0
            while j < len(tokens):
                tok = tokens[j]
                if tok.endswith(":"):
                    key = tok[:-1]  # strip trailing ":"
                    val = tokens[j + 1] if j + 1 < len(tokens) else ""
                    entry[key] = val
                    j += 2
                else:
                    j += 1
            if "id" in entry:
                state["sessions"].append(entry)
        i += 1
    return state

def _write_state(path: Path, state: dict) -> None:
    dir_ = path.parent
    dir_.mkdir(parents=True, exist_ok=True)
    lines = [f"count: {state['count']}\n", "sessions:\n"]
    for s in state["sessions"]:
        pid   = s.get("pid", "?")
        sid   = s.get("id", "?")
        ts    = s.get("started", "?")
        birth = s.get("birth", "")
        lines.append(f"- id: {sid} pid: {pid} started: {ts} birth: {birth}\n")
    tmp_fd, tmp_path = tempfile.mkstemp(dir=str(dir_), suffix=".tmp")
    try:
        with os.fdopen(tmp_fd, "w", encoding="utf-8") as fh:
            fh.writelines(lines)
        os.replace(tmp_path, str(path))
    except Exception:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise

def _get_proc_birth(pid: int) -> str:
    """Return a stable birth-time string for *pid*, or '' on failure."""
    import subprocess as _sp, platform as _pl
    try:
        if _pl.system() == "Linux":
            # /proc/<pid>/stat field 22 = start time in jiffies (monotone, unique per boot)
            stat_path = Path(f"/proc/{pid}/stat")
            if stat_path.exists():
                fields = stat_path.read_text().split()
                return fields[21] if len(fields) > 21 else ""
        # macOS / fallback: use ps -o lstart=
        r = _sp.run(
            ["ps", "-o", "lstart=", "-p", str(pid)],
            capture_output=True, text=True, timeout=3
        )
        return r.stdout.strip()
    except Exception:
        return ""


def _pid_alive(pid_str: str, birth_time: str = "") -> bool:
    """Return True only when *pid_str* process is alive AND birth time matches (if provided)."""
    try:
        pid = int(pid_str)
        os.kill(pid, 0)
    except (ValueError, ProcessLookupError, PermissionError):
        return False
    if birth_time:
        return _get_proc_birth(pid) == birth_time
    return True

def _merge_hook(settings_path: Path, hook_cmd: str) -> None:
    """Merge our PostToolUse hook entry into settings.local.json."""
    if settings_path.exists():
        try:
            data = json.loads(settings_path.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            corrupt = settings_path.with_suffix(".json.leadv2-corrupt")
            corrupt.write_text(settings_path.read_text(encoding="utf-8"))
            data = {}
    else:
        data = {}

    hooks = data.setdefault("hooks", {})
    post_tool_use = hooks.setdefault("PostToolUse", [])

    already = any(
        hook_cmd in str(group.get("hooks", []))
        for group in post_tool_use
        if isinstance(group, dict)
    )
    if not already:
        our_entry = {
            "hooks": [{"type": "command", "command": hook_cmd, "timeout": 10}]
        }
        post_tool_use.append(our_entry)

    settings_path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")

def _hook_already_installed(settings_path: Path, hook_cmd: str) -> bool:
    """Return True if our hook is present in settings.local.json PostToolUse."""
    if not settings_path.exists():
        return False
    try:
        data = json.loads(settings_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        return False
    post = data.get("hooks", {}).get("PostToolUse", [])
    return any(
        hook_cmd in str(g.get("hooks", []))
        for g in post
        if isinstance(g, dict)
    )

# ── lock ─────────────────────────────────────────────────────────────────
lock_path = Path(str(refcount_path) + ".lock")
lock_path.parent.mkdir(parents=True, exist_ok=True)
lock_fd = open(str(lock_path), "a+")
try:
    fcntl.flock(lock_fd, fcntl.LOCK_EX)

    if op == "watchdog":
        # Purge sessions whose PID is no longer alive (with birth-time anti-reuse check).
        settings_path = Path(args[0])
        bak_path      = Path(args[1])
        bak_none      = Path(args[2])
        state = _read_state(refcount_path)
        alive = [
            s for s in state["sessions"]
            if _pid_alive(s.get("pid", "0"), s.get("birth", ""))
        ]
        dead_count = len(state["sessions"]) - len(alive)
        if dead_count > 0:
            state["sessions"] = alive
            state["count"] = max(0, len(alive))
            if state["count"] == 0:
                # All sessions dead — restore settings then clear sidecar.
                # H1 fix: run the same restore logic as the last-release path.
                if bak_none.exists():
                    settings_path.unlink(missing_ok=True)
                    bak_none.unlink(missing_ok=True)
                    print("[settings-refcount] watchdog: removed temporary settings.local.json (sentinel restore)", file=sys.stderr)
                elif bak_path.exists():
                    import shutil
                    shutil.copy2(str(bak_path), str(settings_path))
                    bak_path.unlink(missing_ok=True)
                    print("[settings-refcount] watchdog: restored settings.local.json from backup", file=sys.stderr)
                else:
                    print("[settings-refcount] watchdog: WARNING: no backup found, leaving settings as-is", file=sys.stderr)
                # K1 fix: only clear sidecar contents; never unlink the lock inode.
                refcount_path.unlink(missing_ok=True)
                print(f"[settings-refcount] watchdog: purged {dead_count} dead sessions, count→0", file=sys.stderr)
            else:
                _write_state(refcount_path, state)
                print(f"[settings-refcount] watchdog: purged {dead_count} dead sessions, count→{state['count']}", file=sys.stderr)
        sys.exit(0)

    elif op == "acquire":
        session_id, pid, settings_path_s, hook_path_s, bak_path_s, bak_none_s = args
        settings_path = Path(settings_path_s)
        hook_path     = Path(hook_path_s)
        bak_path      = Path(bak_path_s)
        bak_none      = Path(bak_none_s)

        state = _read_state(refcount_path)

        # Orphan detection: if count>0 but hook not actually in settings,
        # something went wrong in a prior session — reset cleanly.
        if state["count"] > 0 and not _hook_already_installed(settings_path, str(hook_path)):
            print("[settings-refcount] orphan detected: count>0 but hook absent — resetting", file=sys.stderr)
            state = {"count": 0, "sessions": []}
            refcount_path.unlink(missing_ok=True)

        if state["count"] == 0:
            # First acquirer — backup and install hook.
            if settings_path.exists():
                import shutil
                shutil.copy2(str(settings_path), str(bak_path))
                bak_none.unlink(missing_ok=True)
                print(f"[settings-refcount] backed up {settings_path.name} → {bak_path.name}", file=sys.stderr)
            else:
                bak_none.touch()
                bak_path.unlink(missing_ok=True)
                print("[settings-refcount] no original settings — sentinel written", file=sys.stderr)
            _merge_hook(settings_path, str(hook_path))
            print("[settings-refcount] hook installed (first acquirer)", file=sys.stderr)

        # Register session — capture birth time for PID-reuse detection (H2 fix).
        ts    = datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None).strftime("%Y-%m-%dT%H:%M:%SZ")
        birth = _get_proc_birth(int(pid))
        state["sessions"].append({"id": session_id, "pid": pid, "started": ts, "birth": birth})
        state["count"] = len(state["sessions"])
        _write_state(refcount_path, state)
        print(f"[settings-refcount] acquire: session={session_id} count→{state['count']}", file=sys.stderr)
        sys.exit(0)

    elif op == "release":
        session_id, settings_path_s, bak_path_s, bak_none_s = args
        settings_path = Path(settings_path_s)
        bak_path      = Path(bak_path_s)
        bak_none      = Path(bak_none_s)

        state = _read_state(refcount_path)
        state["sessions"] = [s for s in state["sessions"] if s.get("id") != session_id]
        state["count"] = max(0, len(state["sessions"]))
        print(f"[settings-refcount] release: session={session_id} count→{state['count']}", file=sys.stderr)

        if state["count"] == 0:
            # Last release — restore settings.
            if bak_none.exists():
                # Original didn't exist — remove settings.
                settings_path.unlink(missing_ok=True)
                bak_none.unlink(missing_ok=True)
                print("[settings-refcount] removed temporary settings.local.json (sentinel restore)", file=sys.stderr)
            elif bak_path.exists():
                import shutil
                shutil.copy2(str(bak_path), str(settings_path))
                bak_path.unlink(missing_ok=True)
                print("[settings-refcount] restored settings.local.json from backup", file=sys.stderr)
            else:
                print("[settings-refcount] WARNING: no backup found on last release!", file=sys.stderr)
            # K1 fix: only clear sidecar; never unlink the lock inode (split-lock race prevention).
            refcount_path.unlink(missing_ok=True)
        else:
            _write_state(refcount_path, state)
        sys.exit(0)

    else:
        print(f"[settings-refcount] unknown op: {op}", file=sys.stderr)
        sys.exit(1)

finally:
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_UN)
        lock_fd.close()
    except Exception:
        pass
PYEOF
}

leadv2_settings_watchdog() {
  # Purge sidecar entries whose registered PID is no longer alive.
  # Call this ONCE at the start of a new wrapper invocation, before acquire.
  # Running watchdog separately (not inside acquire) avoids the test-isolation
  # problem where the acquire subprocess's own PID is ephemeral.
  # H1 fix: pass bak_path + bak_none so count→0 can restore settings.
  _leadv2_settings_py_lock watchdog \
    "$(_leadv2_settings_file)" \
    "$(_leadv2_bak_file)" \
    "$(_leadv2_bak_none_sentinel)" || true
}

leadv2_settings_acquire() {
  # Install PostToolUse hook in settings.local.json when counter goes 0→1.
  # When counter is already ≥1, just bumps the refcount — no file mutation.
  # Args: <session_id>
  # NOTE: call leadv2_settings_watchdog BEFORE this in the wrapper script to
  # purge dead-PID orphans; watchdog is intentionally NOT called here so that
  # sequential test calls do not clobber each other's entries.
  local session_id="${1:?leadv2_settings_acquire: session_id required}"
  local hook_path
  hook_path="$(_leadv2_hook_path)"
  if [[ ! -x "$hook_path" ]]; then
    printf -- '[settings-refcount] hook not executable: %s\n' "$hook_path" >&2
    return 1
  fi
  _leadv2_settings_py_lock acquire \
    "$session_id" \
    "$$" \
    "$(_leadv2_settings_file)" \
    "$hook_path" \
    "$(_leadv2_bak_file)" \
    "$(_leadv2_bak_none_sentinel)"
}

leadv2_settings_release() {
  # Decrement refcount. Restores settings.local.json when count reaches 0.
  # H3 fix: no longer swallows failures with || true.
  # On failure: writes a sentinel file so operators/CI can detect cleanup problems.
  # Always returns the original wrapped command's exit code (caller's concern).
  # Args: <session_id>
  local session_id="${1:?leadv2_settings_release: session_id required}"
  local cleanup_rc=0
  _leadv2_settings_py_lock release \
    "$session_id" \
    "$(_leadv2_settings_file)" \
    "$(_leadv2_bak_file)" \
    "$(_leadv2_bak_none_sentinel)" || cleanup_rc=$?
  if [[ "$cleanup_rc" -ne 0 ]]; then
    local sentinel
    sentinel="${LEADV2_PROJECT_ROOT}/.claude/settings.local.json.leadv2-cleanup-failed.$$"
    printf -- '[settings-refcount] CLEANUP FAILED: release returned %d for session %s\n' \
      "$cleanup_rc" "$session_id" >&2
    printf -- 'cleanup_rc=%d\nsession_id=%s\npid=%d\n' \
      "$cleanup_rc" "$session_id" "$$" > "$sentinel" 2>/dev/null || true
  fi
  return "$cleanup_rc"
}

# ── task queue claim/release wrappers (lane-based, M2: multi-session safety) ─
# These call leadv2-queue-claim.sh / leadv2-queue-release.sh using LEADV2_TASK_ID.
# On successful claim, LEADV2_PO_LANE and LEADV2_PO_ITEM_ID are exported.
# Source .claude/scripts/leadv2-helpers.sh before using.

leadv2_po_claim() {
  # Claim the next available task queue item across all lanes (recovery → action → intelligence).
  # Optional arg $1: prefer lane name (exact match tried first, then normal order).
  # Outputs: claimed item id on stdout (legacy contract preserved).
  # On success, exports LEADV2_PO_ITEM_ID and LEADV2_PO_LANE, and writes crash-protection sidecar.
  # Exit 2 = nothing available; other non-zero = error.
  local prefer="${1:-}"
  local claim_script
  claim_script="$(lv2_script leadv2-queue-claim.sh 2>/dev/null || printf -- '%s' "$_LV2_D/leadv2-queue-claim.sh")"
  local claimer="${LEADV2_TASK_ID:?LEADV2_TASK_ID not set}"

  local raw_output rc
  if [[ -n "$prefer" ]]; then
    # Try the preferred lane first
    local preferred_lane="$prefer"
    raw_output=$("$claim_script" --lane "$preferred_lane" --by "$claimer" 2>/dev/null) && rc=0 || rc=$?
    if [[ "$rc" -eq 0 && -n "$raw_output" ]]; then
      # Single-lane result: extract id from YAML output
      local item_id
      item_id=$(printf -- '%s' "$raw_output" | python3 -c "import sys,yaml; items=yaml.safe_load(sys.stdin.read()) or []; print(items[0]['id'] if items else '')" 2>/dev/null || true)
      if [[ -n "$item_id" ]]; then
        LEADV2_PO_LANE="$preferred_lane"
        LEADV2_PO_ITEM_ID="$item_id"
        export LEADV2_PO_LANE LEADV2_PO_ITEM_ID
        leadv2_po_claim_register "${LEADV2_TASK_ID:-}" 2>/dev/null || true
        printf -- '%s\n' "$item_id"
        return 0
      fi
    fi
    # Fall through to normal multi-lane scan if preferred lane had nothing
  fi

  raw_output=$("$claim_script" --by "$claimer" 2>/dev/null) && rc=0 || rc=$?
  if [[ "$rc" -eq 2 ]]; then
    return 2
  fi
  if [[ "$rc" -ne 0 ]]; then
    printf -- '[helpers] leadv2_po_claim: claim script exited %s\n' "$rc" >&2
    return "$rc"
  fi

  # Multi-lane output format: "lane:item_id"
  local lane item_id
  raw_output="$(printf -- '%s' "$raw_output" | tr -d '\n')"
  lane="${raw_output%%:*}"
  item_id="${raw_output#*:}"

  if [[ -z "$lane" || -z "$item_id" ]]; then
    printf -- '[helpers] leadv2_po_claim: unexpected output from claim script: %s\n' "$raw_output" >&2
    rm -f "$_env_file" || true
    return 1
  fi

  LEADV2_PO_LANE="$lane"
  LEADV2_PO_ITEM_ID="$item_id"
  export LEADV2_PO_LANE LEADV2_PO_ITEM_ID
  leadv2_po_claim_register "${LEADV2_TASK_ID:-}" 2>/dev/null || true
  printf -- '%s\n' "$item_id"
}

leadv2_po_lane_for_id() {
  # Resolve which lane contains a given item id.
  # Reads lane field from docs/tasks.yaml via leadv2-tasks-lib.sh.
  # Prints lane name on found, exit 0; exit 1 on not-found or empty lane.
  local _id="${1:?leadv2_po_lane_for_id: item_id required}"
  local _tasks_lib
  _tasks_lib="$(lv2_script leadv2-tasks-lib.sh 2>/dev/null || printf -- '%s' "$_LV2_D/leadv2-tasks-lib.sh")"
  if [[ ! -f "$_tasks_lib" ]]; then return 1; fi
  # shellcheck source=leadv2-tasks-lib.sh
  source "$_tasks_lib"
  local _lane
  _lane=$(leadv2_tasks_by_id "$_id" 2>/dev/null \
    | python3 -c "import sys,yaml; d=(yaml.safe_load(sys.stdin) or [{}])[0]; print(d.get('lane',''))" 2>/dev/null || true)
  if [[ -n "$_lane" ]]; then
    printf -- '%s\n' "$_lane"
    return 0
  fi
  return 1
}

leadv2_po_release() {
  # Release a previously claimed task queue item.
  # Args: <item_id> [<release_status=done|failed|poison|rejected>] [<lane>] [<reject_reason>]
  # Lane resolution order: $3 if non-empty → $LEADV2_PO_LANE env → leadv2_po_lane_for_id $1 → error.
  # reject_reason ($4) is only meaningful for failed/rejected/poison statuses.
  # release_status mapping: done→success, failed→fail, poison→poison, rejected→reject.
  local _item="${1:?leadv2_po_release: item_id required}"
  local _release_status="${2:-done}"
  local _lane_arg="${3:-}"
  local _reject_reason="${4:-}"
  local _release_script
  _release_script="$(lv2_script leadv2-queue-release.sh 2>/dev/null || printf -- '%s' "$_LV2_D/leadv2-queue-release.sh")"

  # Resolve lane: $3 > LEADV2_PO_LANE > lane_for_id fallback
  local _lane="${_lane_arg:-${LEADV2_PO_LANE:-}}"
  if [[ -z "$_lane" ]]; then
    _lane="$(leadv2_po_lane_for_id "$_item" 2>/dev/null)" || true
  fi
  if [[ -z "$_lane" ]]; then
    printf -- '[helpers] leadv2_po_release: lane unknown — pass 3rd arg, set LEADV2_PO_LANE, or ensure item exists in a lane yaml\n' >&2
    return 2
  fi

  # Map release_status → outcome
  local _outcome
  case "$_release_status" in
    done)     _outcome="success" ;;
    failed)   _outcome="fail"    ;;
    poison)   _outcome="poison"  ;;
    rejected) _outcome="reject"  ;;
    *)
      printf -- '[helpers] leadv2_po_release: unknown status "%s" — expected done|failed|poison|rejected\n' "$_release_status" >&2
      return 1
      ;;
  esac

  # After successful release, remove the crash-protection sidecar
  if [[ "$_outcome" == "poison" || "$_outcome" == "reject" ]]; then
    local _reason_arg="${_reject_reason:-$_release_status}"
    "$_release_script" --lane "$_lane" --id "$_item" --outcome "$_outcome" \
      --reject-reason "$_reason_arg"
  else
    "$_release_script" --lane "$_lane" --id "$_item" --outcome "$_outcome"
  fi
  local _rel_rc=$?
  if [[ "$_rel_rc" -eq 0 ]]; then
    leadv2_po_claim_release "${LEADV2_TASK_ID:-}" 2>/dev/null || true
  fi
  return "$_rel_rc"
}

# ── task queue claim sidecar helpers (M2/J3: crash protection) ─────────────
# Sidecar dir: docs/agents/product-owner/.claims/
# Sidecar file: <task_id>.claim  contains: "pid=<pid>\nclaimed_at=<ISO>\n"
#
# Usage in lead session after successful claim:
#   leadv2_po_claim_register "$LEADV2_TASK_ID"
#   trap 'leadv2_po_claim_release "$LEADV2_TASK_ID"' EXIT INT TERM HUP
#
# On next validate run, any sidecar whose PID is dead is automatically released
# by leadv2-queue-sweep.sh (dead-PID scan runs at every sweep tick).

_leadv2_claims_dir() {
  printf -- '%s/docs/agents/product-owner/.claims' "${LEADV2_PROJECT_ROOT}"
}

leadv2_po_claim_register() {
  # Write a sidecar .claim file for the given task_id.
  # Args: <task_id>   (defaults to LEADV2_TASK_ID)
  local tid="${1:-${LEADV2_TASK_ID:-}}"
  if [[ -z "$tid" ]]; then
    printf -- '[helpers] leadv2_po_claim_register: task_id required\n' >&2
    return 1
  fi
  local claims_dir
  claims_dir="$(_leadv2_claims_dir)"
  mkdir -p "$claims_dir"
  local ts
  ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  printf -- 'pid=%s\nclaimed_at=%s\n' "$$" "$ts" > "${claims_dir}/${tid}.claim"
}

leadv2_po_claim_release() {
  # Remove sidecar .claim file for the given task_id.
  # Args: <task_id>   (defaults to LEADV2_TASK_ID)
  local tid="${1:-${LEADV2_TASK_ID:-}}"
  if [[ -z "$tid" ]]; then
    printf -- '[helpers] leadv2_po_claim_release: task_id required\n' >&2
    return 1
  fi
  local claims_dir
  claims_dir="$(_leadv2_claims_dir)"
  rm -f "${claims_dir}/${tid}.claim"
}

# ── Handoff-file compression (M5) ────────────────────────────────────────
# leadv2_compress_handoff <path>
#   If path is YAML → no-op.
#   If path is markdown AND >8KB (or LEADV2_HANDOFF_COMPRESS_THRESHOLD) →
#     writes <stem>.compressed.md adjacent to path, prints its path to stdout.
#   If path is markdown AND ≤8KB → no-op (prints empty string).
#
# Requires Python >=3.10 and pyyaml (same gate as leadv2_validate_handoff).
leadv2_compress_handoff() {
  if [[ $# -ne 1 ]]; then
    printf -- '[helpers] usage: leadv2_compress_handoff <path>\n' >&2
    return 2
  fi
  local path="$1"
  _leadv2_check_python_version || return 1

  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local project_root
  project_root="$(cd "$script_dir/../.." && pwd)"

  python3 - "$path" "$project_root" <<'PYEOF'
import sys
from pathlib import Path

path_arg, project_root = sys.argv[1], sys.argv[2]

# Load handoff_compression without adding platform/ to sys.path
import importlib.util

def _load(name, file_path):
    spec = importlib.util.spec_from_file_location(name, file_path)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)
    return mod

try:
    _load(
        "platform.leadv2.handoff_compression",
        project_root + "/platform/leadv2/handoff_compression.py",
    )
except Exception as exc:
    print(f"[handoff-compress] import error: {exc}", file=sys.stderr)
    sys.exit(1)

from platform.leadv2.handoff_compression import compress_handoff, HandoffCompressionStatus

result = compress_handoff(Path(path_arg))
if result.status == HandoffCompressionStatus.FAILED:
    print(f"[handoff-compress] FAILED: {result.reason}", file=sys.stderr)
    sys.exit(2)
elif result.status == HandoffCompressionStatus.COMPRESSED:
    print(str(result.path))
# SKIPPED_* → print nothing, exit 0
PYEOF
}

# leadv2_read_handoff <path>
#   Reads the compressed twin if it exists, otherwise the original.
#   <path> must be the path to the original file (*.md or *.full.md).
#   Prints file contents to stdout.
#
#   Retry logic (H4): on ENOENT (atomic-replace window), retries up to 3×
#   with 50 ms backoff.  On final failure: emits stderr + returns non-zero.
leadv2_read_handoff() {
  if [[ $# -ne 1 ]]; then
    printf -- '[helpers] usage: leadv2_read_handoff <path>\n' >&2
    return 2
  fi
  local path="$1"

  # Compute compressed twin path:
  #   foo.md        → foo.compressed.md
  #   foo.full.md   → foo.compressed.md  (strip .full suffix first)
  local compressed
  local base="${path%.md}"
  base="${base%.full}"
  compressed="${base}.compressed.md"

  # Determine which file to read (prefer compressed twin)
  local target
  if [[ -f "$compressed" ]]; then
    target="$compressed"
  elif [[ -f "$path" ]]; then
    target="$path"
  else
    target="$path"  # may still fail; retry handles transient ENOENT
  fi

  # Retry loop — handles atomic-replace window (up to 3 attempts, 50ms apart)
  local attempt=0
  local max_attempts=3
  while (( attempt < max_attempts )); do
    if [[ -f "$target" ]]; then
      cat "$target"
      return 0
    fi
    attempt=$(( attempt + 1 ))
    if (( attempt < max_attempts )); then
      sleep 0.05
      # Re-evaluate: twin may have appeared during the replace window
      if [[ -f "$compressed" ]]; then
        target="$compressed"
      fi
    fi
  done

  printf -- '[helpers] leadv2_read_handoff: file not found after %d attempts: %s\n' \
    "$max_attempts" "$target" >&2
  return 1
}

# ── Cost aggregation ─────────────────────────────────────────────────────────
# leadv2_emit_costs <task_id>
#   Calls platform.leadv2.cost_aggregator emit --task-id <id>.
#   Idempotent: rewrites costs.yaml on each call.
#   Exit 0 on success (including empty list), non-zero on internal error.
leadv2_emit_costs() {
  if [[ $# -ne 1 ]]; then
    printf -- '[helpers] usage: leadv2_emit_costs <task_id>\n' >&2
    return 2
  fi
  local task_id="$1"

  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local project_root
  project_root="$(cd "$script_dir/../.." && pwd)"

  # K1 fix: invoke cost_aggregator as a module via python3 -m.
  # The old code called _load(..., "pricing_table.yaml") which is not a Python
  # module — spec_from_file_location returns None for .yaml → always threw.
  # cost_aggregator.py reads pricing_table.yaml as data internally.
  PYTHONPATH="$project_root" python3 -m platform.leadv2.cost_aggregator \
    emit --task-id "$task_id"
  return $?
}

# ── Threshold helpers for pattern promotion / skill synthesis (H3) ───────────
# These replace hardcoded numbers in /leadv2 operator code and skill prose.
# Configurable via env; validated to be non-negative integers; fallback to
# defaults on bad values. An inverted (PROMOTE > SYNTH) configuration causes
# synth to never fire — warn loudly at startup.

leadv2_get_promote_threshold() {
  local v="${LEADV2_REFLECT_PROMOTE_THRESHOLD:-3}"
  [[ "$v" =~ ^[0-9]+$ ]] || { printf -- '3'; return; }
  printf -- '%s' "$v"
}

leadv2_get_synth_threshold() {
  local v="${LEADV2_SKILL_SYNTH_THRESHOLD:-5}"
  [[ "$v" =~ ^[0-9]+$ ]] || { printf -- '5'; return; }
  printf -- '%s' "$v"
}

# Returns 0 (OK) when PROMOTE <= SYNTH; returns 1 and emits WARN when inverted.
leadv2_threshold_warn_if_inverted() {
  local p s
  p=$(leadv2_get_promote_threshold)
  s=$(leadv2_get_synth_threshold)
  if [[ "$p" -gt "$s" ]]; then
    printf -- 'WARN: LEADV2_REFLECT_PROMOTE_THRESHOLD=%s > LEADV2_SKILL_SYNTH_THRESHOLD=%s — synth will never fire\n' \
      "$p" "$s" >&2
    return 1
  fi
  return 0
}

# --- PO-LEADV2-002: pulse-mode + async-question helpers ---

leadv2_pulse_log() {
  # Usage: leadv2_pulse_log <phase> <text>
  [[ "${LEADV2_PULSE_MODE:-0}" == "1" ]] || return 0
  local task_id="${LEADV2_TASK_ID:-unknown}"
  bash "$(dirname "${BASH_SOURCE[0]}")/leadv2-pulse.sh" "$task_id" "$1" "${2:-}" || true
}

leadv2_ask_async() {
  # Usage: leadv2_ask_async <phase> <summary_30w> <question> <options_json> [auto_decide_seconds]
  # Writes docs/handoff/<task_id>/questions-async/q-<ts>-$$[-r<rand>]-pending.yaml
  # Prints qid to stdout
  local phase="$1" summary="$2" question="$3" options_json="$4"
  local auto_decide="${5:-null}"
  local task_id="${LEADV2_TASK_ID:-unknown}"
  local dir="docs/handoff/${task_id}/questions-async"
  mkdir -p "$dir"
  local qid="" attempts=0
  while [[ $attempts -lt 3 ]]; do
    qid="q-$(date +%s%N 2>/dev/null || date +%s)-$$"
    [[ ! -f "${dir}/${qid}-pending.yaml" ]] && break
    qid=""; sleep 0.001; (( attempts++ )) || true
  done
  [[ -z "$qid" ]] && qid="q-$(date +%s%N 2>/dev/null || date +%s)-$$-r$RANDOM"
  local pending="${dir}/${qid}-pending.yaml"
  local tmp; tmp=$(mktemp)
  python3 -c "
import yaml, sys
d = {'task_id': sys.argv[1], 'phase': sys.argv[2], 'qid': sys.argv[3],
     'summary_for_lead': sys.argv[4], 'question': sys.argv[5],
     'options': yaml.safe_load(sys.argv[6]),
     'auto_decide_after': None if sys.argv[7]=='null' else int(sys.argv[7]),
     'wait_indefinitely': sys.argv[7]=='null', 'priority': 'P1',
     'created_at': sys.argv[8]}
yaml.safe_dump(d, sys.stdout, allow_unicode=True, default_flow_style=False)
" "$task_id" "$phase" "$qid" "$summary" "$question" "$options_json" "$auto_decide" \
  "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" > "$tmp"
  mv "$tmp" "$pending"

  # SUPERVISE-V2-01 fix-1 (H1/Codex#1): NO V2 control-plane mirror here.
  # A prior version of this function also wrote a --no-block leadv2-ask.sh
  # question with an INDEPENDENT qid, unlinked from the legacy qid above.
  # Nothing ever resolved that mirror when the real question answered via
  # leadv2-reply.sh, so it sat as a permanent phantom "pending" duplicate in
  # the founder-facing table — exactly the risk context.yaml named ("two
  # answer commands confuse founder"). leadv2-supervise.sh's table ALREADY
  # dual-READS this legacy questions-async pending file directly (see
  # "waiting-for-answer: open questions-async pending files" in that script)
  # and tags it store=legacy-handoff — the founder sees this question with
  # NO mirror needed. Single-store contract (D-a): legacy stays a dual-READ
  # source, never also fanned out into a second write.
  echo "$qid"
}

leadv2_wait_answer() {
  # Usage: leadv2_wait_answer <qid> [timeout_seconds=14400]
  # Exit 0: answered by founder (prints chosen option)
  # Exit 1: auto-decided (prints chosen option)
  # Exit 2: hard-block (Heavy/Strategic/missing class — never auto-decide)
  local qid="$1"
  local timeout_sec="${2:-14400}"
  local task_id="${LEADV2_TASK_ID:-unknown}"
  local dir="docs/handoff/${task_id}/questions-async"
  local pending="${dir}/${qid}-pending.yaml"
  local answered="${dir}/${qid}-answered.yaml"

  # Pre-check: answered before we started polling?
  if [[ -f "$answered" ]]; then
    python3 -c "import yaml; d=yaml.safe_load(open('${answered}')); print(d.get('chosen',''))" 2>/dev/null || true
    return 0
  fi

  local wait_indefinitely="false"
  [[ -f "$pending" ]] && wait_indefinitely=$(python3 -c "import yaml; d=yaml.safe_load(open('${pending}')); print(str(d.get('wait_indefinitely',False)).lower())" 2>/dev/null || echo "false")

  # Read classification — missing = NEVER auto-decide (D10)
  # Read from actual LEAD_V2_STATE.md (not task-scoped STATE.yaml)
  local class_val=""
  class_val=$(python3 -c "
import re
try:
    txt = open('docs/LEAD_V2_STATE.md').read()
    m = re.search(r'class:\\s*(\\w[\\w-]*)', txt)
    print(m.group(1) if m else '')
except:
    print('')
" 2>/dev/null || echo "")

  local never_auto=0
  [[ -z "$class_val" ]] && never_auto=1
  case "$class_val" in Heavy|Strategic) never_auto=1 ;; esac
  [[ "$wait_indefinitely" == "true" ]] && never_auto=1

  local deadline=$(( $(date +%s) + timeout_sec ))

  while true; do
    if [[ -f "$answered" ]]; then
      python3 -c "import yaml; d=yaml.safe_load(open('${answered}')); print(d.get('chosen',''))" 2>/dev/null || true
      return 0
    fi
    local now; now=$(date +%s)
    if [[ $never_auto -eq 0 && $now -ge $deadline ]]; then
      local default_opt
      default_opt=$(python3 -c "
import yaml
d=yaml.safe_load(open('${pending}'))
for o in d.get('options',[]):
    if o.get('is_default') and o.get('conservative'):
        print(o.get('label',''))
        break
" 2>/dev/null || echo "")
      if [[ -n "$default_opt" ]]; then
        local tmp; tmp=$(mktemp)
        cat > "$tmp" <<YAML
task_id: ${task_id}
qid: ${qid}
chosen: ${default_opt}
decided_by: auto
answered_at: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
YAML
        local lock="${answered}.lock"
        if ln "$tmp" "$lock" 2>/dev/null; then
          mv "$tmp" "$answered"; rm -f "$lock"
          echo "$default_opt"; return 1
        else
          rm -f "$tmp"
          python3 -c "import yaml; d=yaml.safe_load(open('${answered}')); print(d.get('chosen',''))" 2>/dev/null || true
          return 0
        fi
      fi
      return 2
    fi
    sleep 5
  done
}


# ── Context YAML read-modify-write lock ───────────────────────────────
# Acquire an exclusive flock on <task_dir>/.context.lock for the duration
# of a context.yaml read-modify-write cycle.  Mirrors the STATE.md.lock
# pattern in leadv2-state-atomic-write.sh.
#
# Usage:
#   leadv2_with_context_lock <context_yaml_path> <cmd> [args...]
#
# The lock file is placed alongside context.yaml:
#   $(dirname <context_yaml_path>)/.context.lock
#
# On timeout (10s): prints warning to stderr and exits non-zero.
# The entire read→modify→_atomic_write_yaml chain must run inside this call
# so that concurrent sessions cannot interleave their reads and writes.
leadv2_with_context_lock() {
  local ctx_path="$1"; shift
  local lock_dir
  lock_dir="$(dirname "$ctx_path")"
  local lock_file="${lock_dir}/.context.lock"
  mkdir -p "$lock_dir"
  touch "$lock_file"
  flock -x -w 10 "$lock_file" "$@" || {
    printf -- '[helpers] leadv2_with_context_lock: timeout waiting for %s\n' "$lock_file" >&2
    return 1
  }
}

# ── _leadv2_claude_agents_json ────────────────────────────────────────────────
# Call `claude agents --json` with a 5-second timeout.
# Returns JSON on stdout; empty string on any failure (binary missing, timeout,
# non-zero exit, unsupported CLI version).
#
# Caches result in /tmp/leadv2-claude-agents-cache-$$.json for 30 seconds keyed
# by the current process-group PID ($$) so a single sweep never spams the CLI.
# Callers that need one-per-sweep caching should invoke this once and pass the
# result around — do NOT call from inside a per-session loop.
#
# Usage:
#   agents_json=$(_leadv2_claude_agents_json)
#   if [[ -n "$agents_json" ]]; then
#     # use the JSON
#   fi
_leadv2_claude_agents_json() {
  local cache_file="/tmp/leadv2-claude-agents-cache-$$.json"
  local cache_ttl=30

  # Return cached result if fresh enough
  if [[ -f "$cache_file" ]]; then
    local cache_age
    cache_age=$(( $(date -u +%s) - $(python3 -c "import os,sys; print(int(os.path.getmtime(sys.argv[1])))" "$cache_file" 2>/dev/null || echo 0) ))
    if [[ "$cache_age" -le "$cache_ttl" ]]; then
      cat "$cache_file"
      return 0
    fi
  fi

  # Check binary availability
  if ! command -v claude >/dev/null 2>&1; then
    printf -- '' > "$cache_file" 2>/dev/null || true
    printf -- ''
    return 0
  fi

  # Run with 5-second timeout; suppress stderr entirely so old CLIs don't log noise
  local raw
  raw=$(timeout 5 claude agents --json 2>/dev/null) || true

  # Validate output is JSON (non-empty); fall back to empty on bad output
  if [[ -n "$raw" ]] && python3 -c "import sys,json; json.loads(sys.argv[1])" "$raw" 2>/dev/null; then
    printf -- '%s' "$raw" > "$cache_file" 2>/dev/null || true
    printf -- '%s' "$raw"
  else
    printf -- '' > "$cache_file" 2>/dev/null || true
    printf -- ''
  fi
}

# Export fun names so subshells see them.
# `export -f` is bash-only — in zsh it is interpreted as `typeset -f` and
# prints the entire function body to stdout (200+ lines per source). Only run
# under bash; in zsh the functions are still available in the sourcing shell.
if [[ -n "${BASH_VERSION:-}" ]]; then
  export -f _leadv2_check_python_version
  export -f leadv2_validate_yaml
  export -f leadv2_rotate_history
  export -f leadv2_lock_acquire
  export -f leadv2_lock_release
  export -f leadv2_archive_old_handoff
  export -f leadv2_cost_check
  export -f leadv2_dry_run_enabled
  export -f leadv2_maybe_dry_run_echo
  export -f leadv2_live_update
  export -f leadv2_status_summary
  export -f leadv2_codex_ready
  export -f leadv2_deploy_via_override
  export -f leadv2_task_id
  export -f leadv2_task_dir
  export -f leadv2_state_path
  export -f leadv2_live_path
  export -f leadv2_lock_path
  export -f _leadv2_active_file
  export -f _leadv2_active_lockfile
  export -f _leadv2_active_ensure_header
  export -f leadv2_active_register
  export -f leadv2_active_update_phase
  export -f leadv2_active_unregister
  export -f leadv2_active_list
  export -f leadv2_po_claim
  export -f leadv2_po_release
  export -f _leadv2_claims_dir
  export -f leadv2_po_claim_register
  export -f leadv2_po_claim_release
  export -f leadv2_compress_handoff
  export -f leadv2_read_handoff
  export -f leadv2_emit_costs
  export -f leadv2_get_promote_threshold
  export -f leadv2_get_synth_threshold
  export -f leadv2_threshold_warn_if_inverted
  export -f _leadv2_refcount_file
  export -f _leadv2_settings_file
  export -f _leadv2_bak_file
  export -f _leadv2_bak_none_sentinel
  export -f _leadv2_hook_path
  export -f _leadv2_settings_py_lock
  export -f leadv2_settings_watchdog
  export -f leadv2_settings_acquire
  export -f leadv2_settings_release
  export -f leadv2_pulse_log
  export -f leadv2_ask_async
  export -f leadv2_wait_answer
  export -f _leadv2_claude_agents_json
  export -f _lv2_load_quality_engine_config
  export -f leadv2_with_context_lock
  export -f lv2_script
fi
