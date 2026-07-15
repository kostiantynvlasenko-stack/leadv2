#!/usr/bin/env bash
# PreToolUse(Agent) WARN-only nudge: remind the lead to route fitting build/review
# tasks to Codex when a repo has opted into codex_enabled: true. NEVER blocks/denies —
# purely informational stderr reminder. Mirrors leadv2-block-codex.sh's cwd/policy
# resolution so behavior stays consistent across hooks.
set -euo pipefail
trap 'echo "[$(basename "$0")] error at line $LINENO" >&2; exit 0' ERR

INPUT="$(cat 2>/dev/null || true)"
[[ -z "$INPUT" ]] && exit 0

TOOL_NAME="$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || echo "")"
[[ "$TOOL_NAME" != "Agent" ]] && exit 0

SUBTYPE="$(echo "$INPUT" | jq -r '.tool_input.subagent_type // empty' 2>/dev/null || echo "")"
[[ -z "$SUBTYPE" ]] && exit 0

SUBTYPE_LOWER="$(echo "$SUBTYPE" | tr '[:upper:]' '[:lower:]')"

# Already routed to Codex -> nothing to nudge.
[[ "$SUBTYPE_LOWER" == *codex* ]] && exit 0

# Only nudge for build/review roles Codex is first-class for.
case "$SUBTYPE_LOWER" in
  *developer*|*postgres*|*frontend*|*critic*|*security*) ;;
  *) exit 0 ;;
esac

CWD="$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || echo "")"
[[ -z "$CWD" ]] && CWD="$PWD"

PROJECT_ROOT="${CLAUDE_PROJECT_ROOT:-${CLAUDE_PROJECT_DIR:-$(cd "$CWD" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null || echo "$CWD")}}"
POLICY="$PROJECT_ROOT/.claude/leadv2-overrides/codex-policy.yaml"

# No policy file, or codex_enabled not true -> stay silent (this repo hasn't opted in).
[[ -f "$POLICY" ]] || exit 0
grep -qE '^[[:space:]]*codex_enabled:[[:space:]]*true' "$POLICY" 2>/dev/null || exit 0

# LEADV2-FANOUT-MAXIMIZE-CHEAP-MODELS-01: when the fanout child was launched
# with LEADV2_MAXIMIZE_CHEAP_MODELS=1 (default-on; kill switch =0, see
# scripts/leadv2-fanout.sh), strengthen the reminder into an explicit
# should-route directive and log every fitting-Claude selection to a
# repo-local ledger for visibility. This stays WARN-only (continueOnBlock:
# true, no permissionDecision:deny) — it never hard-blocks the spawn, it only
# makes the steer louder and durably visible instead of a one-shot stderr line.
MAXIMIZE="${LEADV2_MAXIMIZE_CHEAP_MODELS:-1}"

if [[ "$MAXIMIZE" == "1" ]]; then
  REMINDER="[leadv2-codex-first-nudge] MAXIMIZE_CHEAP_MODELS=1: subagent_type=$SUBTYPE SHOULD route to Codex (codex-task.sh --tier standard, or --tier top for Heavy/adversarial per codex-policy.yaml) for plan/review/fitting-dev, or to GLM for background/bulk work -- not Claude quota, unless this spawn is integration-critical or a safety-gate task. See docs/model-routing.md and .claude/leadv2-overrides/codex-policy.yaml (dev_on_codex_fitting/phase5_review_standard)."

  # H1 (codex review): cap the ledger at ~256KB so default-on per-spawn
  # logging can't grow unbounded across the life of an installer's repo —
  # rotate by keeping only the newest half once the cap is exceeded. Cheap:
  # one wc -c + one tail -c, both bounded by LOG_CAP_BYTES, only on write.
  # H2 (codex review): the entire probe+rotate+append is wrapped in ONE
  # brace group whose stderr is redirected to /dev/null on the group itself
  # (not tacked onto the individual append) — this protects the append's own
  # `open()` failure (missing/unwritable dir or file) too, which a trailing
  # `>>file 2>/dev/null` on a single command does NOT: the shell attempts the
  # file-open redirect before the per-command stderr redirect takes effect,
  # so a bad path would otherwise still print a shell-level error on every
  # spawn despite `|| true`. The writability pre-check is belt-and-braces on
  # top of that structural fix, not a substitute for it.
  LOG_DIR="$PROJECT_ROOT/docs/leadv2"
  LOG_FILE="$LOG_DIR/codex-first-nudge.log"
  LOG_CAP_BYTES=262144
  {
    mkdir -p "$LOG_DIR"
    if [[ -w "$LOG_DIR" ]] && { [[ ! -e "$LOG_FILE" ]] || [[ -w "$LOG_FILE" ]]; }; then
      if [[ -f "$LOG_FILE" ]]; then
        LOG_SIZE="$(wc -c < "$LOG_FILE")"
        LOG_SIZE="${LOG_SIZE//[[:space:]]/}"
        if [[ "$LOG_SIZE" =~ ^[0-9]+$ ]] && (( LOG_SIZE > LOG_CAP_BYTES )); then
          tail -c "$(( LOG_CAP_BYTES / 2 ))" "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
        fi
      fi
      printf -- '%s subtype=%s cwd=%s decision=claude-selected-where-codex-glm-fits\n' \
        "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$SUBTYPE" "$CWD" >> "$LOG_FILE"
    fi
  } 2>/dev/null || true
else
  REMINDER="[leadv2-codex-first-nudge] REMINDER: codex_enabled: true in $POLICY -- consider routing this task (subagent_type=$SUBTYPE) to Codex first (codex-task.sh) before Claude quota. See docs/model-routing.md."
fi
echo "$REMINDER" >&2

# ALSO emit stdout JSON: a stderr-only line on an allow decision is never
# injected into model context (its "audience" was never actually the model).
# additionalContext on an allow decision IS surfaced to the model.
python3 -c "
import json, sys
print(json.dumps({
    'hookSpecificOutput': {
        'hookEventName': 'PreToolUse',
        'permissionDecision': 'allow',
        'additionalContext': sys.argv[1],
    }
}))
" "$REMINDER"

exit 0
