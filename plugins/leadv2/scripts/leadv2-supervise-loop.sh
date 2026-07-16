#!/usr/bin/env bash
# leadv2-supervise-loop.sh — SUPERVISE-V2-01 D-c (batch-2 item 1): one
# Monitor-attachable FOREGROUND loop around `leadv2-supervise.sh --json
# --since <cursor>`. The loop renders output to a log file; the supervising
# lead only Monitor()s that file and never re-invokes leadv2-supervise.sh
# in-band. This script owns the sleep/poll cadence — not the LLM (off_limits:
# "no sleep/poll loop owned by the LLM").
#
# Usage:
#   leadv2-supervise-loop.sh --ensure   # attach-or-start: if a live loop
#     already owns the PID+birth sentinel, print its log path and exit 0
#     WITHOUT starting a duplicate (re-entry/PostCompact safe). Otherwise this
#     process becomes the loop itself (blocks — spawn it backgrounded).
#   leadv2-supervise-loop.sh            # unconditionally becomes the loop
#     (no sentinel liveness check first) — prefer --ensure from callers.
#
# Cadence (D-c):
#   every LEADV2_SUPERVISE_EVENT_POLL_S (default 5s): `leadv2-supervise.sh
#     --json --since <cursor>` — new question/dead/stuck/closed/truth-breach
#     events are appended to the log as ONE typed URGENT line each,
#     immediately. Unchanged poll -> zero bytes appended (delta_mode default).
#   every LEADV2_SUPERVISE_PULSE_S (default 300s): one full non-delta call ->
#     exactly N status lines for N non-dead lanes, each <=180 bytes:
#       `task_id phase age waiting|stuck|ok cx=<receipt|-> glm=<receipt|->`
#     (dead lanes are excluded from the N-count per D-d; their liveness is
#     surfaced only via the DEAD urgent event + founder escalation, never as
#     a pulse row — the mission grammar's "dead" token documents the state
#     enum, it is not reachable inside a non-dead-lane pulse line).
#
# Env overrides (test sandboxing):
#   LEADV2_PROJECT_ROOT / CLAUDE_PROJECT_DIR / PROJECT_ROOT — repo root
#     (same fail-closed order as leadv2-supervise.sh; no script-dir fallback)
#   LEADV2_SUPERVISE_EVENT_POLL_S   — event poll interval seconds (default 5)
#   LEADV2_SUPERVISE_PULSE_S        — full pulse interval seconds (default 300)
#   LEADV2_SUPERVISE_LOOP_MAX_CYCLES — exit after N event-poll cycles (test
#     determinism; 0/unset = run forever)
#   LEADV2_SUPERVISE_LOOP_PULSE_ON_START=1 — force a pulse on the FIRST cycle
#     instead of waiting for the full PULSE_S window (test determinism)
#
# Exit codes: 0 = ensure found a live loop already running (no-op) OR the
# loop ran its bounded test cycles and exited cleanly. 1 = root_error.
#
# lean: cx=/glm= receipts are read directly from active.yaml's
# provider_receipts[] field (populated by a future provider-wrapper writer —
# batch-1 already reserves the field, empty by default) rather than a new
# column in leadv2-supervise.sh's JSON table — upgrade when a receipt writer
# lands and the table shape needs the same data server-side.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ENSURE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ensure) ENSURE=1; shift ;;
    -h|--help)
      printf -- 'Usage: leadv2-supervise-loop.sh [--ensure]\n'
      exit 0
      ;;
    *)
      printf -- '[supervise-loop] unknown arg: %s\n' "$1" >&2
      exit 1
      ;;
  esac
done

# ── Fail-closed root resolution — identical order to leadv2-supervise.sh ───
PROJECT_ROOT=""
if [[ -n "${LEADV2_PROJECT_ROOT:-}" ]]; then
  PROJECT_ROOT="$LEADV2_PROJECT_ROOT"
elif [[ -n "${CLAUDE_PROJECT_DIR:-}" ]]; then
  PROJECT_ROOT="$CLAUDE_PROJECT_DIR"
elif _lv2l_top="$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null)"; then
  PROJECT_ROOT="$_lv2l_top"
fi
if [[ -z "$PROJECT_ROOT" ]]; then
  printf -- '[supervise-loop] root_error: could not resolve project root — set LEADV2_PROJECT_ROOT or CLAUDE_PROJECT_DIR, or run from inside a git worktree (cwd=%s)\n' "$PWD" >&2
  exit 1
fi
export LEADV2_PROJECT_ROOT="$PROJECT_ROOT"

STATE_PATH_SH="${SCRIPT_DIR}/leadv2-state-path.sh"
SUPERVISE_SH="${SCRIPT_DIR}/leadv2-supervise.sh"

SENTINEL="$(PROJECT_ROOT="$PROJECT_ROOT" "$STATE_PATH_SH" .supervise-loop.json)"
LOG_FILE="$(PROJECT_ROOT="$PROJECT_ROOT" "$STATE_PATH_SH" supervise-loop.log)"
ACTIVE_YAML="$(PROJECT_ROOT="$PROJECT_ROOT" "$STATE_PATH_SH" active.yaml)"

EVENT_POLL_S="${LEADV2_SUPERVISE_EVENT_POLL_S:-5}"
PULSE_S="${LEADV2_SUPERVISE_PULSE_S:-300}"
MAX_CYCLES="${LEADV2_SUPERVISE_LOOP_MAX_CYCLES:-0}"

_now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
_pid_birth() { ps -o lstart= -p "$1" 2>/dev/null | tr -s ' ' || true; }
_pid_alive() { kill -0 "$1" 2>/dev/null; }

# ── --ensure: attach-or-start via PID+birth sentinel (no duplicate loop) ──
# R2-2 fix (codex-review-2.md finding 2): the old version did an UNLOCKED
# check-then-create — two concurrent `--ensure` calls could both observe a
# stale/dead sentinel, both fall through, and both write a sentinel claiming
# ownership (duplicate loop; whichever writes last "wins" and the other's
# process silently has no matching sentinel). The liveness check AND the
# ownership write below now happen inside ONE critical section held by a
# single `flock` on `${SENTINEL}.lock` (python3 fcntl, matching this
# project's portable-locking convention elsewhere in leadv2-supervise.sh —
# no bash `flock` binary, which is absent on macOS/BSD).
mkdir -p "$(dirname "$SENTINEL")" "$(dirname "$LOG_FILE")"
MY_PID=$$
MY_BIRTH="$(_pid_birth "$MY_PID")"

_ENSURE_OUT="$(python3 - "$SENTINEL" "${SENTINEL}.lock" "$ENSURE" "$MY_PID" "$MY_BIRTH" <<'PYENSURE'
import sys, os, json, fcntl, tempfile, datetime, subprocess

sentinel_path, lock_path, ensure_flag, my_pid_s, my_birth = sys.argv[1:6]
ensure_flag = ensure_flag == "1"
my_pid = int(my_pid_s)

def pid_alive(pid_val):
    try:
        os.kill(int(pid_val), 0)
        return True
    except (TypeError, ValueError, ProcessLookupError, PermissionError):
        return False

def pid_birth(pid_val):
    try:
        r = subprocess.run(["ps", "-o", "lstart=", "-p", str(pid_val)],
                            capture_output=True, text=True, timeout=5)
        b = r.stdout.strip()
        return " ".join(b.split()) if b else ""
    except Exception:
        return ""

os.makedirs(os.path.dirname(lock_path) or ".", exist_ok=True)
lf = open(lock_path, "a+")
fcntl.flock(lf, fcntl.LOCK_EX)
try:
    if ensure_flag and os.path.isfile(sentinel_path):
        try:
            with open(sentinel_path, encoding="utf-8") as fh:
                d = json.load(fh) or {}
            spid = d.get("pid")
            sbirth = d.get("pid_birth")
            if spid is not None and pid_alive(spid) and sbirth and pid_birth(spid) == sbirth:
                print(f"EXISTING {int(spid)}")
                sys.exit(0)
        except Exception:
            pass
    # Not (ensure AND live-and-corroborated) -- claim ownership atomically,
    # still holding the lock, so no other --ensure caller can race us here.
    out = {
        "pid": my_pid,
        "pid_birth": my_birth,
        "started_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }
    dirn = os.path.dirname(sentinel_path)
    os.makedirs(dirn, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=dirn, suffix=".tmp")
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        json.dump(out, fh)
    os.replace(tmp, sentinel_path)
    print(f"NEW {my_pid}")
finally:
    fcntl.flock(lf, fcntl.LOCK_UN)
    lf.close()
PYENSURE
)"

_ENSURE_STATUS="$(printf -- '%s\n' "$_ENSURE_OUT" | awk '{print $1}')"
_ENSURE_PID="$(printf -- '%s\n' "$_ENSURE_OUT" | awk '{print $2}')"

if [[ "$_ENSURE_STATUS" == "EXISTING" ]]; then
  printf -- '[supervise-loop] already running pid=%s log=%s\n' "$_ENSURE_PID" "$LOG_FILE"
  exit 0
fi

printf -- '%s [supervise-loop] started pid=%s log=%s event_poll=%ss pulse=%ss\n' \
  "$(_now_iso)" "$MY_PID" "$LOG_FILE" "$EVENT_POLL_S" "$PULSE_S" >>"$LOG_FILE"

# R2-2 fix: the EXIT trap used to unconditionally `rm -f` the sentinel — if
# another `--ensure` call raced in between (e.g. a PostCompact re-entry that
# started a second loop after this one's ownership check but before this
# one's write), that trap could delete the SECOND loop's live ownership
# record out from under it. Now the trap only removes the sentinel if it
# STILL contains this process's own pid+birth — i.e. this process is still
# the recorded owner — matching the same "never clobber a different owner"
# discipline leadv2-supervise.sh's active.yaml mutation uses.
_cleanup_sentinel() {
  python3 -c "
import json, sys, os
path, pid, birth = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    with open(path, encoding='utf-8') as fh:
        d = json.load(fh) or {}
    if str(d.get('pid')) == pid and d.get('pid_birth') == birth:
        os.remove(path)
except Exception:
    pass
" "$SENTINEL" "$MY_PID" "$MY_BIRTH" 2>/dev/null || true
}
trap _cleanup_sentinel EXIT

_render_events() {
  local out_json="$1"
  python3 - "$out_json" "$LOG_FILE" <<'PYEV'
import json, sys, datetime

out_str, log_path = sys.argv[1], sys.argv[2]
try:
    d = json.loads(out_str)
except Exception:
    sys.exit(0)
if not isinstance(d, dict):
    sys.exit(0)

events = []
for q in (d.get("requires_founder") or d.get("questions") or []):
    summary = (q.get("summary_for_lead") or q.get("question") or "")[:100]
    events.append(f"QUESTION {q.get('task_id', '?')} qid={q.get('qid', '?')} \"{summary}\"")
# forward-compat: 'dead' key does not exist until item 4 lands corroborated
# death detection in leadv2-supervise.sh; read defensively either way.
for st in (d.get("dead") or []):
    reasons = "; ".join(st.get("reasons", []))[:100]
    events.append(f"DEAD {st.get('task_id', '?')} {reasons}")
for st in (d.get("stuck") or []):
    reasons = "; ".join(st.get("reasons", []))[:100]
    events.append(f"STUCK {st.get('task_id', '?')} {reasons}")
for tid in (d.get("closed_since_last") or []):
    events.append(f"CLOSED {tid}")
# forward-compat: 'truth_breaches' populated once item 3's hook is wired.
for b in (d.get("truth_breaches") or []):
    summary = str(b.get("summary", ""))[:80]
    events.append(f"TRUTH_RED {b.get('id', '?')} {b.get('severity', '?')} {summary}")

if not events:
    sys.exit(0)

now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
with open(log_path, "a", encoding="utf-8") as fh:
    for e in events:
        line = f"{now} [SUPERVISE-URGENT] {e}"
        if len(line.encode("utf-8")) > 220:
            line = line[:217] + "..."
        fh.write(line + "\n")
PYEV
}

_render_pulse() {
  local pulse_json="$1"
  python3 - "$pulse_json" "$ACTIVE_YAML" "$LOG_FILE" <<'PYPULSE'
import json, sys, os, datetime

pulse_str, active_yaml_path, log_path = sys.argv[1:4]
try:
    d = json.loads(pulse_str)
except Exception:
    sys.exit(0)
if not isinstance(d, dict):
    sys.exit(0)

table = d.get("table") or []
stuck_ids = {st.get("task_id") for st in (d.get("stuck") or [])}
dead_ids = {st.get("task_id") for st in (d.get("dead") or [])}
waiting_ids = {q.get("task_id") for q in (d.get("requires_founder") or d.get("questions") or [])}

receipts_by_task = {}
try:
    import yaml
    with open(active_yaml_path, encoding="utf-8") as fh:
        ay = yaml.safe_load(fh) or {}
    for s in (ay.get("sessions") or []):
        receipts_by_task[s.get("task_id")] = s.get("provider_receipts") or []
except Exception:
    pass

def receipt_proof(receipts, provider):
    for r in receipts:
        if not isinstance(r, dict) or r.get("provider") != provider:
            continue
        jid = r.get("job_id") or r.get("run_id")
        art = r.get("artifact_path")
        if jid and art:
            return f"{str(jid)[:8]}@{os.path.basename(str(art))}"
    return "-"

lines = []
for row in table:
    tid = row.get("task_id", "?")
    if tid in dead_ids:
        continue  # dead lanes are never part of the N-lane pulse (D-d)
    phase = row.get("phase", "?")
    age = row.get("minutes_in_phase", "?")
    if tid in waiting_ids:
        state = "waiting"
    elif tid in stuck_ids:
        state = "stuck"
    else:
        state = "ok"
    receipts = receipts_by_task.get(tid, [])
    cx = receipt_proof(receipts, "codex")
    glm = receipt_proof(receipts, "glm")
    line = f"{tid} {phase} {age}m {state} cx={cx} glm={glm}"
    if len(line.encode("utf-8")) > 180:
        line = line[:177] + "..."
    lines.append(line)

now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
with open(log_path, "a", encoding="utf-8") as fh:
    fh.write(f"--- pulse {now} ({len(lines)} lane(s)) ---\n")
    for ln in lines:
        fh.write(ln + "\n")
    # F2 truth-probe (item 3): the hook runs only on this full-call cadence
    # (once per 300s pulse) — surface any breach as a typed URGENT line here,
    # never as a silent "clear" when status != "checked".
    if d.get("truth_probe") == "checked":
        for b in (d.get("truth_breaches") or []):
            summary = str(b.get("summary", ""))[:80]
            line = f"{now} [SUPERVISE-URGENT] TRUTH_RED {b.get('id', '?')} {b.get('severity', '?')} {summary}"
            fh.write(line[:220] + "\n")
PYPULSE
}

LAST_PULSE_EPOCH=0
if [[ "${LEADV2_SUPERVISE_LOOP_PULSE_ON_START:-0}" == "1" ]]; then
  LAST_PULSE_EPOCH=0
else
  LAST_PULSE_EPOCH=$(date +%s)
fi
CYCLE=0

while true; do
  CYCLE=$((CYCLE + 1))
  RC=0
  OUT="$("$SUPERVISE_SH" --json --since loop 2>/dev/null)" || RC=$?
  if [[ "$RC" -ne 0 ]]; then
    printf -- '%s [supervise-loop] URGENT root_error rc=%s: %s\n' \
      "$(_now_iso)" "$RC" "$(printf -- '%s' "$OUT" | tr '\n' ' ' | cut -c1-180)" >>"$LOG_FILE"
  else
    _render_events "$OUT"
  fi

  NOW_EPOCH=$(date +%s)
  if (( NOW_EPOCH - LAST_PULSE_EPOCH >= PULSE_S )); then
    RC=0
    PULSE_JSON="$("$SUPERVISE_SH" --json 2>/dev/null)" || RC=$?
    if [[ "$RC" -eq 0 ]]; then
      _render_pulse "$PULSE_JSON"
    fi
    LAST_PULSE_EPOCH=$NOW_EPOCH
  fi

  if [[ "$MAX_CYCLES" -gt 0 && "$CYCLE" -ge "$MAX_CYCLES" ]]; then
    printf -- '%s [supervise-loop] max-cycles=%s reached — exiting (test mode)\n' "$(_now_iso)" "$MAX_CYCLES" >>"$LOG_FILE"
    exit 0
  fi

  sleep "$EVENT_POLL_S"
done
