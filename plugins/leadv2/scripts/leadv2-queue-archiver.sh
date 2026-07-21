#!/usr/bin/env bash
# leadv2-queue-archiver.sh — Standalone script (called from SessionStart hook).
# Now delegates to leadv2-tasks-lib.sh for YAML-based archiving of tasks.yaml.
# Legacy QUEUE.md archiving code preserved as dead code below.
#
# Lock: docs/leadv2/.archiver-last-run — skips if already ran today.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/leadv2-temp.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${PROJECT_ROOT:-$(cd "${SCRIPT_DIR}/../../" && pwd)}"

# Source tasks lib
# shellcheck source=leadv2-tasks-lib.sh
source "${SCRIPT_DIR}/leadv2-tasks-lib.sh"

LOCKFILE="${PROJECT_ROOT}/docs/leadv2/.archiver-last-run"

TODAY=$(date +%Y-%m-%d)

# Already ran today?
if [[ -f "$LOCKFILE" ]]; then
  last_run=$(cat "$LOCKFILE" 2>/dev/null || true)
  if [[ "$last_run" == "$TODAY" ]]; then
    exit 0
  fi
fi

# Delegate to tasks lib (archives entries with closed_at > 30 days old)
if [[ -f "${PROJECT_ROOT}/docs/tasks.yaml" ]]; then
  leadv2_tasks_archive --older-than-days 30
fi

printf -- '%s\n' "$TODAY" > "$LOCKFILE"
exit 0

# ── DEAD CODE: legacy QUEUE.md archiver — superseded by tasks.yaml lib call
if false; then
QUEUE_FILE="${PROJECT_ROOT}/docs/agents/product-owner/QUEUE.md"
ARCHIVE_DIR="${PROJECT_ROOT}/docs/agents/product-owner/queue/_archive"

[[ -f "$QUEUE_FILE" ]] || exit 0

# Cutoff: 30 days ago (macOS vs Linux)
if date -v -30d +%Y-%m-%d >/dev/null 2>&1; then
  CUTOFF=$(date -v -30d +%Y-%m-%d)
else
  CUTOFF=$(date -d '30 days ago' +%Y-%m-%d)
fi

# Build list of open [ ] task IDs to check for dep references
open_ids=()
while IFS= read -r line; do
  tid=$(grep -oE '\bPO-[A-Za-z0-9-]+\b' <<< "$line" | head -1 || true)
  [[ -n "$tid" ]] && open_ids+=("$tid")
done < <(grep -E '^\s*-\s*\[ \]\s+\*\*PO-' "$QUEUE_FILE" 2>/dev/null || true)

# Find candidate [x] lines with filed: YYYY-MM-DD where date < CUTOFF
candidates=()
candidate_lines=()

while IFS= read -r line; do
  tid=$(grep -oE '\bPO-[A-Za-z0-9-]+\b' <<< "$line" | head -1 || true)
  [[ -z "$tid" ]] && continue

  # Extract filed: date, or fall back to ✅ YYYY-MM-DD close marker
  filed=$(grep -oE 'filed:\s*[0-9]{4}-[0-9]{2}-[0-9]{2}' <<< "$line" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -1 || true)
  if [[ -z "$filed" ]]; then
    filed=$(grep -oE '✅\s*[0-9]{4}-[0-9]{2}-[0-9]{2}' <<< "$line" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -1 || true)
  fi
  [[ -z "$filed" ]] && continue

  # Only if filed date < cutoff
  [[ "$filed" < "$CUTOFF" ]] || continue

  # Check if referenced by any open [ ] item as a dep (Deps: or Depends:)
  dep_found=0
  for open_id in "${open_ids[@]:-}"; do
    [[ -z "$open_id" ]] && continue
    if grep -E "^\s*-\s*\[ \].*${open_id}.*[Dd]ep(s|ends)?:[^)]*\b${tid}\b" "$QUEUE_FILE" >/dev/null 2>&1; then
      dep_found=1
      break
    fi
    # Also check inline deps like "Deps: PO-200" anywhere in open item line
    if grep -E "^\s*-\s*\[ \].*\*\*${open_id}\*\*.*[Dd]ep(s|ends)?:.*\b${tid}\b" "$QUEUE_FILE" >/dev/null 2>&1; then
      dep_found=1
      break
    fi
  done

  [[ $dep_found -eq 1 ]] && continue

  candidates+=("$tid")
  candidate_lines+=("$line")
done < <(grep -E '^\s*-\s*\[x\]\s+\*\*PO-' "$QUEUE_FILE" 2>/dev/null || true)

if (( ${#candidates[@]} == 0 )); then
  printf -- '%s\n' "$TODAY" > "$LOCKFILE"
  exit 0
fi

# Archive file: monthly
ARCHIVE_MONTH=$(date +%Y-%m)
ARCHIVE_FILE="${ARCHIVE_DIR}/QUEUE-archive-${ARCHIVE_MONTH}.md"
mkdir -p "$ARCHIVE_DIR"

{
  printf -- '# Archived Queue Items — %s\n' "$ARCHIVE_MONTH"
  printf -- '# Auto-archived on %s (filed > 30 days ago, no open deps)\n' "$TODAY"
  printf -- '\n'
  for line in "${candidate_lines[@]}"; do
    printf -- '%s\n' "$line"
  done
} >> "$ARCHIVE_FILE"

# Remove archived lines from QUEUE.md (temp-file rewrite)
TMPFILE=$(lv2_mktemp_file "queue-archiver" "md")
trap 'rm -f "$TMPFILE"' EXIT

while IFS= read -r line; do
  skip=0
  for cline in "${candidate_lines[@]}"; do
    if [[ "$line" == "$cline" ]]; then
      skip=1
      break
    fi
  done
  [[ $skip -eq 0 ]] && printf -- '%s\n' "$line"
done < "$QUEUE_FILE" > "$TMPFILE"

mv "$TMPFILE" "$QUEUE_FILE"

printf -- '%s\n' "$TODAY" > "$LOCKFILE"
printf -- 'Archived %d item(s) to %s\n' "${#candidates[@]}" "$ARCHIVE_FILE"
fi
# end DEAD CODE legacy archiver
