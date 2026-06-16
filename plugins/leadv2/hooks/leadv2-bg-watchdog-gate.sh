#!/usr/bin/env bash
# PostToolUse:Agent hook -- watchdog gate for background agent spawns.
# Spec: docs/handoff/ANTI-AMNESIA-01/design.md sec 4B
#
# Fires after every Agent tool call. If run_in_background=true and no WATCHDOG
# entry follows the most recent BG_SPAWN in the session ledger, injects a
# blocking additionalContext reminder to arm a Monitor watchdog immediately.
#
# Reuses ledger and agent_type guard from leadv2-bg-ledger.sh.
# Only fires for the lead (subagents have agent_type set -> exit 0).
# Non-blocking in all error paths: trap exits 0 on any failure.
# Default-on: no opt-out. Monitor after every bg spawn is mandatory.
set -euo pipefail
trap 'exit 0' ERR  # lean: replaced below after _CHECKER_TMP assigned — upgrade when early-exit cleanup needed

INPUT="$(python3 -c 'import sys; print(sys.stdin.read())' 2>/dev/null || true)"
[[ -z "$INPUT" ]] && exit 0

# Subagent guard: lead has no agent_type field; subagents do.
AGENT_TYPE="$(printf -- '%s' "$INPUT" | python3 -c \
  'import sys,json; d=json.loads(sys.stdin.read()); print(d.get("agent_type",""))' \
  2>/dev/null || true)"
[[ -n "$AGENT_TYPE" ]] && exit 0

TOOL_NAME="$(printf -- '%s' "$INPUT" | python3 -c \
  'import sys,json; d=json.loads(sys.stdin.read()); print(d.get("tool_name",""))' \
  2>/dev/null || true)"
[[ "$TOOL_NAME" != "Agent" ]] && exit 0

IS_BG="$(printf -- '%s' "$INPUT" | python3 -c \
  'import sys,json; d=json.loads(sys.stdin.read()); print(str(d.get("tool_input",{}).get("run_in_background",False)).lower())' \
  2>/dev/null || true)"
[[ "$IS_BG" != "true" ]] && exit 0

SESSION_ID="$(printf -- '%s' "$INPUT" | python3 -c \
  'import sys,json; d=json.loads(sys.stdin.read()); print(d.get("session_id",""))' \
  2>/dev/null || true)"
[[ -z "$SESSION_ID" ]] && exit 0

SAFE_SID="$(printf -- '%s' "$SESSION_ID" | tr -cd 'A-Za-z0-9._-')"
[[ -z "$SAFE_SID" ]] && exit 0

LEDGER_FILE="/tmp/leadv2-bg-ledger/${SAFE_SID}.log"
[[ -f "$LEDGER_FILE" ]] || exit 0

# Write the ledger-checker python script to a version-stamped tmp path.
# M2 fix: write atomically via mktemp + mv -f to eliminate [[ ! -f ]] + write race.
# Increment version suffix when logic inside the checker changes.
CHECKER="/tmp/leadv2-wdgate-check-v2.py"
_CHECKER_TMP="$(mktemp /tmp/leadv2-wdgate-XXXXXX.py)"
# M-4: extend trap to clean temp file on both ERR and EXIT
trap 'rm -f "${_CHECKER_TMP:-}"; exit 0' ERR EXIT
python3 - "$_CHECKER_TMP" <<'WRITE_CHECKER'
import sys
dst = sys.argv[1]
code = (
    "import sys\n"
    "ledger = sys.argv[1]\n"
    "lines = []\n"
    "try:\n"
    "    with open(ledger) as fh:\n"
    "        lines = [l.rstrip() for l in fh if l.strip()]\n"
    "except Exception:\n"
    "    sys.exit(0)\n"
    "last_watchdog = -1\n"
    "for i, line in enumerate(lines):\n"
    "    parts = line.split(chr(9), 2)\n"
    "    if len(parts) >= 2 and parts[1] == 'WATCHDOG':\n"
    "        last_watchdog = i\n"
    "for i, line in enumerate(lines):\n"
    "    if i <= last_watchdog:\n"
    "        continue\n"
    "    parts = line.split(chr(9), 2)\n"
    "    if len(parts) >= 2 and parts[1] == 'BG_SPAWN':\n"
    "        desc = parts[2] if len(parts) > 2 else '(no description)'\n"
    "        print(desc)\n"
    "        break\n"
)
with open(dst, "w") as fh:
    fh.write(code)
WRITE_CHECKER
mv -f "$_CHECKER_TMP" "$CHECKER"

DESC="$(python3 "$CHECKER" "$LEDGER_FILE" 2>/dev/null || true)"
[[ -z "$DESC" ]] && exit 0

python3 -c '
import json, sys
desc = sys.argv[1]
msg = (
    "[WATCHDOG REQUIRED] Background agent spawned without a Monitor watchdog. "
    "Call Monitor(path=<deliverable-path>) as your NEXT action before any other tool. "
    "If the completion ping is lost without a Monitor armed, the session stalls indefinitely. "
    "Spawn description: " + desc
)
print(json.dumps({"additionalContext": msg}))
' "$DESC"

exit 0
