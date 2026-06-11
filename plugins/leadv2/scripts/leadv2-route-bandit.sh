#!/usr/bin/env bash
# leadv2-route-bandit.sh — Thompson Beta-Binomial route bandit for leadv2 router.
#
# USAGE:
#   leadv2-route-bandit.sh sample \
#     --context-key "plan:Standard:false" \
#     --allowed '["sonnet","fable","opus"]' \
#     --heuristic sonnet \
#     [--state-file /path/to/route-bandit-state.yaml]
#
#   leadv2-route-bandit.sh update \
#     --task-id BANDIT-01 \
#     [--state-file /path] \
#     [--scorecard-file /path]
#
#   leadv2-route-bandit.sh rebuild \
#     [--state-file /path] \
#     [--project-root /path]
#
# STDOUT (sample): chosen_arm=<arm>
# STDOUT (update): update_result=ok|skipped|error
# STDOUT (rebuild): rebuild_result=ok|skipped|error
# EXIT 0 always — fail-safe; caller treats any non-zero as internal guard only
#
# ENV:
#   LEADV2_BANDIT_STATE_FILE  — override state file path (testing)
#   PROJECT_ROOT              — project root; auto-detected from script location if absent
#
# Mirrors platform/eval/bandits.sh: bash + inline python3 argv-based,
# no heredoc-pipe stdin conflicts (bash-scripting skill §Heredoc).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

log()      { printf -- '[%s] leadv2-route-bandit: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }
log_info() { log "INFO: $*"; }
log_warn() { log "WARN: $*"; }
log_err()  { log "ERROR: $*"; }

# ── Python helpers (argv-based, no heredoc-pipe stdin conflict) ───────────────

# All python3 scripts are stored in a companion .py file loaded by path,
# OR called as: python3 "$PY_HELPER" <subcmd> <args...>
# We store them in a separate helper file to avoid heredoc-in-bash issues.

readonly PY_HELPER="${SCRIPT_DIR}/leadv2-route-bandit-py.py"

_ensure_py_helper() {
  [[ -f "$PY_HELPER" ]] && return 0
  log_warn "Python helper not found at $PY_HELPER — cannot proceed"
  return 1
}

# ── default state file ────────────────────────────────────────────────────────

_default_state_file() {
  local proj_root
  proj_root="${PROJECT_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
  printf '%s/docs/leadv2/route-bandit-state.yaml' "$proj_root"
}

# ── YAML <-> JSON conversion (delegate to py helper) ─────────────────────────

_state_to_json() {
  local yaml_path="$1"
  _ensure_py_helper || { echo "{}"; return 0; }
  python3 "$PY_HELPER" parse_yaml "$yaml_path" 2>/dev/null || echo "{}"
}

_json_to_yaml() {
  local json_str="$1"
  _ensure_py_helper || return 1
  python3 "$PY_HELPER" to_yaml "$json_str" 2>/dev/null
}

# ── SAMPLE subcommand ─────────────────────────────────────────────────────────

cmd_sample() {
  local ctx_key="" allowed_json="" heuristic="" state_file=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --context-key)  ctx_key="$2";      shift 2 ;;
      --allowed)      allowed_json="$2"; shift 2 ;;
      --heuristic)    heuristic="$2";    shift 2 ;;
      --state-file)   state_file="$2";   shift 2 ;;
      *) shift ;;
    esac
  done

  if [[ -z "$state_file" ]]; then
    state_file="${LEADV2_BANDIT_STATE_FILE:-$(_default_state_file)}"
  fi

  # Outer fail-safe: any unhandled error returns heuristic, exit 0
  {
    if [[ -z "$ctx_key" || -z "$heuristic" ]]; then
      log_warn "sample: missing --context-key or --heuristic; returning heuristic"
      printf 'chosen_arm=%s\n' "$heuristic"
      return 0
    fi

    if [[ -z "$allowed_json" ]]; then
      allowed_json="[\"${heuristic}\"]"
    fi

    _ensure_py_helper || {
      log_warn "sample: py helper missing; returning heuristic"
      printf 'chosen_arm=%s\n' "$heuristic"
      return 0
    }

    # Read state file -> JSON
    local state_json="{}"
    if [[ -f "$state_file" ]]; then
      state_json="$(_state_to_json "$state_file")" || state_json="{}"
    fi

    # Check circuit-breaker
    local cooldown_n
    cooldown_n=$(python3 "$PY_HELPER" get_cooldown "$state_json" "$ctx_key" 2>/dev/null) || cooldown_n=0

    if [[ "$cooldown_n" -gt 0 ]]; then
      log_info "sample: circuit-breaker active for $ctx_key (n=$cooldown_n); returning heuristic"
      _decrement_cooldown "$ctx_key" "$state_file" "$state_json" || true
      printf 'chosen_arm=%s\n' "$heuristic"
      return 0
    fi

    # Thompson sampling
    local result
    result=$(python3 "$PY_HELPER" sample "$ctx_key" "$allowed_json" "$heuristic" "$state_json" 2>/dev/null) || {
      log_warn "sample: python3 sampling failed; returning heuristic"
      printf 'chosen_arm=%s\n' "$heuristic"
      return 0
    }

    if [[ -z "$result" ]]; then
      log_warn "sample: empty result; returning heuristic"
      printf 'chosen_arm=%s\n' "$heuristic"
      return 0
    fi

    printf '%s\n' "$result"
  } || {
    log_err "sample: unexpected error; returning heuristic (fail-safe)"
    printf 'chosen_arm=%s\n' "$heuristic"
  }
  return 0
}

_decrement_cooldown() {
  local ctx_key="$1" state_file="$2" state_json="$3"
  local lock_file="${state_file}.lock"

  local new_state_json
  new_state_json=$(python3 "$PY_HELPER" decrement_cooldown "$ctx_key" "$state_json" 2>/dev/null) || return 0

  local tmp_file
  tmp_file="$(mktemp "${state_file}.tmp.XXXXXX")"
  _json_to_yaml "$new_state_json" > "$tmp_file" 2>/dev/null || { rm -f "$tmp_file"; return 0; }

  (
    flock -x 200
    mv "$tmp_file" "$state_file"
  ) 200>"$lock_file" 2>/dev/null || { rm -f "$tmp_file"; return 0; }
}

# ── UPDATE subcommand ─────────────────────────────────────────────────────────

cmd_update() {
  local task_id="" state_file="" scorecard_file=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --task-id)        task_id="$2";        shift 2 ;;
      --state-file)     state_file="$2";     shift 2 ;;
      --scorecard-file) scorecard_file="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  # UPDATE always exits 0 — non-blocking updater must not crash close
  {
    if [[ -z "$task_id" ]]; then
      log_warn "update: missing --task-id; skipping"
      printf 'update_result=skipped\n'
      return 0
    fi

    if [[ -z "$state_file" ]]; then
      state_file="${LEADV2_BANDIT_STATE_FILE:-$(_default_state_file)}"
    fi

    _ensure_py_helper || {
      log_err "update: py helper missing"
      printf 'update_result=error\n'
      return 0
    }

    local proj_root
    proj_root="${PROJECT_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
    local handoff_dir="${proj_root}/docs/handoff/${task_id}"
    local rd_file="${handoff_dir}/route-decisions.yaml"

    # Read route-decisions.yaml -> JSON
    local rd_json="[]"
    if [[ -f "$rd_file" ]]; then
      rd_json=$(python3 "$PY_HELPER" parse_rd "$rd_file" 2>/dev/null) || rd_json="[]"
    fi

    if [[ "$rd_json" == "[]" || -z "$rd_json" ]]; then
      log_info "update: no route-decisions for task $task_id; skipping"
      printf 'update_result=skipped\n'
      return 0
    fi

    # Read scorecard row
    if [[ -z "$scorecard_file" ]]; then
      scorecard_file="${proj_root}/docs/leadv2/scorecard.jsonl"
    fi

    local sc_json="{}"
    if [[ -f "$scorecard_file" ]]; then
      sc_json=$(grep "\"task_id\":\"${task_id}\"" "$scorecard_file" 2>/dev/null | tail -1) || sc_json="{}"
      [[ -z "$sc_json" ]] && sc_json="{}"
    fi

    if [[ "$sc_json" == "{}" ]]; then
      log_warn "update: no scorecard row for task $task_id; skipping"
      printf 'update_result=skipped\n'
      return 0
    fi

    # Read current state -> JSON
    local state_json="{}"
    if [[ -f "$state_file" ]]; then
      state_json="$(_state_to_json "$state_file")" || {
        log_warn "update: state parse failed; attempting rebuild"
        state_json="$(_rebuild_state_json "$proj_root")" || state_json="{}"
      }
    fi

    # Run update
    local new_state_json
    new_state_json=$(python3 "$PY_HELPER" update "$task_id" "$rd_json" "$sc_json" "$state_json" 2>/dev/null) || {
      log_err "update: python3 update failed; leaving state unchanged"
      printf 'update_result=error\n'
      return 0
    }

    [[ -z "$new_state_json" ]] && {
      log_err "update: empty result from python3"
      printf 'update_result=error\n'
      return 0
    }

    # Stamp meta
    local now_iso
    now_iso="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    new_state_json=$(python3 "$PY_HELPER" stamp_meta "$new_state_json" "$now_iso" 2>/dev/null) || true

    _write_state "$new_state_json" "$state_file" || {
      printf 'update_result=error\n'
      return 0
    }

    log_info "update: state updated for task $task_id"
    printf 'update_result=ok\n'
  } || {
    log_err "update: unexpected error; exit 0 (non-blocking)"
    printf 'update_result=error\n'
  }
  return 0
}

_rebuild_state_json() {
  local proj_root="$1"
  local scorecard_file="${proj_root}/docs/leadv2/scorecard.jsonl"
  local handoff_base="${proj_root}/docs/handoff"

  [[ -f "$scorecard_file" ]] || { echo "{}"; return 0; }

  local sc_content
  sc_content="$(cat "$scorecard_file" 2>/dev/null)" || { echo "{}"; return 0; }

  python3 "$PY_HELPER" rebuild "$sc_content" "$handoff_base" 2>/dev/null || echo "{}"
}

_write_state() {
  local json_str="$1" state_file="$2"
  local lock_file="${state_file}.lock"
  local tmp_file
  tmp_file="$(mktemp "${state_file}.tmp.XXXXXX")"

  _json_to_yaml "$json_str" > "$tmp_file" 2>/dev/null || { rm -f "$tmp_file"; return 1; }

  mkdir -p "$(dirname "$state_file")" 2>/dev/null || true

  (
    flock -x 200
    mv "$tmp_file" "$state_file"
  ) 200>"$lock_file" 2>/dev/null || { rm -f "$tmp_file"; return 1; }
}

# ── REBUILD subcommand ────────────────────────────────────────────────────────

cmd_rebuild() {
  local state_file="" proj_root=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --state-file)    state_file="$2";   shift 2 ;;
      --project-root)  proj_root="$2";    shift 2 ;;
      *) shift ;;
    esac
  done

  proj_root="${proj_root:-${PROJECT_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}}"

  if [[ -z "$state_file" ]]; then
    state_file="${LEADV2_BANDIT_STATE_FILE:-${proj_root}/docs/leadv2/route-bandit-state.yaml}"
  fi

  {
    _ensure_py_helper || {
      log_err "rebuild: py helper missing"
      printf 'rebuild_result=error\n'
      return 0
    }

    local rebuilt
    rebuilt="$(_rebuild_state_json "$proj_root")" || {
      log_err "rebuild: failed"
      printf 'rebuild_result=error\n'
      return 0
    }

    if [[ -z "$rebuilt" || "$rebuilt" == "{}" ]]; then
      log_warn "rebuild: no data found; state unchanged"
      printf 'rebuild_result=skipped\n'
      return 0
    fi

    local now_iso
    now_iso="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    rebuilt=$(python3 "$PY_HELPER" stamp_meta "$rebuilt" "$now_iso" 2>/dev/null) || true

    _write_state "$rebuilt" "$state_file" || {
      printf 'rebuild_result=error\n'
      return 0
    }

    log_info "rebuild: state written to $state_file"
    printf 'rebuild_result=ok\n'
  } || {
    log_err "rebuild: unexpected error"
    printf 'rebuild_result=error\n'
  }
  return 0
}

# ── main dispatch ─────────────────────────────────────────────────────────────

main() {
  local subcmd="${1:-}"
  shift || true

  case "$subcmd" in
    sample)  cmd_sample  "$@" ;;
    update)  cmd_update  "$@" ;;
    rebuild) cmd_rebuild "$@" ;;
    *)
      log_err "Unknown subcommand: '$subcmd'. Use: sample | update | rebuild"
      exit 1
      ;;
  esac
}

main "$@"
