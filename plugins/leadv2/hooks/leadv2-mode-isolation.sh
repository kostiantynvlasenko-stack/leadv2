#!/usr/bin/env bash
# Shared hook helper: identify a supervisor Claude session without consulting
# active.yaml.  The registry is a shared control plane and its first row may
# belong to any child lead, so it must never be used to infer session mode.
#
# leadv2-task-anchor.sh writes this per-Claude-session marker after proving
# that the live supervisor PID is in the current process ancestry.

leadv2_hook_is_supervisor_session() {
  local input="${1:-}"
  local session_id=""
  local safe_session=""

  [[ -n "$input" ]] || return 1
  session_id="$(printf -- '%s' "$input" | python3 -c '
import json, sys
try:
    print((json.load(sys.stdin).get("session_id") or "").strip())
except Exception:
    pass
' 2>/dev/null || true)"
  safe_session="$(printf -- '%s' "$session_id" | tr -cd 'A-Za-z0-9._-')"
  [[ -n "$safe_session" && -f "/tmp/.leadv2-supervisor-mode-${safe_session}" ]]
}

# Print the task owned by this hook's process tree.  Never falls back to the
# first shared registry row: a concurrent lead may own it.
leadv2_hook_resolve_task_id() {
  local input="${1:-}"
  local active_yaml="${2:-}"
  local explicit=""

  leadv2_hook_is_supervisor_session "$input" && return 1

  explicit="$(printf -- '%s' "${LEADV2_TASK_ID:-}" | tr -cd 'A-Za-z0-9._-')"
  if [[ -n "$explicit" ]]; then
    printf -- '%s\n' "$explicit"
    return 0
  fi
  [[ -n "$active_yaml" && -f "$active_yaml" ]] || return 1

  python3 - "$active_yaml" <<'PYEOF' 2>/dev/null
import os, subprocess, sys
try:
    import yaml
    with open(sys.argv[1], encoding="utf-8") as fh:
        sessions = (yaml.safe_load(fh) or {}).get("sessions") or []

    ancestors = []
    seen = set()
    pid = os.getppid()
    while pid > 1 and pid not in seen:
        seen.add(pid)
        ancestors.append(pid)
        raw = subprocess.run(
            ["ps", "-o", "ppid=", "-p", str(pid)],
            capture_output=True, text=True, timeout=1,
        ).stdout.strip()
        nxt = int(raw) if raw else 0
        if nxt <= 1 or nxt == pid:
            break
        pid = nxt

    by_pid = {int(row.get("pid")): row for row in sessions if row.get("pid")}
    for ancestor in ancestors:
        row = by_pid.get(ancestor)
        if row:
            task_id = str(row.get("task_id") or "").strip()
            if task_id:
                print(task_id)
                raise SystemExit(0)
except Exception:
    pass
raise SystemExit(1)
PYEOF
}

leadv2_hook_resolve_phase() {
  local input="${1:-}"
  local active_yaml="${2:-}"
  local task_id=""

  leadv2_hook_is_supervisor_session "$input" && return 1
  if [[ -n "${LEADV2_ACTIVE_PHASE:-}" ]]; then
    printf -- '%s\n' "${LEADV2_ACTIVE_PHASE,,}"
    return 0
  fi
  task_id="$(leadv2_hook_resolve_task_id "$input" "$active_yaml" 2>/dev/null || true)"
  [[ -n "$task_id" && -n "$active_yaml" && -f "$active_yaml" ]] || return 1
  python3 - "$active_yaml" "$task_id" <<'PYEOF' 2>/dev/null
import sys, yaml
try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        sessions = (yaml.safe_load(fh) or {}).get("sessions") or []
    row = next((r for r in sessions if str(r.get("task_id") or "") == sys.argv[2]), None)
    phase = str((row or {}).get("phase") or "").strip().lower()
    if phase:
        print(phase)
        raise SystemExit(0)
except Exception:
    pass
raise SystemExit(1)
PYEOF
}
