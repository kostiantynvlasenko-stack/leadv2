#!/usr/bin/env bash
# leadv2-shared-script-warn.sh — PreToolUse:Edit|Write|MultiEdit warn-only hook.
#
# PLUGIN-DISTRIBUTION-SILENT-EDIT-HAZARD-01 (2026-07-28): Stage 3 converted
# ~170-215 vendored .claude/scripts/*.sh|py|mjs per repo into PER-FILE
# SYMLINKS pointing at the single canonical tree
# (~/Projects/leadv2/plugins/leadv2/scripts/<name>), identical across
# persona-engine, m3-market, and respiro-ios (live-verified by marker-append/
# revert test, see persona-engine docs/handoff/supervisor-scope/
# plugin-propagation-process.md). Editing "this repo's copy" of one of these
# files now silently rewrites the one real file that all three repos run --
# with ZERO warning anywhere: leadv2-lead-edit-guard.sh:68 explicitly
# EXEMPTS `.claude/scripts/leadv2-*.sh` from its own warning (an exemption
# written when these were per-repo copies -- now exactly backwards), and
# leadv2-plugin-sync-drift-warn.sh only fires after a Bash command that
# invokes leadv2-plugin-sync.sh itself, never on an ordinary Edit/Write.
#
# This hook closes that gap. It is UNCONDITIONAL (no LEADV2_LEAD_GUARD gate --
# that guard is lead-only and opt-in; this risk applies to every editor,
# lead or subagent) and WARN-ONLY (continueOnBlock: true in hooks.json,
# and this script itself always exits 0). It never blocks: the founder
# edits these files deliberately and often, and blocking would make
# ordinary plugin work painful. It only fires when the edited path is
# ACTUALLY a symlink resolving outside the repo it's edited from --
# a repo-native (real, non-symlinked) file in the same directory stays
# silent.
#
# Consumer-repo list comes from cross-repo-paths.yaml (the same file
# leadv2-crossrepo-aggregate.sh treats as authoritative) so this stays
# correct if a repo is added or removed later, rather than hardcoding names
# that would drift.

set -euo pipefail
trap 'exit 0' ERR

INPUT="$(cat 2>/dev/null || true)"
[[ -z "$INPUT" ]] && exit 0

FILE_PATH="$(printf '%s' "$INPUT" | python3 -c "
import sys, json
try:
    r = json.loads(sys.stdin.read())
    print(r.get('tool_input', {}).get('file_path', ''))
except Exception:
    pass
" 2>/dev/null || true)"

[[ -z "$FILE_PATH" ]] && exit 0

# Only care about files under a repo's .claude/scripts/ tree -- that's the
# only directory Stage 3 converted to per-file symlinks.
case "$FILE_PATH" in
  */.claude/scripts/*) ;;
  *) exit 0 ;;
esac

# Not a symlink at all (repo-native file, or new file about to be created) --
# nothing shared, stay silent.
[[ -L "$FILE_PATH" ]] || exit 0

REAL_TARGET="$(readlink -f "$FILE_PATH" 2>/dev/null || true)"
[[ -z "$REAL_TARGET" ]] && exit 0

# Determine the repo root the edited path lives in. If the symlink resolves
# to somewhere INSIDE that same repo, it's a local convenience link, not a
# cross-repo fan-out -- stay silent.
FILE_DIR="$(dirname "$FILE_PATH")"
REPO_ROOT="$(git -C "$FILE_DIR" rev-parse --show-toplevel 2>/dev/null || true)"

if [[ -n "$REPO_ROOT" ]] && [[ "$REAL_TARGET" == "$REPO_ROOT"/* ]]; then
  exit 0
fi

CROSS_REPO_YAML="${HOME}/.claude/leadv2-shared/cross-repo-paths.yaml"
CONSUMERS=""
if [[ -f "$CROSS_REPO_YAML" ]]; then
  CONSUMERS="$(python3 -c "
import re
names = []
with open('$CROSS_REPO_YAML') as f:
    for line in f:
        m = re.match(r'^  ([a-zA-Z0-9_-]+):\s*\$', line)
        if m:
            names.append(m.group(1))
print(', '.join(names))
" 2>/dev/null || true)"
fi
[[ -z "$CONSUMERS" ]] && CONSUMERS="persona-engine, m3-market, respiro-ios"

printf -- '[leadv2-shared-script-warn] WARNING: %s is a symlink shared across all consuming repos (%s) — it resolves to %s. Editing it here changes what EVERY one of them runs, not just this repo. This is expected for deliberate plugin edits; if that is not your intent, check `ls -l %s` before proceeding.\n' \
  "$FILE_PATH" "$CONSUMERS" "$REAL_TARGET" "$FILE_PATH" >&2

exit 0
