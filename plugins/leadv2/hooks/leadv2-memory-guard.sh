#!/usr/bin/env bash
# PreToolUse hook (Write|Edit matcher) — guard global MEMORY.md from leadv2 sessions.
#
# When an active leadv2 task is running (LEADV2_TASK_ID set OR docs/leadv2/active.yaml
# has sessions), any Write or Edit targeting */memory/MEMORY.md is DENIED.
# Route durable facts to docs/leadv2/immune-patterns.yaml instead.
#
# Block-once-then-pass: a per-session retry sentinel prevents deadlock.
# On the first block for this session+path, deny and write the sentinel.
# If the sentinel already exists (retry), allow the write and remove sentinel.
# Sentinel dir: /tmp/leadv2-memory-guard/

set -euo pipefail
trap 'exit 0' ERR

INPUT="$(cat 2>/dev/null || true)"
[[ -z "$INPUT" ]] && exit 0

# ---------------------------------------------------------------------------
# 1. Extract file_path from tool input (Write or Edit both use file_path)
# ---------------------------------------------------------------------------
FILE_PATH="$(printf '%s' "$INPUT" | python3 -c "
import sys, json
try:
    data = json.loads(sys.stdin.read())
    inp = data.get('tool_input', data)
    fp = inp.get('file_path', inp.get('path', ''))
    print(fp)
except Exception:
    pass
" 2>/dev/null || true)"

[[ -z "$FILE_PATH" ]] && exit 0

# ---------------------------------------------------------------------------
# 2. Check if path targets */memory/MEMORY.md
# ---------------------------------------------------------------------------
if [[ "$FILE_PATH" != */memory/MEMORY.md ]]; then
    exit 0
fi

# ---------------------------------------------------------------------------
# 3. Check if an active leadv2 task is running
# ---------------------------------------------------------------------------
_is_active_leadv2() {
    # Check env var first (fast path)
    if [[ -n "${LEADV2_TASK_ID:-}" ]]; then
        return 0
    fi
    # Check docs/leadv2/active.yaml for sessions list
    _root="${LEADV2_PROJECT_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
    local active_yaml="${_root}/docs/leadv2/active.yaml"
    if [[ -f "$active_yaml" ]]; then
        local sessions
        sessions=$(python3 -c "
import sys, yaml
try:
    data = yaml.safe_load(open('$active_yaml')) or {}
    sessions = data.get('sessions', [])
    print('yes' if sessions else 'no')
except Exception:
    print('no')
" 2>/dev/null || echo "no")
        [[ "$sessions" == "yes" ]] && return 0
    fi
    return 1
}

if ! _is_active_leadv2; then
    # No active leadv2 task — allow the write
    exit 0
fi

# ---------------------------------------------------------------------------
# 4. Block-once-then-pass sentinel logic
# ---------------------------------------------------------------------------
SESSION_KEY="${LEADV2_TASK_ID:-leadv2}"
# Stable key from task id + file path hash
PATH_HASH=$(printf '%s' "$FILE_PATH" | python3 -c "
import sys, hashlib
print(hashlib.sha1(sys.stdin.read().encode()).hexdigest()[:8])
" 2>/dev/null || echo "00000000")
SENTINEL_DIR="/tmp/leadv2-memory-guard"
SENTINEL_FILE="${SENTINEL_DIR}/${SESSION_KEY}_${PATH_HASH}.blocked"

mkdir -p "$SENTINEL_DIR"

if [[ -f "$SENTINEL_FILE" ]]; then
    # Second attempt (retry) — allow and clear sentinel
    rm -f "$SENTINEL_FILE"
    exit 0
fi

# First attempt — deny and write sentinel
touch "$SENTINEL_FILE"

# Emit deny response using exact PreToolUse schema
trap - ERR
python3 -c "
import sys, json
print(json.dumps({
    'hookSpecificOutput': {
        'hookEventName': 'PreToolUse',
        'permissionDecision': 'deny',
        'permissionDecisionReason': 'Route durable facts to docs/leadv2/immune-patterns.yaml; keep global MEMORY.md thin.'
    }
}))
" 2>/dev/null
exit 2
