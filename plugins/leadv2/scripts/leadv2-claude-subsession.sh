#!/usr/bin/env bash
# .claude/scripts/leadv2-claude-subsession.sh
#
# Drop-in wrapper around ~/.claude/scripts/claude-subsession.sh that enables
# tool-output compression for /leadv2 subsessions.
#
# Usage: identical to claude-subsession.sh — all arguments are forwarded.
#   --role <role>           Role name (required, consumed by inner script)
#   --model <model>         Model alias e.g. sonnet, opus, haiku (required)
#   --task-id <id>          Task id (required)
#   --mission-file <path>   Mission markdown file (required)
#   --session-id <id>       Optional session id
#   --effort <level>        Optional effort: max|high (forwarded to inner script)
#   --wait                  Wait for completion before returning
#
# NOTE on LEADV2_SPAWN_* env vars: those vars control leadv2-session-spawner.sh
# (the daemon spawn path). This wrapper uses claude-subsession.sh which has its
# own --model/--effort CLI flags. Pass model/effort as CLI args here, not via
# LEADV2_SPAWN_* env vars. LEADV2_SPAWN_MCP_CONFIG, LEADV2_SPAWN_SETTINGS, and
# LEADV2_SPAWN_PERMISSION_MODE are not applicable to the subsession path.
#
# What this wrapper adds:
#   1. Sets LEADV2_COMPRESS_TOOL_OUTPUT=1 so the hook script is not a no-op.
#   2. JSON-merges our PostToolUse hook entry into .claude/settings.local.json
#      using a reference-counted sidecar so concurrent subsessions are safe.
#   3. Restores the original settings.local.json on EXIT (or on crash) when
#      this is the last active subsession.
#
# Concurrency contract:
#   A sidecar file .claude/settings.local.json.leadv2-refcount tracks active
#   sessions.  The first acquire installs the hook; subsequent acquires just
#   bump the counter.  The last release restores the original settings.
#   See leadv2_settings_acquire / leadv2_settings_release in leadv2-helpers.sh.
#
# Crash-safety:
#   The EXIT trap fires on normal exit, SIGINT, SIGTERM, and SIGHUP.
#   If the process is SIGKILLed the refcount stays elevated; the next
#   acquire's built-in watchdog purges dead-PID entries automatically.
#
# IMPORTANT: exec is NOT used here so that the cleanup trap runs after the
# inner claude process exits.  We launch the subsession with a normal call and
# wait, then the trap fires.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Resolution order: explicit override → CLAUDE_PROJECT_DIR (v2.1.144+) → script-relative fallback
PROJECT_ROOT="${LEADV2_PROJECT_ROOT:-${CLAUDE_PROJECT_DIR:-$(cd "${SCRIPT_DIR}/../.." && pwd)}}"
export LEADV2_PROJECT_ROOT="${PROJECT_ROOT}"

REAL_SUBSESSION="${HOME}/.claude/scripts/claude-subsession.sh"

if [[ ! -x "$REAL_SUBSESSION" ]]; then
  printf -- '[leadv2-claude-subsession] real subsession script not found: %s\n' "${REAL_SUBSESSION}" >&2
  exit 1
fi

HOOK_PATH="${PROJECT_ROOT}/.claude/hooks/leadv2-compress-tool-output"
if [[ ! -x "$HOOK_PATH" ]]; then
  printf -- '[leadv2-claude-subsession] hook not executable: %s\n' "${HOOK_PATH}" >&2
  exit 1
fi

# Source helpers for leadv2_settings_acquire / leadv2_settings_release.
# shellcheck source=leadv2-helpers.sh
source "${SCRIPT_DIR}/leadv2-helpers.sh"

# ---------------------------------------------------------------------------
# Generate a unique session id for this invocation.
# ---------------------------------------------------------------------------
_LEADV2_SESSION_ID=""
if command -v uuidgen >/dev/null 2>&1; then
  _LEADV2_SESSION_ID="$(uuidgen | tr '[:upper:]' '[:lower:]')"
else
  _LEADV2_SESSION_ID="$(date -u +%Y%m%dT%H%M%S)-$$-${RANDOM}"
fi

# ---------------------------------------------------------------------------
# Cleanup trap: release our refcount slot.
# Runs on EXIT (which covers normal exit, SIGINT, SIGTERM after signal→EXIT).
# ---------------------------------------------------------------------------
_leadv2_subsession_cleanup() {
  local exit_code=$?
  leadv2_settings_release "${_LEADV2_SESSION_ID}"
  exit "$exit_code"
}

# Forward INT/TERM/HUP to EXIT so cleanup always fires.
trap '_leadv2_subsession_cleanup' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

# ---------------------------------------------------------------------------
# Watchdog: purge sidecar entries for dead PIDs (handles SIGKILL orphans).
# Must run before acquire so stale entries are cleared first.
# ---------------------------------------------------------------------------
leadv2_settings_watchdog

# ---------------------------------------------------------------------------
# Acquire: installs the hook (first session) or just bumps counter (N>=1).
# ---------------------------------------------------------------------------
leadv2_settings_acquire "${_LEADV2_SESSION_ID}"

# ---------------------------------------------------------------------------
# Export environment flags and run the inner subsession.
# Normal call (NOT exec) so the cleanup trap fires when it returns.
# ---------------------------------------------------------------------------
export LEADV2_COMPRESS_TOOL_OUTPUT=1
export PROJECT_ROOT="${PROJECT_ROOT}"

# ---------------------------------------------------------------------------
# PATH wrappers (M4): when compression is active, prepend our per-command
# wrapper dir so the subsession's Bash tool hits the wrappers first.
# We save the original PATH so wrappers can find real binaries without
# walking into themselves (recursion guard).
# ---------------------------------------------------------------------------
_WRAPPERS_DIR="${PROJECT_ROOT}/.claude/bin/leadv2-wrappers"
if [[ -d "${_WRAPPERS_DIR}" ]]; then
  # K1 fix: PATH_REAL_FOR_LEADV2 is an outermost-session invariant.
  # If it is already set (inherited from an outer leadv2 session) keep it as-is
  # so nested subsessions never see the wrapper dir in their "real" PATH.
  # Only the outermost session computes and exports it.
  if [[ -z "${PATH_REAL_FOR_LEADV2:-}" ]]; then
    # Strip any leadv2-wrappers directory from PATH before saving, just in case
    # PATH was already polluted prior to this outermost session.
    _clean_path="$(printf '%s' "$PATH" | tr ':' '\n' | grep -v 'leadv2-wrappers' | tr '\n' ':' | sed 's/:$//')"
    export PATH_REAL_FOR_LEADV2="${_clean_path}"
  fi
  export PATH="${_WRAPPERS_DIR}:${PATH}"
  export LEADV2_WRAPPER_DEPTH=0
fi

"${REAL_SUBSESSION}" "$@"
