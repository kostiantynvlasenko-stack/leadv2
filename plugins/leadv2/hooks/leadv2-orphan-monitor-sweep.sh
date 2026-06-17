#!/usr/bin/env bash
# SessionStart hook: kill orphaned zsh-monitor loops from dead claude sessions.
# These come from `Monitor` calls running `until bash codex-task.sh status ... ; do sleep 30; done`
# that don't get SIGTERM'd cleanly when the parent claude REPL exits.
#
# Strategy: any zsh -c containing "codex-task.sh status" running >15min, or whose
# CODEX_COMPANION_SESSION_ID points to a non-alive claude session, gets SIGKILL.
set -euo pipefail
trap 'echo "[$(basename "$0")] error at line $LINENO" >&2; exit 0' ERR

# Collect candidate orphan PIDs
mapfile -t CAND < <(ps -eo pid,etimes,command | awk '
  $0 ~ /codex-task\.sh status/ && $0 ~ /\/bin\/zsh -c/ {
    pid=$1; etimes=$2;
    # etimes in seconds; >900 (15 min) is past Monitor 10-min cap
    if (etimes > 900) print pid;
  }
')

KILLED=()
for pid in "${CAND[@]:-}"; do
  [[ -z "$pid" ]] && continue
  # Verify it still exists, then SIGKILL the entire pgroup
  if kill -0 "$pid" 2>/dev/null; then
    pgid=$(ps -p "$pid" -o pgid= 2>/dev/null | tr -d ' ' || true)
    if [[ -n "$pgid" ]]; then
      kill -KILL -"$pgid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
    else
      kill -KILL "$pid" 2>/dev/null || true
    fi
    KILLED+=("$pid")
  fi
done

if [[ ${#KILLED[@]} -gt 0 ]]; then
  echo "[leadv2-orphan-monitor-sweep] killed ${#KILLED[@]} orphan codex-monitor loops: ${KILLED[*]}" >&2
  printf '%s|orphan-monitor-sweep|killed=%d\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${#KILLED[@]}" >> /tmp/leadv2-sweep.log 2>/dev/null || true
fi
exit 0
