#!/usr/bin/env bash
# leadv2-tell.sh — VOICE writer (S4a of task 1b07a6fd0490).
#
# Usage: leadv2-tell.sh <task_id> "<message>"
#
# Drops a message into docs/handoff/<task_id>/inbox/ for a LIVE child session
# to pick up. The reader is the PostToolUse hook leadv2-pulse-json.sh (S4b/c):
# on every tool-call boundary it scans inbox/, surfaces pending messages back
# into the child via hookSpecificOutput.additionalContext, and atomically acks
# (renames to inbox/done/) so each message is delivered exactly once.
#
# This is the NO-send-keys input channel. `tmux send-keys` does not submit
# (verified live 4 ways); VOICE replaces it with a file the child reads itself.
#
# HONEST LIMIT (S4d — do not paper over): VOICE reaches LIVE children ONLY.
# The reader fires on PostToolUse, i.e. AFTER a tool call completes. A WEDGED
# child (kill -STOP, or stuck mid-tool-call) fires no PostToolUse, polls no
# inbox, and will not see the message until it resumes. This channel is a
# heartbeat-driven poll, NOT an interrupt. State this in any deliverable.
#
# FAIL-LOUD (NOT fail-open): this is a CLI tool invoked by the lead, NOT a hook.
# A silent no-op here is the exact defect this task exists to kill. Bad input
# (missing args, unknown task_id, absent handoff dir) MUST exit non-zero with a
# clear message so the lead knows the message did not land.
#
# Atomic write (tmp+mv in the target dir) so the reader never sees a half file.
# Constraints: bash + macOS BSD only (no GNU date/stat). No daemon.

set -uo pipefail

_usage() { echo "Usage: $0 <task_id> \"<message>\"" >&2; }

_err() { echo "[leadv2-tell.sh] ERROR: $*" >&2; }

# ── Args ───────────────────────────────────────────────────────────────────
if [[ $# -lt 2 ]]; then
  _err "need <task_id> and a <message>; got $# arg(s)."
  _usage
  exit 2
fi
tid="$1"
msg="$2"

if [[ -z "$tid" ]]; then
  _err "task_id is empty."
  _usage
  exit 2
fi
if [[ -z "$msg" ]]; then
  _err "message is empty (nothing to tell)."
  _usage
  exit 2
fi
# task_id is a hex string per leadv2 convention (8+ hex chars) or the literal
# sentinel "_unknown". Reject obviously malformed ids early with a clear error.
if [[ ! "$tid" =~ ^[0-9a-f]{8,}$ && "$tid" != "_unknown" ]]; then
  _err "task_id '$tid' is not a hex id (expected ^[0-9a-f]{8,}\$ or _unknown)."
  exit 2
fi

# ── Resolve project root (walk up for docs/handoff) ────────────────────────
PROJ_ROOT="${CLAUDE_PROJECT_DIR:-$PWD}"
if [[ ! -d "$PROJ_ROOT/docs/handoff" ]]; then
  _d="$PWD"; _i=0
  while [[ "$_i" -lt 8 && "$_d" != "/" ]]; do
    if [[ -d "$_d/docs/handoff" ]]; then PROJ_ROOT="$_d"; break; fi
    _d="$(dirname "$_d")"; _i=$((_i + 1))
  done
fi
if [[ ! -d "$PROJ_ROOT/docs/handoff" ]]; then
  _err "no docs/handoff/ under $PWD (or any ancestor up to 8 levels). Cannot deliver."
  exit 3
fi

# ── Validate the task handoff dir exists ───────────────────────────────────
# A tell to a task with no handoff dir is almost certainly a typo. Refuse
# rather than silently mkdir an empty task tree.
handoff_dir="$PROJ_ROOT/docs/handoff/$tid"
if [[ ! -d "$handoff_dir" ]]; then
  _err "unknown task_id: no handoff dir at docs/handoff/$tid/. Known tasks:"
  ls -1 "$PROJ_ROOT/docs/handoff/" 2>/dev/null | head -20 >&2 || true
  exit 4
fi

# ── Create inbox/ lazily ───────────────────────────────────────────────────
inbox_dir="$handoff_dir/inbox"
if ! mkdir -p "$inbox_dir" 2>/dev/null; then
  _err "mkdir -p $inbox_dir failed (permissions?)."
  exit 5
fi

# ── Compose filename: <utc-ts>-<rand>.md ───────────────────────────────────
# Compact UTC stamp (sortable, second-resolution) + pid+random for uniqueness
# even when two tells land in the same second. .md so the child surfaces it as
# text (the hook reads raw bytes; extension is for humans and `ls` sorting).
_ts_compact="$(date -u +%Y%m%dT%H%M%SZ)"
_rand="$(printf '%05d-%05d' "$$" "$RANDOM")"
fname="${_ts_compact}-${_rand}.md"

# ── Atomic write (tmp in SAME dir + mv) ────────────────────────────────────
# tmp shares the inbox/ filesystem so mv is atomic on APFS. Two concurrent
# writers pick distinct names (pid+random), so they never collide on the tmp
# file; the rename is the linearization point for the reader.
_tmp="${inbox_dir}/.${fname}.tmp.$$"

# Message body: minimal markdown header + the raw message. The hook surfaces
# the whole file as additionalContext, so keep it model-readable. The ts line
# lets the child see freshness; the task_id line disambiguates in multi-task
# trees (inbox/done/ is shared across all messages for one task).
{
  printf '# leadv2-tell @ %s\n\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'task_id: %s\n\n' "$tid"
  printf '%s\n' "$msg"
} > "$_tmp" || { _err "write $_tmp failed."; rm -f "$_tmp" 2>/dev/null; exit 6; }

if ! mv -f "$_tmp" "${inbox_dir}/${fname}" 2>/dev/null; then
  _err "mv $_tmp -> ${inbox_dir}/${fname} failed."
  rm -f "$_tmp" 2>/dev/null
  exit 7
fi

# ── Success ────────────────────────────────────────────────────────────────
# Print the path so the lead can reference it. Stdout only on success.
echo "${inbox_dir}/${fname}"
exit 0
