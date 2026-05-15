#!/usr/bin/env bash
# leadv2-checkpoint.sh — snapshot campaign state into a SESSION-RESUME file.
# Multi-session safe: read under shared lock; SESSION-RESUME unique per session.
#
# Usage:
#   leadv2-checkpoint.sh                # writes timestamped resume file
#   leadv2-checkpoint.sh --print        # also prints the path

set -euo pipefail

QUEUE="${LEADV2_TASK_QUEUE:-docs/leadv2/tasks.yaml}"
LOCK_PATH="docs/leadv2/.task-queue.lock"
[[ -f "$LOCK_PATH" ]] || : > "$LOCK_PATH"
PRINT_PATH="false"
[[ "${1:-}" == "--print" ]] && PRINT_PATH="true"

[[ -f "$QUEUE" ]] || { echo "ERROR: $QUEUE not found" >&2; exit 1; }

HANDOFF_DIR=$(LOCK_PATH="$LOCK_PATH" python3 -c "
import yaml, os, sys, fcntl, time
lock_fd = open(os.environ['LOCK_PATH'], 'w')
deadline = time.time() + 30
while True:
    try:
        fcntl.flock(lock_fd.fileno(), fcntl.LOCK_SH | fcntl.LOCK_NB); break
    except OSError:
        if time.time() > deadline: sys.exit(4)
        time.sleep(0.1)

import yaml, os, sys
data = yaml.safe_load(open('$QUEUE'))
for m in data.get('missions', []):
    mf = m.get('mission_file')
    if mf:
        print(os.path.dirname(os.path.dirname(mf)))
        sys.exit(0)
print('docs/handoff/' + data['campaign'])
")

mkdir -p "$HANDOFF_DIR"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H-%M-%SZ")
SESSION_TAG="${LEADV2_SESSION_ID:-${LEADV2_TASK_ID:-shell-$$}}"
RESUME_PATH="${HANDOFF_DIR}/SESSION-RESUME-${TIMESTAMP}-${SESSION_TAG}.md"

GIT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
GIT_AHEAD=$(git rev-list --count "@{u}.." 2>/dev/null || echo "?")
RECENT_LOG=$(git log --oneline -10 2>/dev/null || echo "")
DIRTY_MOD=$(git status --porcelain 2>/dev/null | { grep -c '^ M' || true; })
DIRTY_UNTRACKED=$(git status --porcelain 2>/dev/null | { grep -c '^??' || true; })
[[ -z "$DIRTY_MOD" ]] && DIRTY_MOD=0
[[ -z "$DIRTY_UNTRACKED" ]] && DIRTY_UNTRACKED=0

export RESUME_PATH GIT_BRANCH GIT_AHEAD DIRTY_MOD DIRTY_UNTRACKED RECENT_LOG TIMESTAMP QUEUE

python3 <<'PY' > "$RESUME_PATH"
import yaml, os
data = yaml.safe_load(open(os.environ["QUEUE"]))

print(f"# Session Resume — {os.environ['TIMESTAMP']} UTC")
print()
print(f"**Campaign:** `{data['campaign']}` — {data.get('description','')}")
print(f"**Started:** {data.get('started','?')}")
print(f"**Pytest at last checkpoint:** {data.get('pytest_at_checkpoint','unknown')}")
print(f"**Branch:** {os.environ['GIT_BRANCH']} ({os.environ['GIT_AHEAD']} commits ahead)")
print(f"**Working tree:** {os.environ['DIRTY_MOD']} modified, {os.environ['DIRTY_UNTRACKED']} untracked")
print()
print("---")
print()
print("## Resume in fresh /leadv2 session — paste this")
print()
print("> Read `docs/leadv2/CAMPAIGN_RESUME.md`. Skip standard /leadv2 PO/BOARD/RECOVERY")
print("> reads — campaign mode only. Read the campaign queue file and the latest")
print(f"> SESSION-RESUME at `{os.environ['RESUME_PATH']}`. Run")
print("> `bash .claude/scripts/leadv2-next-mission.sh --claim` to claim and dispatch the next mission.")
print()
print("---")
print()
print("## Mission status")
print()
print("| ID | Status | Review | Claim |")
print("|---|---|---|---|")
for m in data.get("missions", []):
    print(f"| {m['id']} | {m.get('status','?')} | {m.get('review_status','-')} | {m.get('claimed_by','-')} |")
print()

done = {m["id"] for m in data.get("missions", []) if m.get("status") == "completed"}
nextm = next((m for m in data.get("missions", [])
              if m.get("status") == "pending"
              and all(d in done for d in (m.get("depends_on") or []))), None)
if nextm:
    print(f"## Next pending: `{nextm['id']}`")
    print()
    print(f"- Mission file: {nextm.get('mission_file') or 'NOT YET WRITTEN'}")
    print(f"- Notes: {nextm.get('notes','')}")
else:
    inp = [m for m in data.get("missions", []) if m.get("status") == "in_progress"]
    if inp:
        print("## In-progress")
        print()
        for m in inp:
            print(f"- `{m['id']}` claimed_by={m.get('claimed_by','-')} pid={m.get('claim_pid','-')}")
    else:
        print("## All missions completed")
print()

print("## Outstanding Codex findings")
print()
shown = False
for m in data.get("missions", []):
    if m.get("review_status") == "needs_attention":
        print(f"- `{m['id']}` → {m.get('review_findings') or '(no file)'}")
        shown = True
if not shown:
    print("(none)")
print()
print("## Recent commits")
print()
print("```")
print(os.environ["RECENT_LOG"])
print("```")
PY

LOCK_PATH="$LOCK_PATH" python3 <<'PY'
import yaml, os, datetime, tempfile, fcntl, time, sys
from pathlib import Path

lock_fd = open(os.environ["LOCK_PATH"], "w")
deadline = time.time() + 30
while True:
    try:
        fcntl.flock(lock_fd.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB); break
    except OSError:
        if time.time() > deadline: sys.exit(4)
        time.sleep(0.1)

p = Path(os.environ["QUEUE"])
data = yaml.safe_load(p.read_text())
data["checkpoint_at"] = datetime.datetime.now(datetime.timezone(datetime.timedelta(hours=2))).strftime("%Y-%m-%dT%H:%M+02:00")
fd, tmp = tempfile.mkstemp(dir=p.parent, prefix=".queue.", suffix=".tmp")
with os.fdopen(fd, "w") as f:
    yaml.safe_dump(data, f, sort_keys=False, default_flow_style=False, allow_unicode=True)
os.replace(tmp, p)
PY

if [[ "$PRINT_PATH" == "true" ]]; then
    echo "$RESUME_PATH"
fi
