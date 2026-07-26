#!/usr/bin/env bash
# leadv2-pulse-json.sh — PostToolUse heartbeat writer (EYES, S1 of task 1b07a6fd0490).
#
# Fires on EVERY tool call (registered on the free PostToolUse '.*' matcher in
# .claude/settings.json — G4: that slot had 0 hooks today). Writes
# docs/handoff/<task_id>/pulse.json atomically (tmp+mv) so the supervisor
# (leadv2-supervise.sh, S2 verdict) can compute busy-vs-wedged from a real
# per-tool-call artifact instead of the inert `stale` column that has NO
# writer anywhere in the live tree (G3 — `stale` is false forever, so every
# registered session renders "active" unconditionally).
#
# HARD REQUIREMENTS (context.yaml D3 + plan.S1):
#   - fail-open:  ALWAYS exit 0. A hook that errors on every tool call degrades
#                 every leadv2 session. Errors go to stderr only.
#   - fast:       <50ms budget — runs on every tool call. Pure bash + one date
#                 call; NO python3 in the hot path. Stdin JSON parsed with
#                 bash regex (~10ms cold, ~5ms warm on macOS).
#   - atomic:     tmp file in the SAME directory as the target + mv, so a
#                 concurrent supervisor read never sees a half-written file.
#
# task_id RESOLUTION (subagents do NOT inherit LEADV2_TASK_ID from the parent
# lead session — Claude Code does not propagate it across the subagent fork):
#   1. $LEADV2_TASK_ID         — explicit, set by the top-level lead session.
#   2. $LEADV2_PULSE_TASK_ID   — opt-in override for hooks/subagents.
#   3. CWD match docs/handoff/<tid>/  — a subagent cd'd into a task worktree.
#   4. docs/leadv2/active.yaml — LAST RESORT: first session's task_id. May be
#                                WRONG in multi-task setups (the registry is
#                                ordered by registration, not by "this
#                                process"). Tolerable because the supervisor
#                                also reads pid and will flag the mismatch.
#   5. none of the above       — write docs/handoff/_unknown/pulse.json so the
#                                artifact exists and the supervisor can SURFACE
#                                the misconfiguration. NEVER silently no-op
#                                (the whole point of EYES is a real artifact).
#
# Written 2026-07-26, lane 1b07a6fd0490. Constraints: bash + macOS BSD only.

# ── fail-open discipline ───────────────────────────────────────────────────
# No `set -e` (a failing grep would kill the hook). No ERR trap. Every error
# path calls `_bail` which exits 0. The EXIT trap is a belt-and-suspenders
# guarantee that even an unexpected death returns 0 to the hook caller.
set -uo pipefail
_bail() { echo "[leadv2-pulse-json.sh] $*" >&2; exit 0; }
trap 'exit 0' EXIT HUP TERM INT

# ── Resolve project root (walk up for docs/handoff) ────────────────────────
PROJ_ROOT="${CLAUDE_PROJECT_DIR:-$PWD}"
if [[ ! -d "$PROJ_ROOT/docs/handoff" ]]; then
  _d="$PWD"
  _i=0
  while [[ "$_i" -lt 8 && "$_d" != "/" ]]; do
    if [[ -d "$_d/docs/handoff" ]]; then PROJ_ROOT="$_d"; break; fi
    _d="$(dirname "$_d")"; _i=$((_i + 1))
  done
fi
[[ -d "$PROJ_ROOT/docs/handoff" ]] || _bail "no docs/handoff under $PWD; nothing to write"

# ── Read PostToolUse stdin payload once ────────────────────────────────────
# Shape (Claude Code): {"tool_name":"Bash","session_id":"...","transcript_path":"...","tool_input":{...},...}
_STDIN=""
if [[ ! -t 0 ]]; then
  # head -c caps the read so a malformed huge stdin can't blow the budget.
  _STDIN="$(head -c 8192 2>/dev/null || true)"
fi

_tool="Unknown"
if [[ "$_STDIN" =~ \"tool_name\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]]; then
  _tool="${BASH_REMATCH[1]}"
fi
_sid=""
if [[ "$_STDIN" =~ \"session_id\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]]; then
  _sid="${BASH_REMATCH[1]}"
fi
_tpath=""
if [[ "$_STDIN" =~ \"transcript_path\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]]; then
  _tpath="${BASH_REMATCH[1]}"
fi
unset _STDIN

# nesting: 0 at top level (transcript under /projects/<slug>/<sid>.jsonl),
#          1 inside a subagent (/subagents/agent-<id>.jsonl).
_nesting=0
[[ "$_tpath" == *"/subagents/"* ]] && _nesting=1

# ── Resolve task_id (fallback chain — see header) ──────────────────────────
tid="${LEADV2_TASK_ID:-}"
if [[ -z "$tid" ]]; then
  tid="${LEADV2_PULSE_TASK_ID:-}"
fi
if [[ -z "$tid" ]]; then
  # CWD match: .../docs/handoff/<tid>/...
  case "$PWD" in
    */docs/handoff/*)
      _rest="${PWD#*docs/handoff/}"
      _cand="${_rest%%/*}"
      if [[ "$_cand" =~ ^[0-9a-f]{8,}$ ]]; then
        tid="$_cand"
      fi
      ;;
  esac
fi
if [[ -z "$tid" ]]; then
  # LAST RESORT: first session's task_id from active.yaml (see header caveat).
  _active="$PROJ_ROOT/docs/leadv2/active.yaml"
  if [[ -f "$_active" ]]; then
    # Match `  - task_id: <hex>` (YAML list element). Print only the value.
    tid="$(awk '/^[[:space:]]*-[[:space:]]+task_id[[:space:]]*:/{gsub(/["'"'"']/,"",$3); print $3; exit}' "$_active" 2>/dev/null || true)"
  fi
fi
if [[ -z "$tid" ]]; then
  # Documented in header: never silently no-op. The supervisor will see
  # docs/handoff/_unknown/pulse.json and flag the misconfiguration.
  tid="_unknown"
fi

# ── Build paths + compose values ───────────────────────────────────────────
pulse_dir="$PROJ_ROOT/docs/handoff/$tid"
mkdir -p "$pulse_dir" 2>/dev/null || _bail "mkdir $pulse_dir failed"
pulse="$pulse_dir/pulse.json"

_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
# $PPID = the claude process that forked this hook. The supervisor cross-
# checks this against active.yaml's pid; a mismatch is itself a signal.
_pid="${PPID:-0}"
_phase="${LEADV2_PHASE:-}"

# Defensive escape of hook-supplied strings (controlled input, but never trust).
_tool="${_tool//\\/\\\\}";  _tool="${_tool//\"/\\\"}"
_sid="${_sid//\\/\\\\}";    _sid="${_sid//\"/\\\"}"
_phase="${_phase//\\/\\\\}"; _phase="${_phase//\"/\\\"}"

# ── Atomic write (tmp in SAME dir + mv) ────────────────────────────────────
# tmp suffix includes $$ so concurrent hooks across nesting levels don't
# collide; mv is atomic on the same filesystem (APFS guarantees).
_tmp="${pulse}.tmp.$$"
printf '{"ts":"%s","pid":%s,"task_id":"%s","phase":"%s","tool":"%s","last_tool_at":"%s","nesting":%s,"session_id":"%s"}\n' \
  "$_ts" "$_pid" "$tid" "$_phase" "$_tool" "$_ts" "$_nesting" "$_sid" > "$_tmp" 2>/dev/null \
  || _bail "write $_tmp failed"
if ! mv -f "$_tmp" "$pulse" 2>/dev/null; then
  rm -f "$_tmp" 2>/dev/null || true
  _bail "mv $_tmp -> $pulse failed"
fi

# ── VOICE: surface pending inbox messages (S4b of 1b07a6fd0490) ───────────
# The child polls its OWN inbox by virtue of this hook firing on every tool
# call. Pending messages in docs/handoff/<tid>/inbox/*.md are surfaced back
# into the session as PostToolUse additionalContext. PROVEN LIVE on Claude
# Code 2.1.220: hookSpecificOutput.additionalContext is delivered as a
# <system-reminder> immediately after the tool result (the child quoted a
# dynamic pid/ts marker verbatim in the empirical test). An inbox nothing
# reads is worthless — THIS is what makes the child LOOK. `tmux send-keys`
# does not submit (verified 4 ways); this replaces it.
#
# Ack (this step, S4b): read the file THEN move to inbox/done/ so it is not
# re-surfaced. RACE WINDOW: read-then-move lets a concurrent fire (parent +
# subagent on the same inbox) read the same file before either moves it,
# double-delivering. S4c closes this with rename-first atomicity.
#
# HONEST LIMIT: a WEDGED child fires no PostToolUse and never polls — VOICE
# reaches LIVE children only. This is a heartbeat-driven poll, not an interrupt.
#
# Hot path stays fast + fail-open: empty inbox → no jq, ~0 added cost. jq is
# used ONLY when there are messages to escape (arbitrary lead-written content).
# Cap at _max_surface per fire to bound additionalContext size.
inbox_dir="$pulse_dir/inbox"
_voice_ctx=""
_n_surfaced=0
_max_surface=5

shopt -s nullglob
_inbox_files=("$inbox_dir"/*.md)
shopt -u nullglob

if [[ ${#_inbox_files[@]} -gt 0 ]]; then
  _done_dir="$inbox_dir/done"
  mkdir -p "$_done_dir" 2>/dev/null || true
  for _f in "${_inbox_files[@]}"; do
    [[ "$_n_surfaced" -ge "$_max_surface" ]] && break
    _base="$(basename "$_f")"
    # S4b: read content FIRST, then ack. (Race window here — S4c reorders.)
    _content="$(cat "$_f" 2>/dev/null || true)"
    if mv -f "$_f" "$_done_dir/$_base" 2>/dev/null; then
      _voice_ctx="${_voice_ctx}--- ${_base} ---"$'\n'"${_content}"$'\n\n'
      _n_surfaced=$((_n_surfaced + 1))
    fi
  done
fi

if [[ "$_n_surfaced" -gt 0 ]]; then
  # jq -Rs JSON-escapes the whole blob (newlines, quotes, backslashes in the
  # lead-written message). Fail-open: a missing/broken jq drops the injection
  # but NOT the pulse.json write above (already committed to disk).
  printf '[LEADV2 VOICE] %d new message(s) from lead (acked to inbox/done/):\n\n%s' \
    "$_n_surfaced" "$_voice_ctx" \
    | jq -Rs -c '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:.}}' 2>/dev/null || true
fi
exit 0
