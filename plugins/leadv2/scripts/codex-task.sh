#!/bin/bash
set -euo pipefail
# Codex convenience wrapper — finds codex-companion.mjs and forwards all args
# Zero Claude tokens consumed. Uses OpenAI/Codex tokens.
#
# Usage:
#   codex-task.sh task "review my approach for X"
#   codex-task.sh adversarial-review --wait
#   codex-task.sh adversarial-review --wait --tier top     # pin to gpt-5.6 tier
#   codex-task.sh status [job-id]
#   codex-task.sh result [job-id]
#   codex-task.sh cancel [job-id]
#
# --tier <top|standard|volume>  Resolves to a Codex model (+ effort where the
#   subcommand accepts one) using the SAME tier table as leadv2-codex-planner.sh:
#     top      -> gpt-5.6-sol/high, falls back to gpt-5.6-terra/xhigh if sol is
#                 absent from ~/.codex/models_cache.json (gov-gated)
#     standard -> gpt-5.6-terra/medium  (EFFORT-RECAL 2026-07-10, was /high)
#     volume   -> gpt-5.6-luna/low      (EFFORT-RECAL 2026-07-10, was /medium)
#   Applies to `task` (model+effort) and `adversarial-review`/`review`
#   (model only — codex-companion's review command does not accept --effort;
#   passing it there would corrupt the focus-text positionals). Ignored (WARN)
#   for any other subcommand. An explicit --model already on the command line
#   always wins over --tier.
#
# Output filter: by default strips codex-companion's noisy [codex] meta lines
# (Running command / Command completed / Calling ... / Tool ... completed/failed /
# Assistant message captured — mid-stream previews).
# Kept: pure content (the final Findings/verdict body that has no [codex] prefix).
# Override: CODEX_VERBOSE=1 to see all meta lines.

COMPANION=$(find ~/.claude/plugins/cache/openai-codex -name codex-companion.mjs -path "*/scripts/*" 2>/dev/null | sort -V | tail -1)

if [[ -z "$COMPANION" ]]; then
  echo "ERROR: codex-companion.mjs not found. Is the Codex plugin installed?" >&2
  exit 1
fi

# ── --tier extraction (must run before the spark ban + subcommand dispatch,
# since codex-companion has no concept of --tier — it only understands
# --model/--effort). Strip --tier out of "$@" and resolve it to concrete
# --model/--effort values, identical resolution table to leadv2-codex-planner.sh.
_TIER=""
_pre_tier_args=()
_i=1
while [[ $_i -le $# ]]; do
  _arg="${!_i}"
  if [[ "$_arg" == "--tier" ]]; then
    _i=$((_i + 1))
    _TIER="${!_i:-}"
  else
    _pre_tier_args+=("$_arg")
  fi
  _i=$((_i + 1))
done
set -- "${_pre_tier_args[@]}"

SUB="${1:-}"

_has_flag() {
  # _has_flag <long> <short> "$@" -- true if either flag literal is present
  local long="$1" short="$2"; shift 2
  for _a in "$@"; do
    [[ "$_a" == "$long" || ( -n "$short" && "$_a" == "$short" ) ]] && return 0
  done
  return 1
}

if [[ -n "$_TIER" ]]; then
  MODELS_CACHE="${CODEX_MODELS_CACHE:-$HOME/.codex/models_cache.json}"
  case "$_TIER" in
    top)
      if command -v jq >/dev/null 2>&1 && [[ -f "$MODELS_CACHE" ]] \
         && jq -e '.models[]? | select(.slug=="gpt-5.6-sol")' "$MODELS_CACHE" >/dev/null 2>&1; then
        TIER_MODEL="gpt-5.6-sol"; TIER_EFFORT="high"
      else
        # lean: sol is gov-gated and currently absent from models_cache.json --
        # fall back to terra/ultra. upgrade when sol lands on this plan.
        TIER_MODEL="gpt-5.6-terra"; TIER_EFFORT="ultra"
      fi
      ;;
    standard)
      # EFFORT-RECAL 2026-07-10 (OpenAI 5.6: one-level-lower holds quality; rollback: standard=high, volume=medium)
      TIER_MODEL="gpt-5.6-terra"; TIER_EFFORT="medium"
      ;;
    volume)
      # EFFORT-RECAL 2026-07-10 (OpenAI 5.6: one-level-lower holds quality; rollback: standard=high, volume=medium)
      TIER_MODEL="gpt-5.6-luna"; TIER_EFFORT="low"
      ;;
    *)
      echo "[codex-task] unknown --tier: $_TIER (expected top|standard|volume)" >&2
      exit 1
      ;;
  esac
  # codex-companion only accepts {none,minimal,low,medium,high,xhigh} on the wire --
  # "ultra" is a logical top-tier label only. Same translation as the planner.
  WIRE_EFFORT="$TIER_EFFORT"
  [[ "$WIRE_EFFORT" == "ultra" ]] && WIRE_EFFORT="xhigh"

  case "$SUB" in
    adversarial-review|review)
      if _has_flag --model -m "$@"; then
        echo "[codex-task] --tier ignored: explicit --model already present" >&2
      else
        set -- "$@" --model "$TIER_MODEL"
      fi
      echo "[codex-task] tier=$_TIER -> model=$TIER_MODEL (sub=$SUB; review has no --effort wire)" >&2
      ;;
    task)
      if _has_flag --model -m "$@"; then
        echo "[codex-task] --tier ignored: explicit --model already present" >&2
      else
        set -- "$@" --model "$TIER_MODEL"
      fi
      if _has_flag --effort "" "$@"; then
        echo "[codex-task] --tier effort ignored: explicit --effort already present" >&2
      else
        set -- "$@" --effort "$WIRE_EFFORT"
      fi
      echo "[codex-task] tier=$_TIER -> model=$TIER_MODEL effort=$WIRE_EFFORT (sub=$SUB)" >&2
      ;;
    *)
      echo "[codex-task] WARN: --tier has no effect on subcommand '$SUB' -- ignoring" >&2
      ;;
  esac
fi

# Hard ban: spark is never used in this project (founder directive 2026-04-28).
# Reject both the CLI alias ("spark") and its resolved model id
# (gpt-5.3-codex-spark, per codex-companion.mjs MODEL_ALIASES) so a caller can't
# route around the ban by passing the resolved slug directly (H4).
for ((_i = 1; _i <= $#; _i++)); do
  if [[ "${!_i}" == "--model" || "${!_i}" == "-m" ]]; then
    _next=$((_i + 1))
    _next_val="${!_next:-}"
    if [[ "$_next_val" == "spark" || "$_next_val" == "gpt-5.3-codex-spark" ]]; then
      echo "[codex-task] spark model is banned in this project. Use default (gpt-5.5) or --tier <top|standard|volume>." >&2
      exit 1
    fi
  fi
done

# Default (no --tier given): plugin 1.0.4 (codex-plugin-cc#270) ships gpt-5.5
# with working structured output for adversarial-review -- empirically verified
# 2026-04-28. No model pin in that case; codex-companion inherits its default
# model (gpt-5.5). --tier (above) is the only thing that pins a model now --
# keep this comment in sync if the default model changes.

# adversarial-review MUST run synchronously. Without --wait, codex-companion starts an
# async job and returns immediately — the findings land in the plugin job-log and the
# caller's captured stdout gets only the start banner (the 2026-05-17 empty-output bug).
# Auto-inject --wait so the wrapper always blocks and the full review reaches stdout.
if [[ "$SUB" == "adversarial-review" ]]; then
  _has_wait=0
  for _a in "$@"; do [[ "$_a" == "--wait" ]] && _has_wait=1; done
  [[ "$_has_wait" -eq 0 ]] && set -- "$@" --wait

  # G2 -- default findings cap
  _MAX_FINDINGS="${CODEX_MAX_FINDINGS:-8}"
  _CAP_PREFIX="Review ONLY the changed files in the diff. Return at most ${_MAX_FINDINGS} findings, Critical/High severity only, one sentence each, with file:line. If a zone is clean say 'clean' -- do not pad."
  _new_args=()
  _found_focus=0
  # Bash positional params are 1-indexed ($1..$#); $0 is the script path.
  # Iterate [1, $#] inclusive -- starting at 0 forwarded $0 as the subcommand
  # ("Unknown subcommand: <path>") and dropped the final arg.
  _idx=1
  while [[ $_idx -le $# ]]; do
    _arg="${!_idx}"
    _idx=$((_idx + 1))
    if [[ "$_arg" == "--focus" ]]; then
      _found_focus=1
      _next_val="${!_idx:-}"
      _idx=$((_idx + 1))
      _new_args+=("--focus" "${_CAP_PREFIX} ${_next_val}")
    else
      _new_args+=("$_arg")
    fi
  done
  if [[ "$_found_focus" -eq 0 ]]; then
    _new_args+=("--focus" "$_CAP_PREFIX")
  fi
  set -- "${_new_args[@]}"

fi


# G1 -- hard timeout + auto-kill
# Controlled by CODEX_TIMEOUT env (default 600). Override per-repo via
# codex_review_timeout_sec in codex-policy.yaml.
#
# D-g tier-aware default (SUPERVISE-V2-01 item 5): a flat 600s default killed
# a --tier top (sol/high) run mid-work this session -- heavier tiers need
# more wall-clock. An EXPLICIT CODEX_TIMEOUT always wins over the tier
# default (never silently overridden).
if [[ -n "${CODEX_TIMEOUT:-}" ]]; then
  _CODEX_TIMEOUT="$CODEX_TIMEOUT"
else
  case "$_TIER" in
    top)      _CODEX_TIMEOUT=1800 ;;
    standard) _CODEX_TIMEOUT=900 ;;
    *)        _CODEX_TIMEOUT=600 ;;
  esac
fi
if command -v gtimeout >/dev/null 2>&1; then
  _TIMEOUT_CMD="gtimeout"
elif command -v timeout >/dev/null 2>&1; then
  _TIMEOUT_CMD="timeout"
else
  _TIMEOUT_CMD=""
fi
_run_node() {
  local _exit_code=0
  if [[ -n "$_TIMEOUT_CMD" ]]; then
    "$_TIMEOUT_CMD" "$_CODEX_TIMEOUT" node "$COMPANION" "$@" || _exit_code=$?
  else
    node "$COMPANION" "$@" || _exit_code=$?
  fi
  if [[ "$_exit_code" -eq 124 ]]; then
    printf 'CODEX TIMED OUT after %ss -- proceeding without Codex\n' "$_CODEX_TIMEOUT" >&2
    # Machine-readable event (D-g) so a pulse loop can surface it without
    # parsing prose -- tier defaults to "default" when --tier was not passed.
    printf 'CODEX_TIMEOUT_EVENT tier=%s limit=%s\n' "${_TIER:-default}" "$_CODEX_TIMEOUT" >&2
    exit 124
  fi
  return "$_exit_code"
}

# C1 -- 5.6 -> 5.5 fallback. A gpt-5.6-family dispatch can fail with a hard 400
# if the local Codex CLI is a stable release that predates 5.6 support (message
# observed: "requires a newer version of Codex") or if the resolved slug isn't
# recognized by the account tier (message observed: "is not supported when
# using Codex with a ChatGPT account", status 400). Either way this is a CLI/
# entitlement problem, not a prompt problem -- retry once on gpt-5.5/high so a
# stale CLI degrades gracefully instead of hard-failing every Codex call.
# lean: buffers full output before replaying instead of streaming live -- loses
# incremental [codex] progress lines during the (rare) fallback path. Upgrade
# to a tee-based streaming retry if interactive live-progress becomes a
# complaint.
_FALLBACK_MODEL="gpt-5.5"
_FALLBACK_EFFORT="high"

_extract_model_arg() {
  local _prev=""
  for _a in "$@"; do
    if [[ "$_prev" == "--model" || "$_prev" == "-m" ]]; then
      printf '%s' "$_a"
      return 0
    fi
    _prev="$_a"
  done
}
DISPATCH_MODEL="$(_extract_model_arg "$@")"

_run_with_fallback() {
  local rc=0 out
  out="$(_run_node "$@" 2>&1)" && rc=0 || rc=$?
  if [[ $rc -ne 0 && "$DISPATCH_MODEL" == gpt-5.6* ]] \
     && printf '%s' "$out" | grep -qE '"status":[[:space:]]*400|is not supported when using Codex|requires a newer version of Codex'; then
    echo "[codex-task] FALLBACK: model '$DISPATCH_MODEL' rejected by Codex CLI -- retrying once with ${_FALLBACK_MODEL} (effort ${_FALLBACK_EFFORT})" >&2
    local fb_args=() prev=""
    for _a in "$@"; do
      if [[ "$prev" == "--model" || "$prev" == "-m" ]]; then
        fb_args+=("$_FALLBACK_MODEL")
      elif [[ "$prev" == "--effort" ]]; then
        fb_args+=("$_FALLBACK_EFFORT")
      else
        fb_args+=("$_a")
      fi
      prev="$_a"
    done
    out="$(_run_node "${fb_args[@]}" 2>&1)" && rc=0 || rc=$?
  fi
  printf '%s\n' "$out"
  return "$rc"
}

# CODEX-NEVER-LOSE-01 -- auto-guard background dispatches. `task`/`review` with
# --background detach into a Codex job with nothing to notify this session on
# completion; if the session dies first, the result is lost. Arm codex-guard.sh
# (detached, non-blocking) so every background dispatch is watched to a
# terminal state and any uncommitted result gets rescued. --wait/foreground
# runs already return the full result inline and don't need this.
_has_background=0
for _a in "$@"; do [[ "$_a" == "--background" ]] && _has_background=1; done

if [[ ( "$SUB" == "task" || "$SUB" == "review" ) && "$_has_background" -eq 1 ]]; then
  _BG_OUT="$(_run_with_fallback "$@")"
  _BG_RC=$?
  printf '%s\n' "$_BG_OUT"

  # jobId format: <task|review>-<base36-timestamp>-<random6> (lib/state.mjs
  # generateJobId) -- appears verbatim in both the rendered launch line and
  # --json payload, so one regex covers both output modes.
  _JOB_ID="$(printf '%s\n' "$_BG_OUT" | grep -oE '(task|review)-[a-z0-9]+-[a-z0-9]+' | head -1 || true)"
  if [[ -n "$_JOB_ID" ]]; then
    # cwd: whatever was forwarded via --cwd/-C, else $PWD -- matches
    # codex-companion's own resolveCommandCwd() default (process.cwd()).
    _GUARD_CWD="$PWD"
    _prev=""
    for _a in "$@"; do
      if [[ "$_prev" == "--cwd" || "$_prev" == "-C" ]]; then
        _GUARD_CWD="$_a"
      fi
      _prev="$_a"
    done
    _GUARD_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/codex-guard.sh"
    if [[ -x "$_GUARD_SCRIPT" ]]; then
      nohup "$_GUARD_SCRIPT" "$_JOB_ID" "$_GUARD_CWD" >/dev/null 2>&1 < /dev/null &
      disown 2>/dev/null || true
      echo "[codex-task] armed codex-guard.sh for $_JOB_ID (cwd=$_GUARD_CWD)" >&2
    else
      echo "[codex-task] WARN: codex-guard.sh not found next to codex-task.sh -- background job $_JOB_ID is unguarded" >&2
    fi
  else
    echo "[codex-task] WARN: could not parse jobId from background dispatch output -- guard not armed" >&2
  fi
  exit "$_BG_RC"
fi

if [[ "${CODEX_VERBOSE:-0}" == "1" ]]; then
  _run_with_fallback "$@"
  exit $?
fi

# Strip noisy [codex] meta lines, keep the findings body / errors / un-prefixed content.
_strip_meta() {
  grep --line-buffered -vE '^\[codex\] (Running command|Command completed|Calling |Tool .* (completed|failed)|Assistant message captured)'
}

# For adversarial-review, also drop everything before the last findings marker so the
# caller sees only the actionable tail (set CODEX_FULL=1 to keep the whole log).
set -o pipefail
if [[ "$SUB" == "adversarial-review" && "${CODEX_FULL:-0}" != "1" ]]; then
  _run_with_fallback "$@" | _strip_meta | awk '
    BEGIN { buf=""; all=""; found=0 }
    /^# Codex|^\*\*Findings\*\*|^## Findings/ { buf=""; found=1 }
    { buf = buf $0 "\n"; all = all $0 "\n" }
    END { printf "%s", (found ? buf : all) }
  '
else
  _run_with_fallback "$@" | _strip_meta
fi
exit "${PIPESTATUS[0]}"
