#!/usr/bin/env bash
# PreToolUse:Agent guard — supervise-mode coordinator-only enforcement.
#
# Task LEADV2-SUPERVISE-GUARD-01 (fix round: review_round_2, C1/H1/H2). When
# the lead has entered /leadv2 supervise mode (scripts/leadv2-supervise.sh has
# written a live .supervise-active sentinel — see that script's
# SUPERVISE-GUARD-01 block), THAT SPECIFIC SUPERVISING SESSION must act as a
# COORDINATOR ONLY: dispatch new work via `scripts/leadv2-fanout.sh` into
# child sessions, never spawn in-session WORKER subagents itself. This hook
# enforces that mechanically rather than relying on prose in the skill.
#
# Sentinel: docs/leadv2/.supervise-active (control-plane path, resolved via
# leadv2-state-path.sh — same root as active.yaml / .supervise-last.json,
# i.e. IDENTICAL across every worktree of the same repo by design). JSON:
# {"pid": <durable claude pid of the supervising session>, "started_at": "<ISO>"}.
#
# PER-SESSION SCOPING (C1 fix, review_round_2): the sentinel path is shared
# repo-wide, but the BLOCK only fires for the exact session that owns it. On
# every Agent call this hook walks its own $PPID chain (_lv2_durable_pid,
# same primitive leadv2-supervise.sh uses to write the sentinel and
# leadv2-supervise-sentinel-cleanup.sh uses to decide ownership on Stop) to
# find ITS OWN durable claude-process pid, and compares it against the pid
# recorded in the sentinel:
#   - sentinel pid == my durable pid  -> this call originates from the very
#     same running claude process that entered supervise mode (an in-session
#     Agent-tool worker spawn) -> gated.
#   - sentinel pid != my durable pid  -> a DIFFERENT claude process (an
#     unrelated concurrent /leadv2 session on the same repo, OR a
#     `leadv2-fanout.sh` child running its own `claude -p` process) -> never
#     gated by this sentinel, regardless of liveness.
# This also self-resolves the "supervise mode blocks its own fanout
# children" defect: a fanout child is a distinct OS process tree, so its
# durable pid can never equal the supervising session's. As an explicit,
# cheap belt-and-suspenders signal (independent of process-tree walking),
# any call carrying LEADV2_ASYNC_QUESTIONS=1 in its own environment (the
# marker leadv2-fanout.sh exports into every child it launches — see
# scripts/leadv2-fanout.sh launch_headless()) is unconditionally allowed
# before any sentinel logic runs at all.
#
# ALLOW-LIST (H1/H2 fix, review_round_2): subagent_type=Explore is the ONLY
# type unconditionally allowed, regardless of model — read-only discovery
# must always work, even mid-supervise. Every other subagent_type — a known
# worker (developer, critic, general-purpose, ...) OR an unrecognized/future
# type never taught to this script — is treated as a gated worker. This
# replaced two prior bugs: (1) a `model=*haiku*` carve-out that bypassed the
# gate for ANY subagent_type including full workers, and (2) a blocklist
# design whose default branch was allow, so an unrecognized subagent_type
# silently passed through ungated. Both are now fail-CLOSED: default is
# deny-when-self-supervising, not allow.
#
# MODE SPLIT: provider-aware full-cycle relay is now the default. It stamps
# mode="legacy-relay" and denies abbreviated same-session workers; work must
# go through leadv2-fanout.sh so every child receives Phase 0..8. An explicit
# mode="interactive-lanes" remains a compatibility escape hatch and is the
# only mode that permits owning-session Agent/Workflow spawns.
#
# Toggle: LEADV2_SUPERVISE_GUARD=0 disables this guard entirely.
# Fail-safe: any internal error exits 0 (never bricks the session); a stale
# (dead-pid) sentinel is treated as inactive AND self-cleaned (removed) here
# so a leftover sentinel from a crashed session doesn't wedge the next one.

set -euo pipefail
trap 'echo "[$(basename "$0")] error at line $LINENO — continuing" >&2; exit 0' ERR

[[ "${LEADV2_SUPERVISE_GUARD:-1}" == "0" ]] && exit 0

# Fanout children carry this marker (exported by scripts/leadv2-fanout.sh
# launch_headless()) — never gated by ANY supervise sentinel, on any repo,
# regardless of pid/session comparisons below.
[[ -n "${LEADV2_ASYNC_QUESTIONS:-}" ]] && exit 0

INPUT="$(cat 2>/dev/null || true)"
[[ -z "$INPUT" ]] && exit 0

PARSED="$(python3 -c "
import sys, json
try:
    d = json.loads(sys.argv[1])
    inp = d.get('tool_input') or {}
    print((inp.get('subagent_type') or '').strip())
    print((inp.get('model') or '').strip())
    print((d.get('cwd') or '').strip())
except Exception:
    pass
" "$INPUT" 2>/dev/null || true)"
[[ -z "$PARSED" ]] && exit 0

SUBTYPE="$(printf -- '%s' "$PARSED" | sed -n '1p')"
CWD_FROM_INPUT="$(printf -- '%s' "$PARSED" | sed -n '3p')"
[[ -z "$CWD_FROM_INPUT" ]] && CWD_FROM_INPUT="$PWD"

SUBTYPE_LOWER="$(printf -- '%s' "$SUBTYPE" | tr '[:upper:]' '[:lower:]')"
# Strip a leading "leadv2:" namespace prefix if present, so leadv2:developer
# etc. are still recognized as their base worker type.
SUBTYPE_LOWER="${SUBTYPE_LOWER#leadv2:}"

# Read-only discovery is always allowed, regardless of supervise mode and
# regardless of model — the ONLY unconditional allow-list entry (H1/H2 fix:
# no more model= carve-out, no more blocklist-with-open-default).
[[ "$SUBTYPE_LOWER" == "explore" ]] && exit 0

# Resolve the state-path resolver + active-registry helper (plugin root
# first, else relative to self — same fallback pattern as
# leadv2-supervise-sentinel-cleanup.sh).
if [[ -n "${CLAUDE_PLUGIN_ROOT:-}" && -f "${CLAUDE_PLUGIN_ROOT}/scripts/leadv2-state-path.sh" ]]; then
  RESOLVER="${CLAUDE_PLUGIN_ROOT}/scripts/leadv2-state-path.sh"
  REGISTRY="${CLAUDE_PLUGIN_ROOT}/scripts/leadv2-active-registry.sh"
else
  _LV2_D="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  RESOLVER="${_LV2_D}/../scripts/leadv2-state-path.sh"
  REGISTRY="${_LV2_D}/../scripts/leadv2-active-registry.sh"
fi
[[ -x "$RESOLVER" ]] || exit 0

# --no-link: resolve only, skip the (relatively expensive) symlink-migration
# side effect — this hook fires on every single Agent call.
SENTINEL="$(PROJECT_ROOT="$CWD_FROM_INPUT" "$RESOLVER" --no-link .supervise-active 2>/dev/null || true)"
[[ -z "$SENTINEL" || ! -f "$SENTINEL" ]] && exit 0

SENTINEL_INFO="$(python3 -c "
import sys, json, os
path = sys.argv[1]
try:
    with open(path, encoding='utf-8') as fh:
        d = json.load(fh) or {}
    pid = d.get('pid')
    mode = d.get('mode') or ''
    if pid is None:
        print('DEAD'); print(''); print(mode); sys.exit(0)
    try:
        os.kill(int(pid), 0)
        print('LIVE'); print(int(pid)); print(mode)
    except (TypeError, ValueError, ProcessLookupError, PermissionError):
        print('DEAD'); print(''); print(mode)
except Exception:
    print('DEAD'); print(''); print('')
" "$SENTINEL" 2>/dev/null || printf -- 'DEAD\n\n\n')"

SENTINEL_STATUS="$(printf -- '%s' "$SENTINEL_INFO" | sed -n '1p')"
SENTINEL_PID="$(printf -- '%s' "$SENTINEL_INFO" | sed -n '2p')"
# MODE SPLIT (fix-2 R2-1): missing/unknown mode normalizes to "legacy-relay"
# (fail-CLOSED default — see comment above); only an explicit
# "interactive-lanes" stamp bypasses the deny-worker gate below.
SENTINEL_MODE="$(printf -- '%s' "$SENTINEL_INFO" | sed -n '3p')"
[[ "$SENTINEL_MODE" != "interactive-lanes" ]] && SENTINEL_MODE="legacy-relay"

if [[ "$SENTINEL_STATUS" != "LIVE" ]]; then
  # Stale sentinel (owning session already died) — self-clean and allow.
  rm -f "$SENTINEL" 2>/dev/null || true
  exit 0
fi

# PER-SESSION SCOPING (C1 fix): only gate calls that originate from the exact
# claude process that owns this sentinel. Anything else — an unrelated
# concurrent /leadv2 session on the same repo, a fanout child that somehow
# didn't carry the env marker above, etc. — is left untouched: not blocked,
# sentinel not modified.
MY_PID=""
if [[ -f "$REGISTRY" ]]; then
  # shellcheck source=leadv2-active-registry.sh
  source "$REGISTRY"
  MY_PID="$(_lv2_durable_pid 2>/dev/null || true)"
fi
[[ -z "$MY_PID" || "$MY_PID" != "$SENTINEL_PID" ]] && exit 0

# Compatibility escape hatch: only an explicitly stamped interactive-lanes
# session may create same-session workers. The default provider-aware relay
# (and missing/unknown modes) reaches the BLOCK below.
[[ "$SENTINEL_MODE" == "interactive-lanes" ]] && exit 0

# This IS the supervising session in legacy-relay mode, and the
# subagent_type is not on the read-only allow-list (recognized worker OR
# unrecognized/future type — fail-CLOSED by design, H2 fix) — BLOCK.
python3 -c "
import json
print(json.dumps({'hookSpecificOutput':{'hookEventName':'PreToolUse','permissionDecision':'deny','permissionDecisionReason':'supervise mode: dispatch this work via scripts/leadv2-fanout.sh --tasks <ID>, do not spawn in-session workers. Override: export LEADV2_SUPERVISE_GUARD=0'}}))
"
exit 2
