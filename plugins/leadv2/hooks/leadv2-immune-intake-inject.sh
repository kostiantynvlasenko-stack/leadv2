#!/usr/bin/env bash
# leadv2-immune-intake-inject.sh
# PreToolUse hook on Write to docs/handoff/*/intake.md
# Reads the file content from stdin JSON, runs immune lookup (keyword +
# optional semantic fusion) on the summary/title, and emits
# hookSpecificOutput.additionalContext for any qualifying match.
#
# MEM-SEMANTIC-RECALL-01 fix round (C1): this is the ONLY real caller of
# leadv2-immune-lookup.sh. Canonicalized into the shared plugin `hooks/` tree
# and registered in hooks/hooks.json (PreToolUse Write matcher) so Claude
# Code's plugin-hook dispatcher actually invokes it — the prior copy living
# only in a target repo's `.claude/hooks/` was never wired into that repo's
# own `.claude/settings.json`, so it never fired in production.
#
# Durable-root fix (C1): REPO_ROOT no longer derived from this script's own
# BASH_SOURCE location (wrong once the script is loaded via the plugin's
# ${CLAUDE_PLUGIN_ROOT} mechanism — BASH_SOURCE then points into the PLUGIN
# install dir, not the target repo). Resolved instead from the invoking
# repo's git-common-dir (durable across worktrees; never --show-toplevel,
# which returns the ephemeral worktree — see project CLAUDE.md T1 incident).
#
# Claude Code hook protocol:
#   stdin: JSON { tool_name, tool_input: { file_path, content } }
#   stdout: JSON with hookSpecificOutput.additionalContext (optional)
#   exit 0: always non-blocking
set -euo pipefail
trap 'echo "[$(basename "$0")] err line $LINENO" >&2; exit 0' ERR

REPO_ROOT="${LEADV2_PROJECT_ROOT:-$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null | xargs dirname 2>/dev/null || pwd)}"

# Prefer the canonical plugin-source script (no rsync staleness); fall back
# to the per-repo synced copy for environments without CLAUDE_PLUGIN_ROOT set.
if [[ -n "${CLAUDE_PLUGIN_ROOT:-}" && -f "${CLAUDE_PLUGIN_ROOT}/scripts/leadv2-immune-lookup.sh" ]]; then
    LOOKUP_SCRIPT="${CLAUDE_PLUGIN_ROOT}/scripts/leadv2-immune-lookup.sh"
else
    LOOKUP_SCRIPT="$REPO_ROOT/.claude/scripts/leadv2-immune-lookup.sh"
fi
PATTERNS_FILE="$REPO_ROOT/docs/leadv2/immune-patterns.yaml"

# Read stdin JSON; guard against missing python3/yaml
INPUT="$(cat)"

# Extract file_path to check if this is an intake.md write
FILE_PATH="$(printf -- '%s' "$INPUT" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('tool_input', {}).get('file_path', ''))
" 2>/dev/null || true)"

# Only activate for intake.md writes
if [[ "$FILE_PATH" != */intake.md ]]; then
    exit 0
fi

# Skip if no patterns file yet, or lookup script missing
if [[ ! -f "$PATTERNS_FILE" || ! -f "$LOOKUP_SCRIPT" ]]; then
    exit 0
fi

# Extract first 500 chars of content as intent
INTENT="$(printf -- '%s' "$INPUT" | python3 -c "
import sys, json
d = json.load(sys.stdin)
content = d.get('tool_input', {}).get('content', '')
import re
m = re.search(r'(?:summary|title|task)[:\s]+(.+)', content, re.IGNORECASE)
text = m.group(1) if m else content[:300]
print(text[:500].strip())
" 2>/dev/null || true)"

if [[ -z "$INTENT" ]]; then
    exit 0
fi

# Run lookup (keyword + optional semantic fusion, gated inside leadv2-immune-lookup.sh)
MATCHES="$(bash "$LOOKUP_SCRIPT" "$INTENT" 2>/dev/null || true)"

# MEM-SEMANTIC-RECALL-01 fix round (C2): the prior gate compared a single
# `score > 0.4` across two incompatible scales — raw keyword jaccard+boost
# (real-world matches observed at ~0.09-0.36, i.e. ALWAYS below 0.4) and the
# RRF-fused/semantic-only case (score hardcoded to 0.0 for anything promoted
# purely by the semantic path). Both real signal types were being discarded.
# Reconciled: each match already cleared its OWN internal floor before
# reaching this list (kw score>0 to rank in the keyword pass, or
# sem_cosine>=tau_sem(0.35) to rank in the semantic pass — see
# leadv2-immune-lookup.sh). The gate here just checks EITHER floor directly,
# on its own native scale, instead of one arbitrary cross-scale number.
HAS_MATCH="$(printf -- '%s' "$MATCHES" | python3 -c "
import sys, yaml
data = yaml.safe_load(sys.stdin) or {}
matches = data.get('matches') or []
high = [m for m in matches if m.get('score', 0) > 0 or m.get('sem_cosine', 0) >= 0.35]
print('1' if high else '0')
" 2>/dev/null || printf -- '0')"

if [[ "$HAS_MATCH" != "1" ]]; then
    exit 0
fi

# Build additionalContext from qualifying matches
CONTEXT="$(printf -- '%s' "$MATCHES" | python3 -c "
import sys, yaml
data = yaml.safe_load(sys.stdin) or {}
matches = [m for m in (data.get('matches') or []) if m.get('score', 0) > 0 or m.get('sem_cosine', 0) >= 0.35]
lines = ['[immune-patterns] Relevant past failure patterns for this task:']
for m in matches:
    sem = m.get('sem_cosine', 0) or 0
    tag = f\" (semantic cosine={sem:.2f})\" if sem >= 0.35 and not m.get('score') else ''
    lines.append(f\"  - [{m['id']} score={m['score']}{tag}] {m['summary']}\")
    lines.append(f\"    action: {m['action']}\")
print('\n'.join(lines))
" 2>/dev/null || true)"

if [[ -z "$CONTEXT" ]]; then
    exit 0
fi

# Emit hookSpecificOutput per Claude Code hook protocol
python3 -c "
import json, sys
ctx = sys.argv[1]
out = {'hookSpecificOutput': {'hookEventName': 'PreToolUse', 'additionalContext': ctx}}
print(json.dumps(out))
" "$CONTEXT"
