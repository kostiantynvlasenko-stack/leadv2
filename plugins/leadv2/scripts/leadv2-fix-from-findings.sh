#!/usr/bin/env bash
# Generate a *-FIX mission file from a Codex findings file.
#
# Usage: leadv2-fix-from-findings.sh <findings-path> <mission-slug>
#   findings-path  e.g. docs/handoff/improvements-2026-04-26/codex-review-F-COST-findings.md
#   mission-slug   e.g. F-COST-FIX
#
# Output: writes docs/handoff/.../missions/mission-<mission-slug>.md and prints its path.

set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "Usage: $0 <findings-path> <mission-slug>" >&2
    exit 2
fi

FINDINGS_PATH="$1"
MISSION_SLUG="$2"

if [[ ! -f "$FINDINGS_PATH" ]]; then
    echo "ERROR: findings file not found: $FINDINGS_PATH" >&2
    exit 1
fi

# Derive mission file path from findings dir
FINDINGS_DIR=$(dirname "$FINDINGS_PATH")
MISSION_DIR="${FINDINGS_DIR}/missions"
mkdir -p "$MISSION_DIR"
MISSION_PATH="${MISSION_DIR}/mission-${MISSION_SLUG}.md"

# Extract base mission name (strip -FIX suffix)
BASE_NAME="${MISSION_SLUG%-FIX}"

# Extract the findings list and scope from the findings file
# (assumes structure: ## K<N>, ## H<N>, ## Mission scope)

cat > "$MISSION_PATH" <<HEADER
# Mission ${MISSION_SLUG}: Address Codex ${BASE_NAME} review findings

You are the \`developer\` agent. Codebase graph project: \`${LEADV2_CODEBASE_PROJECT}\`.

## Goal

Fix all Critical + High findings from the Codex review of ${BASE_NAME}. Full findings: \`${FINDINGS_PATH}\`. Read first.

## Required reading

1. \`docs/leadv2/subagent-preamble.md\` — boilerplate (permissions, off-limits, deliverable format).
2. \`${FINDINGS_PATH}\` — finding-by-finding narrative + line refs.

## Findings to address

HEADER

# Append findings titles from the findings file
# Match lines like "## K1 — Title" or "## H2 — Title"
awk '/^## (K|H)[0-9]/ {
    sub(/^## /, "")
    print "- **" $0 "**"
}' "$FINDINGS_PATH" >> "$MISSION_PATH"

# Append scope and verification template
cat >> "$MISSION_PATH" <<TAIL

## What to ship

See per-finding "**Fix:**" lines in the findings file. Each finding maps to a code change. Translate them faithfully — do NOT invent additional scope.

## Tests

For every finding, add at least one regression test asserting the fix path. The findings file's "Required regression tests" section enumerates the expected tests; implement all of them.

## Verify

\`pytest tests/leadv2/ -q --tb=line\` must stay green. \`bash .claude/scripts/leadv2-preflight.sh\` must remain 169/0.

## Off-limits

Authoritative list lives in the findings file's "## Mission scope" section. Honor it strictly. In addition to that list, follow §2 of \`docs/leadv2/subagent-preamble.md\`.

## Deliverable

Per \`docs/leadv2/subagent-preamble.md\` §7. End with \`DELIVERABLE_COMPLETE\`.

## Skills

bash-scripting, error-handling, systematic-debugging, leadv2-subagent-protocol.
TAIL

echo "$MISSION_PATH"
