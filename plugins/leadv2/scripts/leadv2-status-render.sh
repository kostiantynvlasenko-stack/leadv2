#!/usr/bin/env bash
# leadv2-status-render.sh — render the last collected snapshot. NO probes,
# NO agent spawn, NO network. One file read.
#
# STATUS-COLLECTOR-01. Pairs with leadv2-status-collector.sh. The lead should
# call this for the periodic [STATUS] pulse instead of re-deriving DB/engine/
# lane facts inline every time.
#
# Staleness and failure are ALWAYS visible — a stale number presented as
# current, or a zero standing in for "could not measure", is worse than no
# number (mission D). A section with ok:false renders as
# "не удалось измерить", never as 0.
#
# Usage: leadv2-status-render.sh [--project-root <dir>] [--snapshot <path>]
#                                 [--max-age-sec N]
# Exit codes: 0 rendered (fresh or stale-but-shown) · 2 collector disabled
#             (rollback sentinel present — caller should fall back to the
#             legacy agent-spawn status) · 3 no snapshot yet.

set -uo pipefail

PROJECT_ROOT="${PROJECT_ROOT:-$(pwd)}"
SNAPSHOT_PATH=""
MAX_AGE_SEC=900   # collector runs "every few minutes" per mission — 15m default
while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-root) PROJECT_ROOT="$2"; shift 2;;
    --snapshot) SNAPSHOT_PATH="$2"; shift 2;;
    --max-age-sec) MAX_AGE_SEC="$2"; shift 2;;
    -h|--help)
      echo "Usage: leadv2-status-render.sh [--project-root <dir>] [--snapshot <path>] [--max-age-sec N]"
      exit 0;;
    *) shift;;
  esac
done
PROJECT_ROOT="$(cd "$PROJECT_ROOT" && pwd)"
: "${SNAPSHOT_PATH:=$PROJECT_ROOT/docs/leadv2/status-snapshot.json}"

DISABLE_SENTINEL="$PROJECT_ROOT/docs/leadv2/.status-collector-disabled"
if [[ -f "$DISABLE_SENTINEL" || "${STATUS_COLLECTOR_DISABLED:-0}" == "1" ]]; then
  echo "STATUS_COLLECTOR_DISABLED: fall back to legacy agent-spawn status (rollback sentinel: $DISABLE_SENTINEL)"
  exit 2
fi

if [[ ! -f "$SNAPSHOT_PATH" ]]; then
  echo "нет снапшота — коллектор ещё не запускался ($SNAPSHOT_PATH отсутствует)"
  exit 3
fi

MAX_AGE_SEC="$MAX_AGE_SEC" python3 -c "
import json, sys, datetime

path = sys.argv[1]
max_age = int(sys.argv[2])

try:
    snap = json.load(open(path))
except Exception as e:
    print(f'снапшот повреждён ({e.__class__.__name__}) — {path}')
    sys.exit(3)

collected_at_raw = snap.get('collected_at')
try:
    collected_at = datetime.datetime.fromisoformat(collected_at_raw.replace('Z', '+00:00'))
except Exception:
    collected_at = None

now = datetime.datetime.now(datetime.timezone.utc)
age_s = int((now - collected_at).total_seconds()) if collected_at else None

lines = []
if age_s is None:
    lines.append('[STATUS] снапшот без collected_at — считаем протухшим')
elif age_s > max_age:
    mins = age_s // 60
    lines.append(f'[STATUS] ⚠ СНАПШОТ УСТАРЕЛ на {mins}м (собран {collected_at_raw}, порог {max_age//60}м)')
else:
    lines.append(f'[STATUS] снапшот {age_s}s назад ({collected_at_raw})')

sections = snap.get('sections', {})

def sec(name):
    s = sections.get(name)
    if s is None:
        return None, None
    return s.get('ok'), s.get('data')

# git
ok, data = sec('git')
if ok is None:
    lines.append('  GIT: (не собрано)')
elif not ok:
    lines.append('  GIT: не удалось измерить')
else:
    up = data.get('unpushed')
    up_s = 'unknown' if up is None else str(up)
    lines.append(f\"  GIT: HEAD={data.get('local_head','?')} branch={data.get('branch','?')} unpushed={up_s}\")

# lanes (nested leadv2-supervise.sh --json output)
ok, data = sec('lanes')
if ok is None:
    lines.append('  LANES: (не собрано)')
elif not ok:
    lines.append('  LANES: не удалось измерить')
else:
    table = data.get('table') if isinstance(data, dict) else None
    if isinstance(table, list):
        lines.append(f'  LANES: {len(table)} row(s)')
        for row in table[:20]:
            tid = row.get('task_id', '?')
            phase = row.get('phase', '?')
            status = row.get('status', '?')
            waiting = 'waiting' if row.get('waiting') else ''
            reason = row.get('status_reason') or ''
            lines.append(f'    {tid:<28} {phase:<14} {status:<10} {waiting} {reason}')
    else:
        lines.append('  LANES: (unexpected shape — see raw snapshot)')
    degraded = data.get('degraded') if isinstance(data, dict) else None
    if isinstance(degraded, list) and degraded:
        lines.append(f'  DEGRADED DISPATCHES ({len(degraded)}):')
        for item in degraded[:20]:
            lines.append(f\"    {item.get('task_id','?')}: architect prepass {item.get('reason','?')}; raw mission dispatched\")
    questions = data.get('requires_founder') if isinstance(data, dict) else None
    if isinstance(questions, list) and questions:
        lines.append(f'  ОТКРЫТЫЕ ВОПРОСЫ ({len(questions)}):')
        for q in questions[:10]:
            age_m = (q.get('age_seconds') or 0) // 60
            lines.append(f\"    [{q.get('task_id','?')}] {q.get('summary_for_lead', q.get('question','?'))} ({age_m}m)\")
    stuck = data.get('stuck') if isinstance(data, dict) else None
    if isinstance(stuck, list) and stuck:
        lines.append(f'  ЗАСТРЯЛО ({len(stuck)}): ' + ', '.join(s.get('task_id','?') for s in stuck[:10]))

# repo_facts — repo-specific, rendered generically key by key so this stays
# repo-agnostic; a repo's facts hook controls exactly what shows up here.
ok, data = sec('repo_facts')
if ok is None:
    pass  # no hook installed for this repo — nothing to render, not an error
elif not ok:
    lines.append('  REPO FACTS: не удалось измерить (см. снапшот)')
elif isinstance(data, dict):
    for key, val in data.items():
        if isinstance(val, dict) and val.get('ok') is False:
            lines.append(f'  {key}: не удалось измерить' + (f\" ({val['error']})\" if 'error' in val else ''))
        else:
            lines.append(f'  {key}: {json.dumps(val, ensure_ascii=False)}')

print('\n'.join(lines))
" "$SNAPSHOT_PATH" "$MAX_AGE_SEC"
