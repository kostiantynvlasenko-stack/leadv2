#!/usr/bin/env bash
# Stop hook: clear the supervise-mode sentinel (.supervise-active) when its
# owning session exits.
#
# Companion to hooks/leadv2-supervise-fanout-guard.sh (PreToolUse:Agent). That
# guard already self-heals a DEAD-pid sentinel lazily (on the next Agent
# call), but a leftover sentinel between sessions would otherwise sit there
# with a still-live-looking pid (PID reuse) or simply confuse a founder who
# checks state — clearing it eagerly at Stop is cheap and correct.
#
# Removes the sentinel when either:
#   (a) its recorded pid is no longer alive (self-heal, same check as the
#       guard), or
#   (b) its recorded pid matches THIS exiting session's durable claude pid
#       (see leadv2-active-registry.sh:_lv2_durable_pid) — i.e. the session
#       that owns the sentinel is the one stopping right now.
#
# Never touches a sentinel owned by a DIFFERENT still-live session (e.g. a
# founder with two repos/worktrees open) — fail-safe, never fatal.
set -euo pipefail
trap 'echo "[$(basename "$0")] error at line $LINENO — continuing" >&2; exit 0' ERR

INPUT="$(cat 2>/dev/null || true)"
CWD="$(printf -- '%s' "$INPUT" | python3 -c "
import sys, json
try:
    print(json.loads(sys.stdin.read()).get('cwd','') or '')
except Exception:
    pass
" 2>/dev/null || true)"
[[ -z "$CWD" ]] && CWD="$PWD"

if [[ -n "${CLAUDE_PLUGIN_ROOT:-}" && -f "${CLAUDE_PLUGIN_ROOT}/scripts/leadv2-state-path.sh" ]]; then
  RESOLVER="${CLAUDE_PLUGIN_ROOT}/scripts/leadv2-state-path.sh"
  REGISTRY="${CLAUDE_PLUGIN_ROOT}/scripts/leadv2-active-registry.sh"
else
  _LV2_D="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  RESOLVER="${_LV2_D}/../scripts/leadv2-state-path.sh"
  REGISTRY="${_LV2_D}/../scripts/leadv2-active-registry.sh"
fi
[[ -x "$RESOLVER" ]] || exit 0

SENTINEL="$(PROJECT_ROOT="$CWD" "$RESOLVER" --no-link .supervise-active 2>/dev/null || true)"
[[ -z "$SENTINEL" || ! -f "$SENTINEL" ]] && exit 0

MY_PID=""
if [[ -f "$REGISTRY" ]]; then
  # shellcheck source=leadv2-active-registry.sh
  source "$REGISTRY"
  MY_PID="$(_lv2_durable_pid 2>/dev/null || true)"
fi

python3 -c "
import sys, os, json
path, my_pid = sys.argv[1], sys.argv[2]
try:
    with open(path, encoding='utf-8') as fh:
        d = json.load(fh) or {}
    pid = d.get('pid')
    alive = False
    try:
        os.kill(int(pid), 0)
        alive = True
    except Exception:
        alive = False
    mine = bool(my_pid) and str(pid) == str(my_pid)
    if (not alive) or mine:
        os.remove(path)
except Exception:
    pass
" "$SENTINEL" "$MY_PID" 2>/dev/null || true

exit 0
