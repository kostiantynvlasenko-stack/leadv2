#!/bin/bash
# leadv2-state-compact.sh — produce Phase-0 startup briefing in <40 lines.
#
# Replaces the 3-file startup read sequence (git status / LEAD_V2_STATE / QUEUE top).
# Outputs:
#   - HEAD oneliner
#   - Active sessions table (from active.yaml, not the rendered file)
#   - Recent history (from LEAD_V2_STATE.md)
#   - Top 5 unclaimed across lanes (recovery > action > intelligence) via dry-run claim
#   - PO last-meeting + sessions_since
#
# Usage: leadv2-state-compact.sh [project_root]
# Default: cwd.

set -euo pipefail

root="${1:-$(pwd)}"
state_md="$root/docs/LEAD_V2_STATE.md"
active_yaml="$root/docs/leadv2/active.yaml"
po_state="$root/docs/agents/product-owner/STATE.md"
queue_claim_sh="$root/.claude/scripts/leadv2-queue-claim.sh"

echo "=== HEAD ==="
git -C "$root" log -1 --oneline 2>/dev/null || echo "(not a git repo)"
echo

echo "=== Active sessions ==="
if [[ -f "$active_yaml" ]]; then
  python3 - "$active_yaml" <<'PYEOF' 2>/dev/null || echo "(yaml parse failed)"
import sys, yaml
with open(sys.argv[1]) as f:
    d = yaml.safe_load(f) or {}
sessions = d.get("sessions") or []
hard = (d.get("meta") or {}).get("hard_limit", 2)
if not sessions:
    print(f"(none — 0/{hard} max)")
else:
    print(f"{len(sessions)}/{hard} active:")
    for s in sessions:
        print(f"  - {s.get('task_id','?')} phase={s.get('phase','?')} class={s.get('class','?')} started={(s.get('started_at') or '')[:16]}")
PYEOF
else
  echo "(no active.yaml)"
fi

# Extract claimed task IDs from active.yaml for queue filtering below
_claimed_ids=""
if [[ -f "$active_yaml" ]]; then
  _claimed_ids=$(python3 - "$active_yaml" 2>/dev/null <<'PYEOF'
import sys, yaml
with open(sys.argv[1]) as f:
    d = yaml.safe_load(f) or {}
ids = [s.get("task_id","") for s in (d.get("sessions") or []) if s.get("task_id","")]
print("|".join(ids))
PYEOF
  )
fi

# Also detect orphaned worktrees: exist on disk but not in active.yaml
_orphan_ids=""
_orphan_list=""
while IFS= read -r line; do
  # git worktree list format: <path>  <sha>  [<branch>]
  wt_path=$(echo "$line" | awk '{print $1}')
  # Match worktrees under .claude/worktrees/<task-id>
  if [[ "$wt_path" == *"/.claude/worktrees/"* ]]; then
    task_id="${wt_path##*/.claude/worktrees/}"
    [[ -z "$task_id" || "$task_id" == "." ]] && continue
    # Skip if already in active.yaml
    if [[ -n "$_claimed_ids" ]] && echo "$_claimed_ids" | grep -qF "$task_id"; then
      continue
    fi
    _orphan_ids="${_orphan_ids}|${task_id}"
    _orphan_list="${_orphan_list}  - ${task_id} (worktree exists, no active.yaml entry)\n"
  fi
done < <(git -C "$root" worktree list 2>/dev/null)

# Merge orphan IDs into claimed filter
if [[ -n "$_orphan_ids" ]]; then
  if [[ -n "$_claimed_ids" ]]; then
    _claimed_ids="${_claimed_ids}${_orphan_ids}"
  else
    _claimed_ids="${_orphan_ids#|}"
  fi
fi

if [[ -n "$_orphan_list" ]]; then
  echo "=== В работе (orphaned worktree — нет в active.yaml) ==="
  printf '%b' "$_orphan_list"
  echo
fi
echo

echo "=== Recent history (LEAD_V2_STATE) ==="
if [[ -f "$state_md" ]]; then
  awk '/^## Recent history/,/^## [^R]/ { if ($0 !~ /^## /) print }' "$state_md" | head -10 || true
else
  echo "(missing $state_md)"
fi
echo

echo "=== PO meeting freshness ==="
if [[ -f "$po_state" ]]; then
  grep -E "^Last (updated|meeting)" "$po_state" 2>/dev/null | head -2
else
  echo "(missing PO STATE.md)"
fi
echo

echo "=== QUEUE — top 5 unclaimed (recovery > action > intelligence) ==="
if [[ -x "$queue_claim_sh" ]] || [[ -f "$queue_claim_sh" ]]; then
  _queue_out=$(PROJECT_ROOT="$root" bash "$queue_claim_sh" --dry-run --top-n 20 2>/dev/null || true)
  if [[ -z "$_queue_out" ]]; then
    echo "  (no claimable items or claim script error)"
  else
    _count=0
    while IFS=$'\t' read -r lane pri id title; do
      # Skip tasks that have already been closed via docs/leadv2/closed/ sentinel
      [[ -f "${root}/docs/leadv2/closed/${id}.yaml" ]] && continue
      # Skip tasks whose STATE.md contains status: closed
      state_file="${root}/docs/leadv2/tasks/${id}/STATE.md"
      if [[ -f "$state_file" ]] && grep -q "status: closed" "$state_file"; then
        continue
      fi
      printf '  [%s] %-10s %s\n' "$pri" "${lane}:${id}" "$title"
      _count=$(( _count + 1 ))
      [[ "$_count" -ge 5 ]] && break
    done <<< "$_queue_out"
    [[ "$_count" -eq 0 ]] && echo "  (all candidates closed — nothing claimable)"
  fi
else
  echo "(missing $queue_claim_sh)"
fi

python3 "${root}/scripts/queue-archive.py" 2>/dev/null || true

# ── Warn: open [ ] items in frozen QUEUE.md ──────────────────────────────
_qmd="${root}/docs/agents/product-owner/QUEUE.md"
if [[ -f "$_qmd" ]]; then
  _qmd_open=$(grep -c '^\s*- \[ \]' "$_qmd" 2>/dev/null || true)
  _qmd_open="${_qmd_open:-0}"
  if [[ "${_qmd_open%%$'\n'*}" -gt 0 ]] 2>/dev/null; then
    echo "⚠️  QUEUE.md orphans: ${_qmd_open} open [ ] task(s) not in yaml queues — migrate or close them"
    grep '^\s*- \[ \]' "$_qmd" | head -5 | sed 's/.*\[ \] /  /'
  fi
fi

# ── Warn: orphaned in_progress items (no active session, expired/no lease) ──
# Bridge mode: prefer tasks.yaml when present; fall back to lane yamls.
_tasks_yaml="${root}/docs/tasks.yaml"
if [[ -f "$active_yaml" ]]; then
  if [[ -f "$_tasks_yaml" ]]; then
    python3 - "$active_yaml" "$_tasks_yaml" <<'PYEOF' 2>/dev/null || true
import sys, yaml, datetime

active_f   = sys.argv[1]
tasks_file = sys.argv[2]
with open(active_f) as f:
    active = yaml.safe_load(f) or {}
active_ids = {s.get('task_id','') for s in (active.get('sessions') or [])}

items = yaml.safe_load(open(tasks_file)) or []
now = datetime.datetime.utcnow()
orphans = []
for it in (items if isinstance(items, list) else []):
    if not isinstance(it, dict): continue
    if it.get('status') not in ('in_progress', 'in-progress'): continue
    if it.get('id') in active_ids: continue
    claim = it.get('claim') or {}
    lease = claim.get('lease_expires')
    expired = True
    if lease:
        try:
            ls = str(lease).replace('Z','').replace(' ','T')
            if '+' in ls: ls = ls.split('+')[0]
            expired = now >= datetime.datetime.strptime(ls, '%Y-%m-%dT%H:%M:%S')
        except Exception:
            pass
    if expired:
        lane = it.get('lane', '?')
        orphans.append(f"  {it.get('id','?')} [{lane}] — in_progress, no active session")

if orphans:
    print(f"⚠️  Orphaned in_progress ({len(orphans)}): reset to pending manually or via /leadv2")
    for o in orphans[:5]:
        print(o)
PYEOF
  else
    python3 - "$active_yaml" "${root}/docs/agents/product-owner/queue" <<'PYEOF' 2>/dev/null || true
import sys, yaml, os, datetime

active_f  = sys.argv[1]
queue_dir = sys.argv[2]
with open(active_f) as f:
    active = yaml.safe_load(f) or {}
active_ids = {s.get('task_id','') for s in (active.get('sessions') or [])}

now = datetime.datetime.utcnow()
orphans = []
for lane in ('action', 'recovery', 'intelligence'):
    lf = os.path.join(queue_dir, f'{lane}.yaml')
    if not os.path.isfile(lf):
        continue
    items = yaml.safe_load(open(lf)) or []
    for it in items:
        if it.get('status') not in ('in_progress', 'in-progress'):
            continue
        if it.get('id') in active_ids:
            continue
        claim = it.get('claim') or {}
        lease = claim.get('lease_expires')
        expired = True
        if lease:
            try:
                ls = str(lease).replace('Z','').replace(' ','T')
                if '+' in ls: ls = ls.split('+')[0]
                expired = now >= datetime.datetime.strptime(ls, '%Y-%m-%dT%H:%M:%S')
            except Exception:
                pass
        if expired:
            orphans.append(f"  {it.get('id','?')} [{lane}] — in_progress, no active session")

if orphans:
    print(f"⚠️  Orphaned in_progress ({len(orphans)}): reset to pending manually or via /leadv2")
    for o in orphans[:5]:
        print(o)
PYEOF
  fi
fi
