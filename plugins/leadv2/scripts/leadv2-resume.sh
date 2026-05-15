#!/usr/bin/env bash
# leadv2-resume.sh <task-id>
# Multi-source status snapshot for a paused task. Reads STATE.md, shows prior notes,
# checks git status for the current branch.
set -euo pipefail

[[ $# -lt 1 ]] && { echo "usage: $(basename "$0") <task-id>" >&2; exit 64; }
TASK_ID="$1"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Task state convention: docs/leadv2/tasks/<id>/STATE.md
TASK_DIR="$PROJECT_ROOT/docs/leadv2/tasks/$TASK_ID"
STATE_FILE="$TASK_DIR/STATE.md"
# ACTIVE_FILE kept for reference — uses docs/leadv2/active.yaml
# shellcheck disable=SC2034
ACTIVE_FILE="$PROJECT_ROOT/docs/leadv2/active.yaml"

[[ -f "$STATE_FILE" ]] || { echo "ERR: no STATE for $TASK_ID at $STATE_FILE" >&2; exit 65; }

NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
LAST_SEEN="$(grep -E '^- last_seen_at:' "$STATE_FILE" | head -1 | sed 's/.*: //' | tr -d ' ')"
PHASE="$(grep -E '^- phase:' "$STATE_FILE" | head -1 | sed 's/.*: //' | tr -d ' ')"

echo "=== $TASK_ID ==="
echo "phase:     $PHASE"
echo "last_seen: $LAST_SEEN"

# Show title
TITLE="$(grep -E '^- title:' "$STATE_FILE" | head -1 | sed 's/^- title: //' | tr -d '\r')"
[[ -n "$TITLE" ]] && echo "title:     $TITLE"

# Show last 5 History notes (prior session context)
NOTES="$(awk '/^## History notes/{found=1; next} found && /^## /{exit} found && /^- /{print}' "$STATE_FILE" | tail -5)"
if [[ -n "$NOTES" ]]; then
  echo ""
  echo "--- Prior session notes ---"
  echo "$NOTES"
fi
echo ""

# === git status for current repo ===
echo "--- Git status ---"
BR="$(git -C "$PROJECT_ROOT" branch --show-current 2>/dev/null || echo '')"
DIRTY="$(git -C "$PROJECT_ROOT" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
printf "  %-18s branch=%s dirty=%s\n" "project:" "${BR:-?}" "$DIRTY"

# === PR status (gh if available) ===
PR_MANIFEST="$TASK_DIR/pr-manifest.yaml"
if [[ -f "$PR_MANIFEST" ]] && command -v gh >/dev/null 2>&1; then
  echo ""
  echo "--- PRs ---"
  # shellcheck disable=SC2034
  python3 - "$PR_MANIFEST" <<'PY' 2>/dev/null | while IFS=$'\t' read -r num url; do
import yaml, sys
d = yaml.safe_load(open(sys.argv[1])) or {}
for pr in d.get('prs') or []:
    num  = pr.get('pr_number') or ''
    url  = pr.get('pr_url') or ''
    if url and num:
        print(f'{num}\t{url}')
PY
    printf "  PR #%s: " "$num"
    gh pr checks "$num" --json bucket --jq 'group_by(.bucket)|map({bucket:.[0].bucket,n:length})|map("\(.bucket)=\(.n)")|join(", ")' 2>/dev/null || echo "(unavailable)"
  done
else
  echo "(no PR manifest or gh not installed)"
fi

# Update last_seen in STATE.md
sed -i.bak "s/^- last_seen_at:.*/- last_seen_at: $NOW/" "$STATE_FILE" && rm -f "${STATE_FILE}.bak"

echo ""
echo "--- Ready ---"
echo "To log a session note: leadv2-session-note.sh $TASK_ID \"<note>\""
