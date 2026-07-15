#!/usr/bin/env bash
# leadv2-install-dispatcher.sh — SessionStart hook.
# Self-installs the lv2 dispatcher into the consuming repo's .claude/scripts/
# so that `bash .claude/scripts/lv2 <script>` works without manual setup.
# Silent on success. Never fails the session (exits 0 always).
set -uo pipefail
export PYTHONWARNINGS="ignore::DeprecationWarning"  # LEAD-ANCHOR-01: never let py warnings hit stderr as a hook error

_install_dispatcher() {
  local source="${CLAUDE_PLUGIN_ROOT:-}/scripts/lv2"
  local target_dir="${CLAUDE_PROJECT_DIR:-$PWD}/.claude/scripts"
  local target="${target_dir}/lv2"

  # source must exist — nothing to install otherwise
  [[ -f "$source" ]] || return 0

  # already installed and identical — skip
  if [[ -f "$target" ]] && cmp -s "$source" "$target"; then
    return 0
  fi

  mkdir -p "$target_dir" || return 0
  cp "$source" "$target"   || return 0
  chmod +x "$target"       || return 0
}

_install_dispatcher || true
exit 0
