#!/usr/bin/env bash
# ~/.claude/leadv2-shared/hooks/leadv2-bg-watchdog-enforce.sh
# PostToolUse hook -- matcher should cover: Agent|Monitor|TaskStop|SendMessage
# Spec: docs/handoff/LEAD-ANCHOR-01/mission-enforce.md
#
# Complementary to leadv2-bg-watchdog-gate.sh (read first -- reused nothing
# here on purpose): gate.sh reminds on the VERY NEXT tool call after an
# unwatched Agent(run_in_background=true) spawn, keyed off the
# leadv2-bg-ledger.sh session ledger (a file this task does not own or
# extend). This hook is a *staleness + escalation* layer with its own state:
# it tolerates 2 tool calls of grace (so an immediate Monitor call still
# reads as "handled"), and hard-blocks once LEADV2_BG_ORPHAN_MAX (default 3)
# spawns are simultaneously stale. Different state, different trigger
# condition, different verdict -- not a duplicate.
#
# State: /tmp/.leadv2-bg-pending-<session-id>  (one line per unwatched spawn:
#   "<agentId>\t<turn-added>\t<description>")
#        /tmp/.leadv2-bg-turns-<session-id>    (monotonic per-session counter
#   of matched tool calls, used to measure staleness)
#
# Perf: single python3 process per invocation (reads stdin directly, no
# intermediate temp file, no second subprocess) -- this is the highest-risk
# hook in the batch (fires on every Agent/Monitor/TaskStop/SendMessage call),
# so subprocess count is kept to the minimum possible.
#
# Contract: fail-open always. Any error -> exit 0, empty stdout. <200ms.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)/leadv2-temp.sh"
trap 'exit 0' ERR

ORPHAN_MAX="${LEADV2_BG_ORPHAN_MAX:-3}"

CORE="/tmp/leadv2-bwe-core-v5.py"
if [[ ! -f "$CORE" ]]; then
  _CORE_TMP="$(lv2_mktemp_file "leadv2-bwe-core" "py" 2>/dev/null || true)"
  if [[ -n "$_CORE_TMP" ]]; then
    cat > "$_CORE_TMP" <<'PYCORE'
import sys, json, re, time, os, glob

def safe_id(raw):
    return re.sub(r'[^A-Za-z0-9._-]', '', raw or '')

# Evidence gate (JOB-LIVENESS-IS-UNOBSERVABLE-01): the turn counter only
# advances on 4 tool types and resets across compacts, so turn-staleness
# alone demands watchdogs for agents that died hours ago. Before a pending
# spawn counts as unwatched, ask its transcript whether it is still alive.
# Verdict in completed | dead | running | no-transcript | unknown; the last
# two FAIL OPEN (caller must not block on a missing/unreadable transcript).
_PROJECTS_DIR = os.path.expanduser('~/.claude/projects')
_TERMINAL_STOP = {'end_turn', 'stop_turn', 'pause_turn'}


def _find_transcripts(aid):
    """Bounded lookup of one agent's transcript(s). Returns (paths, err).
    Never raises (fail-open). Fixed-depth glob (projects/*/*/subagents/
    agent-<id>*.jsonl) -- 4x faster than `find -maxdepth 5` at an identical
    hit set (verified over 3313 transcripts), which matters because this
    hook fires on every Agent/Monitor/TaskStop/SendMessage call."""
    safe = re.sub(r'[^A-Za-z0-9._-]', '', aid or '')
    if not safe:
        return [], None
    if not os.path.isdir(_PROJECTS_DIR):
        return [], 'projects dir missing'
    try:
        return glob.glob(os.path.join(_PROJECTS_DIR, '*', '*', 'subagents',
                                      'agent-' + safe + '*.jsonl')), None
    except Exception:
        return [], 'glob failed'


def _last_stop_reason(path):
    """stop_reason of the last JSON record in the transcript tail that
    carries one, else None. Scans the tail, not just the literal last line:
    a user/tool_result record logged after an assistant end_turn carries no
    stop_reason, yet the agent is still done. Never raises."""
    try:
        size = os.path.getsize(path)
        with open(path, 'rb') as fh:
            fh.seek(max(0, size - 16384))
            tail = fh.read().decode('utf-8', errors='replace')
    except Exception:
        return None
    last_sr = None
    for cand in tail.splitlines():
        cand = cand.strip()
        if not cand:
            continue
        try:
            rec = json.loads(cand)
        except Exception:
            continue
        msg = rec.get('message')
        if isinstance(msg, dict):
            sr = msg.get('stop_reason')
            if sr:
                last_sr = sr
    return last_sr


def classify_agent(aid, fresh_secs):
    """Returns (verdict, note). completed/dead -> drop (no watchdog needed);
    running -> demand; no-transcript/unknown -> fail open (do not block)."""
    paths, err = _find_transcripts(aid)
    if err:
        return 'unknown', (aid + ': ' + err)
    if not paths:
        return 'no-transcript', (aid + ': no transcript on disk')
    best, best_mtime = None, 0.0
    for p in paths:
        try:
            m = os.path.getmtime(p)
            if m > best_mtime:
                best, best_mtime = p, m
        except Exception:
            continue
    if best is None:
        return 'unknown', (aid + ': transcript unreadable')
    sr = _last_stop_reason(best)
    if sr in _TERMINAL_STOP:
        return 'completed', None
    age = time.time() - best_mtime
    if age >= fresh_secs:
        return 'dead', (aid + ': stale %ds (stop_reason=%s)' % (int(age), sr))
    return 'running', None

def main():
    try:
        orphan_max = int(sys.argv[1]) if len(sys.argv) > 1 else 3
    except Exception:
        orphan_max = 3
    try:
        fresh_secs = int(os.environ.get('LEADV2_BG_TRANSCRIPT_FRESH_SECS', '900'))
    except Exception:
        fresh_secs = 900
    if fresh_secs <= 0:
        fresh_secs = 900

    try:
        data = json.loads(sys.stdin.read())
    except Exception:
        return
    if not isinstance(data, dict):
        return

    # Subagents carry agent_type; only the lead is in scope.
    if data.get('agent_type'):
        return

    tool_name = data.get('tool_name', '') or ''
    if tool_name not in ('Agent', 'Monitor', 'TaskStop', 'SendMessage'):
        return

    sid = safe_id(data.get('session_id', ''))
    if not sid:
        return

    pending_path = f"/tmp/.leadv2-bg-pending-{sid}"
    turns_path = f"/tmp/.leadv2-bg-turns-{sid}"

    turn = 0
    try:
        with open(turns_path, encoding='utf-8') as fh:
            turn = int((fh.read() or '0').strip() or '0')
    except Exception:
        turn = 0
    turn += 1
    try:
        with open(turns_path, 'w', encoding='utf-8') as fh:
            fh.write(str(turn))
    except Exception:
        pass

    entries = []
    try:
        with open(pending_path, encoding='utf-8') as fh:
            for line in fh:
                line = line.rstrip('\n')
                if not line:
                    continue
                parts = line.split('\t', 2)
                if len(parts) == 3:
                    entries.append(parts)
    except Exception:
        entries = []

    tool_input = data.get('tool_input', {}) or {}
    if not isinstance(tool_input, dict):
        tool_input = {}

    if tool_name == 'Agent':
        is_bg = str(tool_input.get('run_in_background', False)).lower() == 'true'
        if is_bg:
            tool_response = data.get('tool_response', {})
            agent_id = ''
            if isinstance(tool_response, dict):
                agent_id = str(tool_response.get('agentId') or tool_response.get('agent_id') or '')
            desc_raw = tool_input.get('description') or tool_input.get('prompt') or 'bg-agent'
            desc = str(desc_raw).replace('\t', ' ').replace('\n', ' ')[:80]
            if not agent_id:
                agent_id = f"a{abs(hash(desc)) % 100000}"
            entries.append([agent_id, str(turn), desc])
    else:
        # Monitor / TaskStop / SendMessage: try to clear pending entries whose
        # agentId or description text appears referenced in this call.
        blob = json.dumps(tool_input, ensure_ascii=False)
        kept = []
        for e in entries:
            aid, t_added, desc = e
            matched = bool(aid) and aid in blob
            if not matched:
                for key in ('path', 'agentId', 'agent_id', 'file', 'deliverable'):
                    v = tool_input.get(key)
                    if v and (str(v) in desc or desc in str(v)):
                        matched = True
                        break
            if not matched:
                kept.append(e)
        entries = kept

    try:
        with open(pending_path, 'w', encoding='utf-8') as fh:
            for e in entries:
                fh.write('\t'.join(e) + '\n')
    except Exception:
        pass

    stale = []
    for aid, t_added, desc in entries:
        try:
            added = int(t_added)
        except Exception:
            added = turn
        if turn - added < 2:
            continue
        # Evidence gate: only demand a watchdog if the transcript says the
        # spawn is genuinely still running. completed/dead (often died hours
        # ago) are dropped; no-transcript/unknown fail open (never block).
        verdict, _note = classify_agent(aid, fresh_secs)
        if verdict == 'running':
            stale.append((aid, desc))

    if not stale:
        return

    ids = ', '.join(a for a, _ in stale)
    if len(stale) >= orphan_max:
        msg = (
            f"{len(stale)} background agents have no watchdog: {ids}. "
            "Pair each with Monitor on its deliverable path, or you will not "
            "notice when they die."
        )
        print(json.dumps({"decision": "block", "reason": msg}))
    else:
        msg = (
            f"{len(stale)} background agent(s) have no watchdog: {ids}. "
            "Pair each with Monitor on its deliverable path, or you will not "
            "notice when they die."
        )
        print(json.dumps({"additionalContext": msg}))

try:
    main()
except Exception:
    pass
PYCORE
    mv -f "$_CORE_TMP" "$CORE" 2>/dev/null || true
  fi
fi

[[ -f "$CORE" ]] || exit 0
python3 "$CORE" "$ORPHAN_MAX" 2>/dev/null || true
exit 0
