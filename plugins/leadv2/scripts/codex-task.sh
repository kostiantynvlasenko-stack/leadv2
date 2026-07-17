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
# --wait  Real flag in ANY position (P0, CODEX-WAIT-AND-TIER-01). Stripped here
#   so it never lands in the prompt (codex-companion `task` has no --wait option
#   and would fold it into the prompt text). Forces the FOREGROUND blocking path
#   for `task`/`review` (strips --background) so the wrapper blocks until the job
#   reaches a terminal state — the only way a long Codex job survives, since a
#   job dies the instant its launching client drops the app-server connection.
#   `adversarial-review` always blocks already (auto-injected for companion).
#
# --reason "<text>"  REQUIRED by --tier top (P1). `top` is the scarce Codex tier
#   (adversarial review + Heavy/arch plans); standard is the default, volume for
#   mechanical/bulk. Without --reason, --tier top exits non-zero.
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
# Strip --tier / --reason / --wait out of "$@" (every position) so codex-companion
# never sees them folded into the prompt. codex-companion understands only
# --model/--effort and (for review subcommands) --wait/--background -- `task` has
# NO --wait option, so an unstripped --wait lands verbatim in the prompt text and
# the call returns immediately (the CODEX-WAIT-AND-TIER-01 P0 bug).
_TIER=""
_REASON=""
_WAIT=0
_pre_args=()
_i=1
while [[ $_i -le $# ]]; do
  _arg="${!_i}"
  case "$_arg" in
    --tier|--tier=*)
      if [[ "$_arg" == --tier=* ]]; then _TIER="${_arg#--tier=}"; else _i=$((_i + 1)); _TIER="${!_i:-}"; fi ;;
    --reason|--reason=*)
      if [[ "$_arg" == --reason=* ]]; then _REASON="${_arg#--reason=}"; else _i=$((_i + 1)); _REASON="${!_i:-}"; fi ;;
    --wait|--wait=*)
      _WAIT=1 ;;
    *)
      _pre_args+=("$_arg") ;;
  esac
  _i=$((_i + 1))
done
set -- "${_pre_args[@]}"

# P1 (CODEX-WAIT-AND-TIER-01) -- --tier top must earn its cost. Measured before
# this gate: 17 runs on top (Sol), 9 on standard (Terra), 0 on volume (Luna) --
# 65% on the priciest tier, burning Codex to 27%. `top` is the scarce tier
# (adversarial review + Heavy/arch plans ONLY); standard is the default, volume
# for mechanical/bulk. Sol->Terra-ultra gov-gated fallback (below) is unaffected
# -- it fires on _TIER=="top" regardless of which model resolves. standard/volume
# pass through unchanged.
if [[ "${_TIER:-}" == "top" && -z "${_REASON:-}" ]]; then
  cat >&2 <<'EOF'
[codex-task] REFUSED: --tier top requires --reason "<why this run earns top>".
  Founder rule (CODEX-WAIT-AND-TIER-01): `top` (Sol -> Terra-ultra) is the scarce
  Codex tier, reserved for adversarial review + Heavy/arch plans. Default is
  `standard` (Terra/medium); use `volume` (Luna/low) for mechanical/bulk work.
  Re-run with --reason "<text>" to attest this run earns top, or drop --tier.
EOF
  exit 2
fi

SUB="${1:-}"

# EFFICIENCY-TUNE-01 C: job registry for supervise-loop stall detection.
# One line per spawn: /tmp/leadv2-job-registry/<session_id>/<job_id> = "run_dir\tstarted_at\tkind".
# Registry-clear rides the wrapper's own EXIT trap — the completion point that
# actually exists in this synchronous/--wait wrapper (foreground `node` call
# returning). Detached `--background` dispatches exit the wrapper immediately
# after parsing jobId, so their registry entry is cleared then too — no
# completion-tracking regression vs today (background completion is already
# tracked separately via codex-guard.sh's jobId watch, not this registry).
if [[ "$SUB" == "task" || "$SUB" == "review" || "$SUB" == "adversarial-review" ]]; then
  _JOB_REG_SID="${CLAUDE_SESSION_ID:-nosession}"
  _JOB_REG_DIR="/tmp/leadv2-job-registry/${_JOB_REG_SID}"
  _JOB_REG_ID="${SUB}-$(date +%s)-$$"
  mkdir -p "$_JOB_REG_DIR" 2>/dev/null \
    && printf -- '%s\t%s\t%s\n' "$PWD" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "codex" \
       > "${_JOB_REG_DIR}/${_JOB_REG_ID}" 2>/dev/null || true
  trap 'rm -f "${_JOB_REG_DIR}/${_JOB_REG_ID}" 2>/dev/null || true' EXIT
fi

# P0 (CODEX-WAIT-AND-TIER-01) -- --wait forces foreground blocking. `task`/
# `review` detach ONLY with --background; without it they already block in the
# foreground (codex-companion runForegroundCommand holds the app-server
# connection until the job reaches a terminal state). So when --wait is set we
# strip --background to guarantee the blocking path -- a backgrounded --wait is
# contradictory and the job dies the instant the launcher returns (proven: 5
# launch methods -> 5 deaths). adversarial-review already auto-injects --wait
# for companion below, so it is unaffected here.
if [[ "${_WAIT:-0}" -eq 1 && ( "${SUB:-}" == "task" || "${SUB:-}" == "review" ) ]]; then
  _bg_seen=0
  _wa_args=()
  for _a in "$@"; do
    if [[ "$_a" == "--background" ]]; then
      _bg_seen=1
    else
      _wa_args+=("$_a")
    fi
  done
  if [[ "$_bg_seen" -eq 1 ]]; then
    set -- "${_wa_args[@]}"
    echo "[codex-task] --wait set: stripping --background -- running foreground and blocking until terminal state (a backgrounded --wait would die on launcher exit)" >&2
  fi
fi

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
    # M4/Codex#3 (SUPERVISE-V2-01 fix-1): stock macOS ships neither gtimeout
    # nor timeout(1) -- the wrapper used to silently run node with NO deadline
    # at all, making the tier-aware CODEX_TIMEOUT + exit-124 auto-retry
    # completely inert. Loud WARN + a portable bash fallback (background
    # sleep+kill watcher) that enforces the SAME deadline contract and
    # explicitly reports it as exit 124, same as gtimeout/timeout(1) would.
    printf '[codex-task] WARN: neither gtimeout nor timeout(1) on PATH -- enforcing the %ss deadline via a portable sleep+kill watcher instead. Install coreutils (brew install coreutils) for the standard implementation.\n' "$_CODEX_TIMEOUT" >&2
    node "$COMPANION" "$@" &
    local _node_pid=$!
    local _fired_file
    _fired_file="$(mktemp)"
    (
      sleep "$_CODEX_TIMEOUT"
      if kill -0 "$_node_pid" 2>/dev/null; then
        : > "$_fired_file"
        kill -TERM "$_node_pid" 2>/dev/null || true
        sleep 2
        kill -KILL "$_node_pid" 2>/dev/null || true
      fi
    ) &
    local _watcher_pid=$!
    wait "$_node_pid" 2>/dev/null
    _exit_code=$?
    kill "$_watcher_pid" 2>/dev/null || true
    wait "$_watcher_pid" 2>/dev/null || true
    if [[ -s "$_fired_file" ]]; then
      _exit_code=124
    fi
    rm -f "$_fired_file"
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

# Codex#4 (SUPERVISE-V2-01 fix-1): tier one-level-lower retry on a real
# timeout (exit 124). Before this fix a timeout left `_run_with_fallback`
# retrying only 5.6 HTTP-400 failures -- a genuine timeout was simply
# abandoned, the tier-aware CODEX_TIMEOUT default existed but nothing acted
# on the exit-124 event. Single retry only: top->standard, standard->volume;
# volume (already the cheapest/fastest tier) has nowhere lower to go.
_tier_down() {
  case "$1" in
    top)      echo "standard" ;;
    standard) echo "volume" ;;
    *)        echo "" ;;
  esac
}

_tier_timeout_for() {
  case "$1" in
    top)      echo 1800 ;;
    standard) echo 900 ;;
    *)        echo 600 ;;
  esac
}

# Sets TIER_MODEL_OUT / WIRE_EFFORT_OUT for the given tier name. Same
# resolution table as the --tier extraction block above.
_tier_model_effort() {
  local _t="$1" _mc _eff
  _mc="${CODEX_MODELS_CACHE:-$HOME/.codex/models_cache.json}"
  case "$_t" in
    top)
      if command -v jq >/dev/null 2>&1 && [[ -f "$_mc" ]] \
         && jq -e '.models[]? | select(.slug=="gpt-5.6-sol")' "$_mc" >/dev/null 2>&1; then
        TIER_MODEL_OUT="gpt-5.6-sol"; _eff="high"
      else
        TIER_MODEL_OUT="gpt-5.6-terra"; _eff="ultra"
      fi
      ;;
    standard) TIER_MODEL_OUT="gpt-5.6-terra"; _eff="medium" ;;
    volume)   TIER_MODEL_OUT="gpt-5.6-luna";  _eff="low" ;;
    *)        TIER_MODEL_OUT="gpt-5.6-terra"; _eff="medium" ;;
  esac
  WIRE_EFFORT_OUT="$_eff"
  [[ "$WIRE_EFFORT_OUT" == "ultra" ]] && WIRE_EFFORT_OUT="xhigh"
}

_run_with_fallback() {
  local rc=0 out
  out="$(_run_node "$@" 2>&1)" && rc=0 || rc=$?

  if [[ $rc -eq 124 && -n "$_TIER" ]]; then
    local _next_tier
    _next_tier="$(_tier_down "$_TIER")"
    if [[ -n "$_next_tier" ]]; then
      echo "[codex-task] CODEX_RETRY_EVENT from_tier=$_TIER to_tier=$_next_tier reason=timeout" >&2
      _tier_model_effort "$_next_tier"
      local retry_args=() _prev=""
      for _a in "$@"; do
        if [[ "$_prev" == "--model" || "$_prev" == "-m" ]]; then
          retry_args+=("$TIER_MODEL_OUT")
        elif [[ "$_prev" == "--effort" ]]; then
          retry_args+=("$WIRE_EFFORT_OUT")
        else
          retry_args+=("$_a")
        fi
        _prev="$_a"
      done
      _TIER="$_next_tier"
      _CODEX_TIMEOUT="$(_tier_timeout_for "$_next_tier")"
      DISPATCH_MODEL="$TIER_MODEL_OUT"
      out="$(_run_node "${retry_args[@]}" 2>&1)" && rc=0 || rc=$?
      echo "[codex-task] CODEX_RETRY_EVENT tier=$_next_tier result=$([[ $rc -eq 0 ]] && echo ok || echo rc=$rc)" >&2
    fi
  fi

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
