#!/usr/bin/env bash
# Stop hook: advisory warning when background agents were spawned without a watchdog Monitor.
#
# Reads the session ledger written by leadv2-bg-ledger.sh.
# If BG_SPAWN lines exist AFTER the last WATCHDOG line AND the newest spawn is <30 min old:
#   emit a non-blocking advisory via additionalContext.
#
# Warn at most once per N stops (default N=3) using a stamp file to avoid spam.
# Never blocks (exit 0 always). Never loops (respects stop_hook_active).
#
# Only fires for the lead (no agent_type in hook input).
set -euo pipefail
trap 'exit 0' ERR

INPUT="$(cat 2>/dev/null || true)"
[[ -z "$INPUT" ]] && exit 0

# Respect stop_hook_active to avoid re-entry.
STOP_ACTIVE="$(printf -- '%s' "$INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null || true)"
[[ "$STOP_ACTIVE" == "true" ]] && exit 0

# Subagent guard.
AGENT_TYPE="$(printf -- '%s' "$INPUT" | jq -r '.agent_type // empty' 2>/dev/null || true)"
[[ -n "$AGENT_TYPE" ]] && exit 0

SESSION_ID="$(printf -- '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)"
[[ -z "$SESSION_ID" ]] && exit 0

SAFE_SID="$(printf -- '%s' "$SESSION_ID" | tr -cd 'A-Za-z0-9._-')"
[[ -z "$SAFE_SID" ]] && exit 0

LEDGER_FILE="/tmp/leadv2-bg-ledger/${SAFE_SID}.log"
[[ -f "$LEDGER_FILE" ]] || exit 0

# --- Throttle: warn once per WARN_EVERY stops ---
WARN_EVERY="${LEADV2_BG_WARN_EVERY:-1}"  # reduced from 3: bg-watchdog-gate now fires inline; stop warn is backstop only
STAMP_FILE="/tmp/leadv2-bg-ledger/${SAFE_SID}.stop-count"
STOP_COUNT=0
if [[ -f "$STAMP_FILE" ]]; then
  STOP_COUNT="$(cat "$STAMP_FILE" 2>/dev/null || printf '0')"
  STOP_COUNT="${STOP_COUNT//[^0-9]/}"
  STOP_COUNT="${STOP_COUNT:-0}"
fi
STOP_COUNT=$(( STOP_COUNT + 1 ))
printf -- '%s\n' "$STOP_COUNT" > "$STAMP_FILE"

# Only emit advisory on stop #1, WARN_EVERY+1, 2*WARN_EVERY+1, etc.
REMAINDER=$(( (STOP_COUNT - 1) % WARN_EVERY ))
[[ "$REMAINDER" -ne 0 ]] && exit 0

# --- Parse ledger via python3 for timestamp math ---
RESULT="$(python3 - "$LEDGER_FILE" <<'PYEOF' 2>/dev/null || true
import sys, datetime

ledger_path = sys.argv[1]

bg_spawns = []   # list of (ts_str, desc) after last WATCHDOG
last_watchdog_idx = -1

lines = []
try:
    with open(ledger_path) as f:
        lines = [l.rstrip('\n') for l in f if l.strip()]
except Exception:
    sys.exit(0)

for i, line in enumerate(lines):
    parts = line.split('\t', 2)
    if len(parts) < 2:
        continue
    ts_str, kind = parts[0], parts[1]
    if kind == 'WATCHDOG':
        last_watchdog_idx = i
    elif kind == 'BG_SPAWN':
        pass  # collected below

# Collect BG_SPAWN lines after last WATCHDOG
for i, line in enumerate(lines):
    if i <= last_watchdog_idx:
        continue
    parts = line.split('\t', 2)
    if len(parts) < 2:
        continue
    ts_str, kind = parts[0], parts[1]
    desc = parts[2] if len(parts) > 2 else ''
    if kind == 'BG_SPAWN':
        bg_spawns.append((ts_str, desc))

if not bg_spawns:
    sys.exit(0)

# Check if newest spawn is within 30 minutes
now = datetime.datetime.now(datetime.timezone.utc)
newest_ts_str = bg_spawns[-1][0]
try:
    newest_ts = datetime.datetime.fromisoformat(newest_ts_str.replace('Z', '+00:00'))
    age_minutes = (now - newest_ts).total_seconds() / 60.0
except Exception:
    age_minutes = 0.0  # parse failure → treat as recent

if age_minutes > 30:
    sys.exit(0)

n = len(bg_spawns)
descs = '; '.join(d for _, d in bg_spawns[-3:])  # last 3 descs for context
print(f"{n}|{descs}")
PYEOF
)"

[[ -z "$RESULT" ]] && exit 0

N_SPAWNS="${RESULT%%|*}"
DESCS="${RESULT#*|}"

# Emit advisory via systemMessage (non-blocking, exit 0).
# Valid for all hook events (PreToolUse, PostToolUse, Stop etc.): top-level
# {"systemMessage": "..."} is injected into next prompt without blocking.
# Do NOT use {"decision":"continue","additionalContext":...} — that shape is
# unverified for Stop hooks and has never been used in this codebase.
python3 - "$N_SPAWNS" "$DESCS" <<'PYEOF'
import sys, json

n = sys.argv[1]
descs = sys.argv[2]

msg = (
    f"[STALL-BACKSTOP] {n} background agent(s) spawned without a watchdog Monitor since "
    f"the last Monitor call. Arm a Monitor (or verify deliverables) before going idle. "
    f"Recent spawn(s): {descs}"
)

print(json.dumps({"systemMessage": msg}))
PYEOF

exit 0
