#!/usr/bin/env bash
set -euo pipefail
# leadv2-mcp-cache.sh — MCP call result cache for /leadv2 subagents.
# Prevents redundant codebase-memory-mcp calls across subagents within a task.
#
# Usage:
#   leadv2-mcp-cache.sh get <tool> <args-hash>
#       Exit 0 + yaml on stdout if cache hit (age < TTL). Exit 1 on miss.
#
#   leadv2-mcp-cache.sh set <tool> <args-hash> <yaml-payload-file>
#       Atomically write result to cache (tmp + mv).
#
#   leadv2-mcp-cache.sh warm <task-id>
#       Pre-populate common queries for the task. Prints a shell snippet
#       the orchestrator should eval/source to populate the cache directory.
#
# Cache location: docs/handoff/<task-id>/mcp-cache/
# Cache TTL: 1800 seconds (30 minutes)
# Cache file format: <tool>-<args-hash>.yaml

readonly CACHE_TTL_SEC=1800

log() { printf '[leadv2-mcp-cache] %s\n' "$*" >&2; }

usage() {
  printf 'Usage:\n' >&2
  printf '  %s get <tool> <args-hash>\n' "$0" >&2
  printf '  %s set <tool> <args-hash> <yaml-payload-file>\n' "$0" >&2
  printf '  %s warm <task-id>\n' "$0" >&2
  exit 1
}

[[ $# -lt 2 ]] && usage

CMD="$1"
shift

# ---------------------------------------------------------------------------
# Resolve cache directory from task-id or derive from current handoff context
# ---------------------------------------------------------------------------
resolve_cache_dir() {
  local task_id="$1"
  local project_root="${PROJECT_ROOT:-$(pwd)}"
  local cache_dir="$project_root/docs/handoff/$task_id/mcp-cache"
  printf '%s' "$cache_dir"
}

# ---------------------------------------------------------------------------
# cmd: get <tool> <args-hash>
# ---------------------------------------------------------------------------
cmd_get() {
  local tool="$1" args_hash="$2"
  local task_id="${LEADV2_TASK_ID:-}"

  if [[ -z "$task_id" ]]; then
    log "WARN: LEADV2_TASK_ID not set, cache disabled"
    exit 1
  fi

  local cache_dir
  cache_dir=$(resolve_cache_dir "$task_id")
  local cache_file="${cache_dir}/${tool}-${args_hash}.yaml"

  if [[ ! -f "$cache_file" ]]; then
    log "MISS: ${tool}-${args_hash}"
    exit 1
  fi

  # Check age
  local file_mtime
  if command -v stat >/dev/null 2>&1; then
    # macOS: stat -f %m; Linux: stat -c %Y
    if stat -f %m "$cache_file" >/dev/null 2>&1; then
      file_mtime=$(stat -f %m "$cache_file")
    else
      file_mtime=$(stat -c %Y "$cache_file")
    fi
  else
    # Fallback: treat as fresh (no stat available)
    file_mtime=$(date +%s)
  fi

  local now
  now=$(date +%s)
  local age=$(( now - file_mtime ))

  if [[ "$age" -ge "$CACHE_TTL_SEC" ]]; then
    log "STALE: ${tool}-${args_hash} (age=${age}s >= ttl=${CACHE_TTL_SEC}s)"
    exit 1
  fi

  log "HIT: ${tool}-${args_hash} (age=${age}s)"
  cat "$cache_file"
  exit 0
}

# ---------------------------------------------------------------------------
# cmd: set <tool> <args-hash> <yaml-payload-file>
# ---------------------------------------------------------------------------
cmd_set() {
  local tool="$1" args_hash="$2" payload_file="$3"
  local task_id="${LEADV2_TASK_ID:-}"

  if [[ -z "$task_id" ]]; then
    log "WARN: LEADV2_TASK_ID not set, skipping cache write"
    exit 0
  fi

  [[ -f "$payload_file" ]] || { log "ERROR: payload file not found: $payload_file"; exit 1; }

  local cache_dir
  cache_dir=$(resolve_cache_dir "$task_id")
  mkdir -p "$cache_dir"

  local cache_file="${cache_dir}/${tool}-${args_hash}.yaml"
  local tmp_file
  tmp_file=$(mktemp "${cache_dir}/.tmp-XXXXXX.yaml")

  # Atomic write: write to tmp, then mv
  cp "$payload_file" "$tmp_file"
  mv "$tmp_file" "$cache_file"

  log "SET: ${tool}-${args_hash} → $cache_file"
  exit 0
}

# ---------------------------------------------------------------------------
# cmd: warm <task-id>
# Pre-populate common query placeholders so subagents know which queries
# the orchestrator has already dispatched. Actual MCP results must be written
# via `leadv2-mcp-cache.sh set` after the orchestrator receives them.
#
# Prints the cache directory path and a list of expected cache keys so the
# orchestrator can track what to populate.
# ---------------------------------------------------------------------------
cmd_warm() {
  local task_id="$1"
  local project_root="${PROJECT_ROOT:-$(pwd)}"
  local cache_dir
  cache_dir=$(resolve_cache_dir "$task_id")
  mkdir -p "$cache_dir"

  log "Warmed cache dir for task $task_id: $cache_dir"

  # Print the standard queries the orchestrator should pre-populate
  # Format: one line per expected cache entry: "<tool> <suggested-query>"
  cat <<WARM_LIST
# Warm targets for task: $task_id
# Orchestrator: run these MCP calls, then write results via:
#   leadv2-mcp-cache.sh set <tool> <args-hash> <result-file>
#
# Standard queries:
#   tool=detect_changes      query: start_sha=<TASK_START_SHA>, head=HEAD
#   tool=get_architecture    query: (no args)
#   tool=search_graph        query: relevant symbols for this task
#
# Cache dir: $cache_dir
# Export LEADV2_TASK_ID=$task_id before calling get/set subcommands.
WARM_LIST

  exit 0
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
case "$CMD" in
  get)
    [[ $# -lt 2 ]] && usage
    cmd_get "$1" "$2"
    ;;
  set)
    [[ $# -lt 3 ]] && usage
    cmd_set "$1" "$2" "$3"
    ;;
  warm)
    [[ $# -lt 1 ]] && usage
    cmd_warm "$1"
    ;;
  *)
    log "ERROR: unknown command: $CMD"
    usage
    ;;
esac
