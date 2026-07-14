#!/usr/bin/env bash
# ~/.claude/leadv2-shared/hooks/leadv2-auto-status.sh
# PostToolUse hook -- matcher `.*` (fires on EVERY tool call).
# Spec: docs/handoff/LEAD-ANCHOR-01/mission-enforce.md
#
# Every LEADV2_STATUS_EVERY (default 15) lead tool calls, prints a compact
# (<=12 line) status block from local files only -- no network:
#   - active task + phase (docs/leadv2/active.md)
#   - up to 6 open tasks (docs/tasks.yaml), labeled in_progress/open
#   - count of DUE/OVERDUE scheduled-decisions.md rows
#   - count of background agents with no watchdog (leadv2-bg-watchdog-enforce
#     state file, read-only here -- never written by this hook)
#
# Perf: single python3 process per invocation (reads stdin directly). The
# every-Nth check happens BEFORE any file parsing, so 14/15 calls do only a
# counter increment + a single isdir check. tasks.yaml parse result is
# cached in /tmp keyed on the file's mtime; only re-parsed when it changes.
# This is the highest-risk hook in the batch (matcher `.*`, EVERY tool call)
# -- kept to one subprocess, fail-open throughout.
#
# Contract: fail-open always. Any error -> exit 0, empty stdout. <200ms.
# Quiet no-op outside a leadv2 repo (no docs/leadv2/) or when
# LEADV2_AUTO_STATUS=0.
set -euo pipefail
trap 'exit 0' ERR

CORE="/tmp/leadv2-astatus-core-v2.py"
if [[ ! -f "$CORE" ]]; then
  _CORE_TMP="$(mktemp /tmp/leadv2-astatus-core-XXXXXX.py 2>/dev/null || true)"
  if [[ -n "$_CORE_TMP" ]]; then
    cat > "$_CORE_TMP" <<'PYCORE'
import sys, json, os, re, datetime

def safe_id(raw):
    return re.sub(r'[^A-Za-z0-9._-]', '', raw or '')

def parse_tasks_yaml(path):
    try:
        with open(path, encoding='utf-8') as fh:
            lines = fh.readlines()
    except Exception:
        return {"total_open": None, "rows": []}
    total_open = None
    rows = []
    cur = None
    for line in lines:
        m = re.match(r'^total_open:\s*(\d+)', line)
        if m:
            total_open = int(m.group(1))
            continue
        m = re.match(r'^- id:\s*(\S+)', line)
        if m:
            if cur:
                rows.append(cur)
            cur = {"id": m.group(1), "status": "", "intent": ""}
            continue
        if cur is not None:
            m = re.match(r'^\s+status:\s*(\S+)', line)
            if m and not cur["status"]:
                cur["status"] = m.group(1)
                continue
            m = re.match(r"^\s+intent:\s*'?(.*)", line)
            if m and not cur["intent"]:
                txt = m.group(1).rstrip("'\"")
                cur["intent"] = txt[:60]
                continue
    if cur:
        rows.append(cur)
    return {"total_open": total_open, "rows": rows}

def load_tasks_cached(path):
    try:
        st = os.stat(path)
    except Exception:
        return {"total_open": None, "rows": []}
    cache_key = safe_id(path)[-100:]
    cache_path = f"/tmp/.leadv2-tasks-cache-{cache_key}.json"
    try:
        with open(cache_path, encoding='utf-8') as fh:
            cache = json.load(fh)
        if cache.get('mtime') == st.st_mtime:
            return cache.get('data', {"total_open": None, "rows": []})
    except Exception:
        pass
    data = parse_tasks_yaml(path)
    try:
        with open(cache_path, 'w', encoding='utf-8') as fh:
            json.dump({'mtime': st.st_mtime, 'data': data}, fh)
    except Exception:
        pass
    return data

def parse_active(path):
    try:
        with open(path, encoding='utf-8') as fh:
            content = fh.readlines()
    except Exception:
        return None
    rows = []
    for line in content:
        s = line.strip()
        if not s.startswith('|') or s.startswith('|---') or s.startswith('| ---'):
            continue
        cols = [c.strip() for c in s.strip('|').split('|')]
        if len(cols) >= 3 and cols[0] and cols[0] != 'task_id':
            rows.append(cols)
    if not rows:
        return None
    first = rows[0]
    task_id = first[0] if len(first) > 0 else ''
    phase = first[2] if len(first) > 2 else ''
    if not task_id:
        return None
    return {"task_id": task_id, "phase": phase}

def count_due(path):
    try:
        with open(path, encoding='utf-8') as fh:
            content = fh.read()
    except Exception:
        return 0
    m = re.search(r'^## OPEN\s*$(.*?)(^## CLOSED\s*$|\Z)', content, re.MULTILINE | re.DOTALL)
    block = m.group(1) if m else ''
    rows = re.split(r'(?=^### )', block, flags=re.MULTILINE)
    today = datetime.date.today()
    count = 0
    for row in rows:
        if not row.strip():
            continue
        due_m = re.search(r'\*\*Due\*\*\s*\|\s*(.*?)\s*\|', row)
        due_raw = due_m.group(1) if due_m else ''
        date_m = re.search(r'\b(\d{4}-\d{2}-\d{2})\b', due_raw)
        if date_m:
            try:
                d = datetime.date.fromisoformat(date_m.group(1))
                if d <= today:
                    count += 1
            except Exception:
                pass
        elif due_raw:
            count += 1
    return count

def main():
    try:
        data = json.loads(sys.stdin.read())
    except Exception:
        return
    if not isinstance(data, dict):
        return
    if data.get('agent_type'):
        return
    if os.environ.get('LEADV2_AUTO_STATUS', '1') == '0':
        return

    cwd = data.get('cwd') or os.getcwd()
    docs_leadv2 = os.path.join(cwd, 'docs', 'leadv2')
    if not os.path.isdir(docs_leadv2):
        return

    sid = safe_id(data.get('session_id', ''))
    if not sid:
        return

    turns_path = f"/tmp/.leadv2-turns-{sid}"
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

    try:
        every = int(os.environ.get('LEADV2_STATUS_EVERY', '15') or '15')
    except Exception:
        every = 15
    if every <= 0 or turn % every != 0:
        return

    lines = []
    try:
        active = parse_active(os.path.join(docs_leadv2, 'active.md'))
    except Exception:
        active = None
    lines.append(
        f"Active: {active['task_id']} (phase {active.get('phase') or '?'})"
        if active else "Active: none"
    )

    try:
        tasks = load_tasks_cached(os.path.join(cwd, 'docs', 'tasks.yaml'))
    except Exception:
        tasks = {"total_open": None, "rows": []}
    open_rows = [
        r for r in tasks.get('rows', [])
        if r.get('status') not in ('done', 'closed', 'complete', 'resolved')
    ]
    open_rows.sort(key=lambda r: 0 if r.get('status') == 'in_progress' else 1)
    shown = open_rows[:6]
    if shown:
        lines.append(f"Open tasks ({len(shown)}/{len(open_rows)}):")
        for r in shown:
            label = 'in_progress' if r.get('status') == 'in_progress' else 'open'
            lines.append(f"  {r['id']} [{label}] {r.get('intent', '')[:60]}")
    else:
        lines.append("Open tasks: none")

    try:
        due_n = count_due(os.path.join(docs_leadv2, 'scheduled-decisions.md'))
    except Exception:
        due_n = 0
    lines.append(f"Scheduled decisions DUE/OVERDUE: {due_n}")

    pending_path = f"/tmp/.leadv2-bg-pending-{sid}"
    orphan_n = 0
    try:
        with open(pending_path, encoding='utf-8') as fh:
            orphan_n = sum(1 for l in fh if l.strip())
    except Exception:
        orphan_n = 0
    lines.append(f"Background agents without watchdog: {orphan_n}")

    lines.append("STATUS — покажи это фаундеру, если он давно не видел статус.")

    lines = lines[:12]
    print(json.dumps({"additionalContext": "\n".join(lines)}))

try:
    main()
except Exception:
    pass
PYCORE
    mv -f "$_CORE_TMP" "$CORE" 2>/dev/null || true
  fi
fi

[[ -f "$CORE" ]] || exit 0
python3 "$CORE" 2>/dev/null || true
exit 0
