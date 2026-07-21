#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/leadv2-temp.sh"
# claude-subsession.sh — spawn isolated Claude CLI headless session with a preset role.
# Part of /leadv2 orchestrator. Zero /lead token overlap: separate conversation, own session-id.
#
# ---------------------------------------------------------------------------
# STABLE PROMPT PREFIX — server cache telemetry is authoritative
# ---------------------------------------------------------------------------
# We split FINAL_PROMPT into:
#   STABLE PREFIX  = SYSTEM_PROMPT + SHARED_PROTOCOL_BOILERPLATE
#                    (no task-specific vars → identical across all spawns with
#                     same role in the same session → near-100% cache hit within 5 min)
#   TASK SUFFIX    = MISSION_BODY + PER_TASK_BOILERPLATE
#                    (contains $TASK_ID, $ROLE, $AGENT_SKILLS — small, uncached)
#
# Per-role prefix is materialised locally to keep prompt assembly deterministic
# and attach a checksum to telemetry. Reusing this FILE is not itself a cache
# hit: Claude Code manages server-side prompt caching, and only the reported
# cache_read_input_tokens proves reuse.
#
# Subscription-authenticated Claude Code manages a one-hour TTL automatically;
# API-key/third-party sessions use their configured TTL. Do not issue a
# separate "warm" API request: its system prefix differs from this CLI request.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Source leadv2-helpers.sh — provides leadv2_dry_run_guard() (D5 call site 1).
# Sourced early so the guard is available before any spawn infrastructure runs.
# Non-fatal if helpers not found (e.g., standalone invocation outside plugin).
# ---------------------------------------------------------------------------
_SUBSESSION_HELPERS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/leadv2-helpers.sh"
if [[ -f "$_SUBSESSION_HELPERS" ]]; then
  # shellcheck source=leadv2-helpers.sh
  source "$_SUBSESSION_HELPERS" 2>/dev/null || true
fi
unset _SUBSESSION_HELPERS

# ---------------------------------------------------------------------------
# Cost telemetry — approximate $ per model (USD per 1M tokens)
# ---------------------------------------------------------------------------
readonly PRICE_OPUS_INPUT=15
readonly PRICE_OPUS_OUTPUT=75
readonly PRICE_SONNET_INPUT=3
readonly PRICE_SONNET_OUTPUT=15

usage() {
  cat >&2 <<EOF
Usage: claude-subsession.sh --role <architect|critic|product-owner|strategist|developer|security-auditor> \\
          --model <opus|sonnet> --task-id <id> --mission-file <path> \\
          [--session-id <id>] [--effort <max|high>] [--wait]
EOF
  exit 1
}

ROLE=""; MODEL=""; TASK_ID=""; MISSION_FILE=""; SESSION_ID=""; EFFORT=""; WAIT=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --role) ROLE="$2"; shift 2 ;;
    --model) MODEL="$2"; shift 2 ;;
    --task-id) TASK_ID="$2"; shift 2 ;;
    --mission-file) MISSION_FILE="$2"; shift 2 ;;
    --session-id) SESSION_ID="$2"; shift 2 ;;
    --effort) EFFORT="$2"; shift 2 ;;
    --wait) WAIT=1; shift ;;
    *) echo "[claude-subsession] unknown arg: $1" >&2; usage ;;
  esac
done

[[ -z "$ROLE" || -z "$MODEL" || -z "$TASK_ID" || -z "$MISSION_FILE" ]] && usage

PROJECT_ROOT="${PROJECT_ROOT:-$(pwd)}"

# ---------------------------------------------------------------------------
# H1/H2/H4 fix-round-1 — task-scoped LEADV2_FORCE_MODEL + shared locked
# costs.yaml append helper.
#
# H2: LEADV2_FORCE_MODEL used to be honored unconditionally from inherited
# env, with no task binding — a stale force from a DIFFERENT task_id (e.g. a
# parent shell that ran task A earlier) could silently leak into task B's
# spawns. Now every read is gated by a companion LEADV2_FORCE_MODEL_TASK; if
# it doesn't match the CURRENT TASK_ID, the force is treated as ABSENT (never
# inherited, never cleared — just ignored) and re-derived fresh from the router.
# ---------------------------------------------------------------------------
_force_model_for_task() {
  if [[ "${LEADV2_FORCE_MODEL_TASK:-}" == "$TASK_ID" ]]; then
    printf '%s' "${LEADV2_FORCE_MODEL:-}"
  fi
}

_set_force_model_for_task() {
  export LEADV2_FORCE_MODEL="$1"
  export LEADV2_FORCE_MODEL_TASK="$TASK_ID"
}

_clear_force_model() {
  unset LEADV2_FORCE_MODEL
  unset LEADV2_FORCE_MODEL_TASK
}

# H1/H4: every costs.yaml writer in this file funnels through here — a single
# flock -x -w N (bounded, never unbounded) on the SAME .cost-flush.lock the
# router reads under -s. On lock timeout: log + skip, NEVER write unlocked
# (would race the router's read / another writer's append into a torn file).
LEADV2_LOCK_WAIT_SEC="${LEADV2_LOCK_WAIT_SEC:-10}"
_costs_append() {
  local costs_file="$1" content="$2" header="${3:-}"
  local lock_file
  lock_file="$(dirname "$costs_file")/.cost-flush.lock"
  mkdir -p "$(dirname "$costs_file")" 2>/dev/null || true
  (
    if ! flock -w "$LEADV2_LOCK_WAIT_SEC" -x 9; then
      echo "[claude-subsession] WARN: could not acquire cost-flush lock within ${LEADV2_LOCK_WAIT_SEC}s for ${costs_file} — skipping append (never write unlocked)" >&2
      exit 0
    fi
    if [[ -n "$header" && ! -f "$costs_file" ]]; then
      printf '%s' "$header" > "$costs_file"
    fi
    printf '%s' "$content" >> "$costs_file"
  ) 9>"$lock_file"
}

# ---------------------------------------------------------------------------
# CACHE DIR — /tmp/leadv2-cache/ holds per-role stable prefix files
# TTL: 5 min (matches Anthropic ephemeral cache window). Files older than
# 5 min are deleted at the start of each run so stale checksums never linger.
# ---------------------------------------------------------------------------
readonly CACHE_DIR="/tmp/leadv2-cache"
readonly CACHE_TTL_SEC=300
mkdir -p "$CACHE_DIR"

# Delete stale prefix files (older than CACHE_TTL_SEC seconds)
find "$CACHE_DIR" -name 'prefix-*.md' -mmin "+$((CACHE_TTL_SEC / 60))" -delete 2>/dev/null || true

# Primary source: .claude/agents/<role>.md (full definition with skills, MCP, model)
# Fallback: .claude/roles/<role>.md (legacy leadv2-specific roles, being phased out)
ROLE_FILE_AGENT="$PROJECT_ROOT/.claude/agents/${ROLE}.md"
ROLE_FILE_ROLES="$PROJECT_ROOT/.claude/roles/${ROLE}.md"

if [[ -f "$ROLE_FILE_AGENT" ]]; then
  ROLE_FILE="$ROLE_FILE_AGENT"
  ROLE_SOURCE="agents"
elif [[ -f "$ROLE_FILE_ROLES" ]]; then
  ROLE_FILE="$ROLE_FILE_ROLES"
  ROLE_SOURCE="roles"
else
  echo "[claude-subsession] role file not found in agents/ or roles/: $ROLE" >&2
  exit 1
fi

[[ -f "$MISSION_FILE" ]] || { echo "[claude-subsession] mission file missing: $MISSION_FILE" >&2; exit 1; }

HANDOFF_DIR="$PROJECT_ROOT/docs/handoff/$TASK_ID"
mkdir -p "$HANDOFF_DIR"

# Claude CLI requires --session-id to be a valid UUID
SESSION_LABEL="${ROLE}-${TASK_ID}-$(date +%s)"
if [[ -z "$SESSION_ID" ]]; then
  if command -v uuidgen >/dev/null 2>&1; then
    SESSION_ID="$(uuidgen | tr '[:upper:]' '[:lower:]')"
  else
    echo "[claude-subsession] uuidgen not found" >&2
    exit 1
  fi
fi

# Persist the label ↔ UUID mapping for resume-by-label
SESSION_MAP_FILE="$HANDOFF_DIR/sessions.map"
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$SESSION_LABEL" "$SESSION_ID" >> "$SESSION_MAP_FILE"

# Strip YAML frontmatter if source is agents/ (body-only as system prompt)
if [[ "$ROLE_SOURCE" == "agents" ]]; then
  SYSTEM_PROMPT=$(awk 'BEGIN{c=0} /^---$/{c++; next} c>=2 {print}' "$ROLE_FILE")
  # Extract skills list via python3 yaml (robust vs awk for multi-line frontmatter values)
  AGENT_SKILLS=$(python3 -c "
import sys, yaml
with open(sys.argv[1]) as f:
    content = f.read()
parts = content.split('---', 2)
if len(parts) >= 3:
    fm = yaml.safe_load(parts[1]) or {}
    skills = fm.get('skills') or []
    print(', '.join(skills))
" "$ROLE_FILE" 2>/dev/null || echo "")
else
  SYSTEM_PROMPT=$(cat "$ROLE_FILE")
  AGENT_SKILLS=""
fi
MISSION_BODY=$(cat "$MISSION_FILE")

# ---------------------------------------------------------------------------
# SHARED_PROTOCOL_BOILERPLATE — stable, NO task-specific vars.
# Goes into the cacheable prefix alongside SYSTEM_PROMPT.
# ---------------------------------------------------------------------------
SHARED_PROTOCOL_BOILERPLATE="MANDATORY — /leadv2 subagent protocol:
- Read docs/handoff/<TASK_ID>/context.yaml FIRST (if it exists). Respect \`decisions\` and \`off_limits\` absolutely.
- Write TWO deliverable files: docs/handoff/<TASK_ID>/<ROLE>.summary.md (≤50 words, one-sentence outcome, 2-3 bullets, 'Full: full.md') AND docs/handoff/<TASK_ID>/<ROLE>.full.md (full analysis). Full analysis goes in .full.md, not in chat.
- Last line of .full.md MUST be the literal string: DELIVERABLE_COMPLETE
- User input needed? Call: .claude/scripts/ask-lead.sh <TASK_ID> \"<question>\"
- Graph queries (MCP): .claude/scripts/ask-lead.sh <TASK_ID> \"graph: search_graph query=\\\"<q>\\\"\" — auto-proxied to MCP by lead, founder not bothered.
- MCP cache: check docs/handoff/<TASK_ID>/mcp-cache/<tool>-<hash>.yaml before any MCP call (age<30min → use cache). See skill §1b.
- NO MCP access in this subsession (headless claude -p mode). Mission file has \"## Graph context\" pre-loaded.
- Chat output to lead: ≤50 words (≤30 for PO/strategist). Full content to deliverable file.
- See full protocol: .claude/skills/leadv2-subagent-protocol/SKILL.md
- Codebase graph project: ${LEADV2_CODEBASE_PROJECT:-}
- Handoff discipline (context.yaml), question proxy (ask-lead.sh), DELIVERABLE_COMPLETE marker, chat limits, and off_limits hard stop are all in the skill file above."

# ---------------------------------------------------------------------------
# PER_TASK_BOILERPLATE — task-specific vars only. Stays in suffix (uncached).
# Keep this as small as possible — every byte here is un-cacheable.
# ---------------------------------------------------------------------------
PER_TASK_BOILERPLATE="Task binding:
- TASK_ID: ${TASK_ID}
- ROLE: ${ROLE}
- Deliverable summary: docs/handoff/${TASK_ID}/${ROLE}.summary.md (≤50 words)
- Deliverable full:    docs/handoff/${TASK_ID}/${ROLE}.full.md (full analysis, DELIVERABLE_COMPLETE last line)
- MCP cache dir:       docs/handoff/${TASK_ID}/mcp-cache/
- Context file: docs/handoff/${TASK_ID}/context.yaml
- Question proxy: .claude/scripts/ask-lead.sh ${TASK_ID} \"<question>\"
- Role-specific skills (from frontmatter): ${AGENT_SKILLS:-none registered}"

# ---------------------------------------------------------------------------
# build_cached_prefix() — materialise stable prefix to /tmp/leadv2-cache/
#   Input : $1 = role name
#   Output: path to prefix file (stdout)
#
# Steps:
#   1. Read .claude/agents/<role>.md body (frontmatter stripped)
#   2. Read .claude/skills/leadv2-subagent-protocol/SKILL.md body
#   3. Concatenate with SHARED_PROTOCOL_BOILERPLATE
#   4. Checksum (md5/sha1)
#   5. Return cached path if exists; else write it
# ---------------------------------------------------------------------------
build_cached_prefix() {
  local role="$1"
  local skill_file="$PROJECT_ROOT/.claude/skills/leadv2-subagent-protocol/SKILL.md"

  # Reuse the already-resolved agents/ OR legacy roles/ body. The previous
  # implementation re-opened agents/<role>.md unconditionally here, silently
  # dropping the supported roles/<role>.md fallback from the actual prompt.
  local role_body
  role_body="$SYSTEM_PROMPT"

  # Strip YAML frontmatter from skill file (between first two --- lines)
  local skill_body
  skill_body=$(awk 'BEGIN{c=0} /^---$/{c++; next} c>=2 {print}' "$skill_file" 2>/dev/null || printf '%s' "$(cat "$skill_file" 2>/dev/null || true)")

  # Build stable prefix content (no task-specific vars)
  local prefix_content
  prefix_content="${role_body}

---

${SHARED_PROTOCOL_BOILERPLATE}

---

Protocol reference:
${skill_body}"

  # Checksum — use md5 if available, else sha1, else cksum
  local checksum
  if command -v md5sum >/dev/null 2>&1; then
    checksum=$(printf '%s' "$prefix_content" | md5sum | cut -d' ' -f1)
  elif command -v md5 >/dev/null 2>&1; then
    checksum=$(printf '%s' "$prefix_content" | md5 -q)
  else
    checksum=$(printf '%s' "$prefix_content" | cksum | cut -d' ' -f1)
  fi

  local prefix_path="${CACHE_DIR}/prefix-${role}.${checksum}.md"

  if [[ ! -f "$prefix_path" ]]; then
    printf '%s' "$prefix_content" > "$prefix_path"
    echo "[claude-subsession] stable prefix materialised for ${role} → ${prefix_path}" >&2
  else
    echo "[claude-subsession] stable prefix file reused for ${role} (server cache status comes from usage telemetry)" >&2
  fi

  printf '%s' "$prefix_path"
}

# ---------------------------------------------------------------------------
# Assemble FINAL_PROMPT:
#   [STABLE PREFIX (cached)]   = role body + shared protocol boilerplate
#   [TASK SUFFIX (uncached)]   = mission body + per-task binding vars
# ---------------------------------------------------------------------------
PREFIX_FILE=$(build_cached_prefix "$ROLE")
STABLE_PREFIX=$(cat "$PREFIX_FILE")
# Extract checksum from filename for cost telemetry (prefix-<role>.<checksum>.md)
PREFIX_CHECKSUM=$(basename "$PREFIX_FILE" | sed 's/prefix-[^.]*\.\(.*\)\.md/\1/')

FINAL_PROMPT="${STABLE_PREFIX}

---

Mission:
${MISSION_BODY}

---

${PER_TASK_BOILERPLATE}"

STREAM_OUT="$HANDOFF_DIR/${ROLE}.stream.jsonl"

CLAUDE_ARGS=(
  -p "$FINAL_PROMPT"
  --model "$MODEL"
  --session-id "$SESSION_ID"
  --output-format stream-json
  --max-turns "${LEADV2_SUBSESSION_MAX_TURNS:-25}"
  --permission-mode acceptEdits
)
[[ -n "$EFFORT" ]] && CLAUDE_ARGS+=(--effort "$EFFORT")

export CLAUDE_ROLE="$ROLE"
export LEADV2_TASK_ID="$TASK_ID"

run_subsession() {
  claude "${CLAUDE_ARGS[@]}" > "$STREAM_OUT" 2>&1
}

# ---------------------------------------------------------------------------
# parse_and_record_cost — parse stream-json for token usage, append to costs.yaml
# Args: $1=stream_file $2=role $3=model $4=session_id $5=handoff_dir $6=start_epoch
#       $7=prefix_checksum (optional — hex checksum of the cached prefix used)
# Failures are non-fatal (log WARN only).
# ---------------------------------------------------------------------------
parse_and_record_cost() {
  local stream_file="$1" role="$2" model="$3" session_id="$4"
  local handoff_dir="$5" start_epoch="$6"
  local prefix_checksum="${7:-}"
  local costs_file="$handoff_dir/costs.yaml"

  if [[ ! -f "$stream_file" ]]; then
    echo "[claude-subsession] WARN: stream file missing, skipping cost record" >&2
    return 0
  fi

  # Extract token totals from stream-json usage events via python3.
  # Write the helper to a temp file (avoids heredoc-inside-$() shellcheck SC1073).
  local py_helper
  py_helper=$(lv2_mktemp_file "subsession-cost" "py")
  # shellcheck disable=SC2064
  trap "rm -f '$py_helper'" RETURN

  python3 -c "
import sys
print(open(sys.argv[1]).read())
" /dev/stdin > "$py_helper" 2>/dev/null <<'PYEOF'
import sys, json, math
from datetime import datetime, timezone

stream_file, model, role, session_id, start_epoch = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], float(sys.argv[5])
price_opus_in, price_opus_out = float(sys.argv[6]), float(sys.argv[7])
price_son_in, price_son_out   = float(sys.argv[8]), float(sys.argv[9])

total_in = total_out = 0
cache_read_tokens = 0   # tokens served from Anthropic prompt cache (input_tokens_cache_read)
cache_create_tokens = 0  # tokens written to cache (input_tokens_cache_write)
refusal_detected = False
try:
    with open(stream_file) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue
            # Detect stop_reason='refusal' (Fable 5 / new model refusal signal).
            # stop_reason appears at top level in message_stop events, or nested under 'message'.
            sr = obj.get("stop_reason") or (obj.get("message", {}) or {}).get("stop_reason")
            if sr == "refusal":
                refusal_detected = True
            usage = obj.get("usage") or (obj.get("message", {}) or {}).get("usage") or {}
            if not usage:
                if "input_tokens" in obj:
                    usage = obj
            in_t  = int(usage.get("input_tokens", 0))
            out_t = int(usage.get("output_tokens", 0))
            cr_t  = int(usage.get("cache_read_input_tokens", 0))
            cw_t  = int(usage.get("cache_creation_input_tokens", 0))
            if in_t  > total_in:  total_in  = in_t
            if out_t > total_out: total_out = out_t
            if cr_t  > cache_read_tokens:   cache_read_tokens   = cr_t
            if cw_t  > cache_create_tokens: cache_create_tokens = cw_t
except Exception as e:
    print(f"PARSE_ERROR: {e}", file=sys.stderr)
    sys.exit(1)

m = model.lower()
if "opus" in m:
    p_in, p_out = price_opus_in, price_opus_out
else:
    p_in, p_out = price_son_in, price_son_out

cost = (total_in * p_in + total_out * p_out) / 1_000_000
duration = int(math.floor(float(datetime.now(timezone.utc).timestamp()) - start_epoch))
ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

# cache_hit_rate: fraction of billable input tokens served from cache.
# null when no cache activity is reported (first spawn or cold miss).
denominator = cache_read_tokens + cache_create_tokens + total_in
cache_hit_rate = round(cache_read_tokens / denominator, 4) if denominator > 0 and cache_read_tokens > 0 else None
cache_hit_str = str(cache_hit_rate) if cache_hit_rate is not None else "null"

status = "REFUSAL" if refusal_detected else "OK"
print(f"{status} {total_in} {total_out} {cost:.6f} {duration} {ts} {cache_hit_str}")
PYEOF

  local result
  result=$(python3 "$py_helper" \
    "$stream_file" "$model" "$role" "$session_id" "$start_epoch" \
    "$PRICE_OPUS_INPUT" "$PRICE_OPUS_OUTPUT" \
    "$PRICE_SONNET_INPUT" "$PRICE_SONNET_OUTPUT" 2>/dev/null) || result="PARSE_ERROR"

  if [[ "$result" == "PARSE_ERROR"* ]] || [[ -z "$result" ]]; then
    echo "[claude-subsession] WARN: cost parse failed for $role/$model, skipping" >&2
    return 0
  fi

  # Detect hard refusal from model (stop_reason='refusal').
  # Export flag so the DELIVERABLE_COMPLETE check section can act on it.
  if [[ "$result" == "REFUSAL "* ]]; then
    echo "[claude-subsession] HARD FAILURE: model returned stop_reason=refusal for role=${role} model=${model} — treating as hard failure, not empty-success" >&2
    export _SUBSESSION_REFUSAL_DETECTED=1
  fi

  read -r _ok input_tokens output_tokens cost_usd duration_sec timestamp cache_hit_rate_val <<< "$result"

  # Derive prefix checksum from the cache file written by build_cached_prefix().
  # Checksum is embedded in the filename: prefix-<role>.<checksum>.md
  local derived_checksum="${prefix_checksum}"
  if [[ -z "$derived_checksum" ]]; then
    local found_prefix
    found_prefix=$(find "$CACHE_DIR" -name "prefix-${role}.*.md" -newer /proc/1 2>/dev/null | head -1 || true)
    if [[ -n "$found_prefix" ]]; then
      derived_checksum=$(basename "$found_prefix" | sed 's/prefix-[^.]*\.\(.*\)\.md/\1/')
    fi
  fi
  local checksum_val="${derived_checksum:-null}"

  # H4 fix-round-1: locked append (was a bare >> with a separate unlocked
  # header-creation check — both folded into _costs_append's single critical
  # section now, closing the header-creation TOCTOU too).
  local _row
  _row=$(printf -- '- role: %s\n  model: %s\n  session_id: %s\n  input_tokens: %s\n  output_tokens: %s\n  cost_usd: %s\n  duration_sec: %s\n  timestamp: %s\n  cache_hit_rate: %s\n  prompt_prefix_checksum: %s\n' \
    "$role" "$model" "$session_id" \
    "$input_tokens" "$output_tokens" "$cost_usd" \
    "$duration_sec" "$timestamp" \
    "${cache_hit_rate_val:-null}" "$checksum_val")
  _costs_append "$costs_file" "$_row" "# leadv2 cost telemetry — appended by claude-subsession.sh
"

  echo "[claude-subsession] cost recorded: ${role}/${model} in=${input_tokens} out=${output_tokens} usd=${cost_usd} cache_hit=${cache_hit_rate_val:-null}" >&2
}

# ---------------------------------------------------------------------------
# Cost ceiling check — run before spawn.
# Reads router output if LEADV2_TASK_CLASS is set; otherwise no-op.
#
# Thresholds:
#   60%  → WARN + downgrade subsequent spawns (opus→sonnet) + log downgrade_event
#          Set LEADV2_FORCE_MODEL=sonnet for remaining spawns in this task.
#   85%  → Refuse new spawns; require founder Tier B override.
#          Write pending decision file if not already present.
#   100% → Auto-abort task; compose Tier B decision with A/B/C options.
#          State=paused in LEAD_V2_STATE. (Exits 1 to stop spawn.)
# ---------------------------------------------------------------------------
_check_cost_ceiling() {
  local task_class="${LEADV2_TASK_CLASS:-}"
  if [[ -z "$task_class" || -z "$TASK_ID" ]]; then
    return 0
  fi

  local router_script
  router_script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/leadv2-router.sh"
  [[ -f "$router_script" ]] || return 0

  # Use build/single_file as probe — we only need ceiling_status + burn metrics
  local router_out
  router_out=$(bash "$router_script" \
    --phase build --step single_file \
    --task-id "$TASK_ID" --class "$task_class" 2>/dev/null) || {
    local rc=$?
    if [[ $rc -eq 1 ]]; then
      echo "[claude-subsession] HARD STOP: task burn >= ceiling — refusing spawn of ${ROLE}" >&2
      _write_auto_abort_decision
      exit 1
    fi
    # exit 2 = routing.yaml missing or unknown step, or router crashed outright
    # (row 6, design §4). Router gave us NOTHING this probe — do not return 0
    # into an unforced spawn if a prior spawn already forced a model in THIS
    # task (H2: task-scoped — a different task's stale force is never inherited).
    local _inherited_force
    _inherited_force="$(_force_model_for_task)"
    if [[ -n "$_inherited_force" && "$_inherited_force" != "$MODEL" ]]; then
      echo "[claude-subsession] WARN: router probe failed (rc=${rc}) — keeping inherited LEADV2_FORCE_MODEL=${_inherited_force} for ${ROLE}" >&2
      MODEL="$_inherited_force"
    fi
    return 0
  }

  local ceiling_status current_burn ceiling_usd
  local recovery_status downgrade_active force_model hard_stop_flag fresh_trip burn_readable
  ceiling_status=$(printf '%s\n' "$router_out" | grep '^ceiling_status=' | cut -d= -f2 || true)
  current_burn=$(printf '%s\n' "$router_out" | grep '^current_burn_usd=' | cut -d= -f2 || echo "0")
  ceiling_usd=$(printf '%s\n' "$router_out" | grep '^ceiling_usd=' | cut -d= -f2 || echo "0")
  # T8b ROUTING-TIER-RECOVERY-REDESIGN keys (additive; router recomputes fresh
  # every probe — NOT inherited env; env is a per-task-scoped cache, never
  # authority). recovery_status/downgrade_active default to "unknown" when
  # absent (older router without the T8b keys) so we HOLD, never recover.
  recovery_status=$(printf '%s\n' "$router_out" | grep '^recovery_status=' | cut -d= -f2 || echo "unknown")
  downgrade_active=$(printf '%s\n' "$router_out" | grep '^downgrade_active=' | cut -d= -f2 || echo "unknown")
  force_model=$(printf '%s\n' "$router_out" | grep '^force_model=' | cut -d= -f2 || true)
  hard_stop_flag=$(printf '%s\n' "$router_out" | grep '^hard_stop=' | cut -d= -f2 || echo "false")
  fresh_trip=$(printf '%s\n' "$router_out" | grep '^fresh_trip=' | cut -d= -f2 || echo "false")
  # F-A fix-round-2: burn_readable distinguishes "genuinely unreadable spend
  # history" from a plain never-spent/day-0 unknown — default true (day-0
  # shaped) when absent, matching the router's own F-A default.
  burn_readable=$(printf '%s\n' "$router_out" | grep '^burn_readable=' | cut -d= -f2 || echo "true")
  [[ -z "$recovery_status" ]] && recovery_status="unknown"
  [[ -z "$downgrade_active" ]] && downgrade_active="unknown"
  [[ -z "$hard_stop_flag" ]] && hard_stop_flag="false"
  [[ -z "$fresh_trip" ]] && fresh_trip="false"
  [[ -z "$burn_readable" ]] && burn_readable="true"

  # ---- 100% cap: auto-abort ----
  if [[ "$ceiling_status" == "hard_stop_95pct" ]]; then
    # Check if we've actually hit 100% (router fires at 95% but we want explicit 100% abort)
    local over_100=0
    if command -v python3 >/dev/null 2>&1 && [[ -n "$current_burn" && -n "$ceiling_usd" ]]; then
      over_100=$(python3 -c "print(1 if float('${current_burn}') >= float('${ceiling_usd}') else 0)" 2>/dev/null || echo "0")
    fi
    if [[ "$over_100" == "1" ]]; then
      echo "[claude-subsession] AUTO-ABORT: task burn ${current_burn} >= cap ${ceiling_usd} — composing Tier B decision" >&2
      _write_auto_abort_decision "$current_burn" "$ceiling_usd"
    else
      echo "[claude-subsession] HARD STOP: task burn >= 95% of ${task_class} ceiling — refusing spawn of ${ROLE}" >&2
      _write_85pct_decision "$current_burn" "$ceiling_usd"
    fi
    exit 1
  fi

  # ---- 85% cap: require founder Tier B override ----
  if [[ -n "$ceiling_usd" && -n "$current_burn" ]]; then
    local burn_pct=0
    if command -v python3 >/dev/null 2>&1 && [[ "$ceiling_usd" != "0" ]]; then
      burn_pct=$(python3 -c "
b, c = float('${current_burn}'), float('${ceiling_usd}')
print(int(b/c*100) if c>0 else 0)
" 2>/dev/null || echo "0")
    fi
    if [[ "$burn_pct" -ge 85 ]]; then
      echo "[claude-subsession] BLOCKED: burn ${burn_pct}% >= 85% ceiling — Tier B override required for ${ROLE}" >&2
      _write_85pct_decision "$current_burn" "$ceiling_usd"
      # Log WARN in LEAD_V2_STATUS
      _append_status_warn "cost_ceiling_85pct: burn ${current_burn} / ${ceiling_usd} (${burn_pct}%) — spawn ${ROLE} blocked"
      exit 1
    fi
  fi

  # ---- T8b ROUTING-TIER-RECOVERY-REDESIGN: windowed recovery gate ----
  # Router recomputes recovery_status/downgrade_active/force_model fresh on
  # EVERY probe from costs.yaml (never from inherited env — env is a cache,
  # never authority, Codex #3). Exactly one branch may clear LEADV2_FORCE_MODEL.
  # NOTE (Risk 4, preserved): MODEL is shell-local and does not propagate to
  # separate-process spawns; LEADV2_FORCE_MODEL (exported) is the cross-spawn
  # signal every subsequent _check_cost_ceiling call re-derives.
  # H2 fix-round-1: every LEADV2_FORCE_MODEL touch below is task-scoped via
  # _force_model_for_task/_set_force_model_for_task/_clear_force_model — a
  # stale force from a different task_id is never read, inherited, or cleared.
  #
  # F-D fix-round-2: a FRESH process (no inherited env at all) used to only
  # HOLD if LEADV2_FORCE_MODEL was already inherited — so `claude-subsession
  # --model opus` with router force_model=sonnet still launched opus. Now:
  # whenever force_model is a REAL value (present, != __HOLD__), it is
  # ADOPTED DIRECTLY as authoritative — never gated behind "was something
  # already inherited". This covers downgrade_active==true AND the
  # "unknown but to_model still known" case (T6/T7-style: active downgrade
  # existed, later windowed data got corrupted) uniformly.
  local _inherited_force
  _inherited_force="$(_force_model_for_task)"
  if [[ -n "$force_model" && "$force_model" != "__HOLD__" ]]; then
    if [[ "$fresh_trip" == "true" ]]; then
      echo "[claude-subsession] WARN: windowed burn >= 60% ceiling — downgrading ${MODEL} → ${force_model} for ${ROLE}" >&2
      _log_downgrade_event "$MODEL" "$force_model" "$current_burn" "$ceiling_usd"
    else
      echo "[claude-subsession] WARN: recovery gate holding (downgrade_active=${downgrade_active}, recovery_status=${recovery_status}) — adopting router force_model=${force_model} for ${ROLE}" >&2
    fi
    _set_force_model_for_task "$force_model"
    MODEL="$force_model"
    _append_status_warn "cost_ceiling_recovery_hold: spawn ${ROLE} forced to ${force_model}"
  elif [[ "$downgrade_active" == "true" || "$burn_readable" == "false" ]]; then
    # force_model unreadable (__HOLD__) but genuinely active-or-unreadable —
    # NOT a plain day-0 unknown (F-A). If this exact task already had a
    # force inherited (e.g. costs.yaml vanished mid-task, design row 1),
    # keep holding that; otherwise fall back to the safest floor tier.
    if [[ -n "$_inherited_force" ]]; then
      echo "[claude-subsession] WARN: downgrade active/unreadable, force_model unreadable — keeping inherited LEADV2_FORCE_MODEL=${_inherited_force} for ${ROLE}" >&2
      MODEL="$_inherited_force"
    else
      echo "[claude-subsession] WARN: downgrade active/unreadable, force_model unreadable, nothing inherited for this task — forcing safest tier (haiku) for ${ROLE}" >&2
      _set_force_model_for_task "haiku"
      MODEL="haiku"
    fi
  elif [[ "$downgrade_active" == "false" && "$recovery_status" == "ok" ]]; then
    # THE only clear — flag-off (LEADV2_COOLDOWN_RECOVERY=0) always yields
    # downgrade_active=false only when there was never an active downgrade,
    # so this never fires a spurious recovery when the flag is off (design F2).
    if [[ -n "$_inherited_force" ]]; then
      echo "[claude-subsession] INFO: cost recovery — clearing forced model (was ${_inherited_force}) for ${ROLE}" >&2
    fi
    _clear_force_model
  else
    # F-A: plain day-0/never-spent unknown — recovery_status=unknown,
    # downgrade_active=unknown, burn_readable=true, force_model unreadable,
    # AND no active downgrade. KNOWN-safe zero-spend state, not lost data.
    # If something was inherited for THIS exact task (ambiguous mid-task
    # file-loss vs genuine day-0 — the file state alone can't tell them
    # apart), keep holding it; otherwise this is a genuine first-ever probe
    # — allow the caller's requested tier through untouched, never haiku.
    if [[ -n "$_inherited_force" && "$_inherited_force" != "$MODEL" ]]; then
      echo "[claude-subsession] WARN: recovery state unknown (day-0-shaped) — keeping inherited LEADV2_FORCE_MODEL=${_inherited_force} for ${ROLE}" >&2
      MODEL="$_inherited_force"
    fi
  fi
}

# ---------------------------------------------------------------------------
# _log_downgrade_event — append downgrade record to costs.yaml
# ---------------------------------------------------------------------------
_log_downgrade_event() {
  local from_model="$1" to_model="$2" current_burn="${3:-?}" ceiling="${4:-?}"
  local costs_file="$HANDOFF_DIR/costs.yaml"
  # H1/H4 fix-round-1: routed through the shared _costs_append (flock -x -w N
  # on the same .cost-flush.lock the router reads under -s) instead of its
  # own unbounded flock -x 9 — bounded wait, never a permanent hang.
  local _row
  _row=$(printf -- '- downgrade_event:\n    timestamp: %s\n    reason: cost_ceiling_60pct\n    from_model: %s\n    to_model: %s\n    affected_role: %s\n    burn_usd: %s\n    ceiling_usd: %s\n' \
    "$(date -u +%FT%TZ)" "$from_model" "$to_model" "$ROLE" "$current_burn" "$ceiling")
  _costs_append "$costs_file" "$_row"
}

# ---------------------------------------------------------------------------
# _write_85pct_decision — compose Tier B decision requiring founder override
# ---------------------------------------------------------------------------
_write_85pct_decision() {
  local current_burn="${1:-?}" ceiling="${2:-?}"
  local decisions_dir="$PROJECT_ROOT/docs/leadv2-decisions"
  mkdir -p "$decisions_dir" 2>/dev/null || true
  local decision_file="$decisions_dir/cost-override-${TASK_ID}.yaml"
  [[ -f "$decision_file" ]] && return 0  # already written
  {
    printf -- 'id: cost-override-%s\n' "$TASK_ID"
    printf -- 'task_id: %s\n' "$TASK_ID"
    printf -- 'trigger: cost_ceiling_85pct\n'
    printf -- 'status: pending\n'
    printf -- 'question: "Task burn $%s has reached 85%% of the $%s cap. Continue spawning %s?"\n' \
      "$current_burn" "$ceiling" "$ROLE"
    printf -- 'options:\n'
    printf -- '  A: "Override cap for this spawn only (continue on opus)"\n'
    printf -- '  B: "Force sonnet for all remaining spawns in this task (default)"\n'
    printf -- '  C: "Abort task and mark blocked-on-human"\n'
    printf -- 'default_option: B\n'
    printf -- 'created_at: %s\n' "$(date -u +%FT%TZ)"
  } > "$decision_file" 2>/dev/null || true
  echo "[claude-subsession] Decision file written: $decision_file" >&2
}

# ---------------------------------------------------------------------------
# _write_auto_abort_decision — compose Tier B decision for 100% cap breach
# ---------------------------------------------------------------------------
_write_auto_abort_decision() {
  local current_burn="${1:-?}" ceiling="${2:-?}"
  local state_md="$PROJECT_ROOT/docs/LEAD_V2_STATE.md"
  local decisions_dir="$PROJECT_ROOT/docs/leadv2-decisions"
  mkdir -p "$decisions_dir" 2>/dev/null || true
  local decision_file="$decisions_dir/auto-abort-${TASK_ID}.yaml"

  # Mark state=paused in LEAD_V2_STATE.md
  if [[ -f "$state_md" ]]; then
    sed -i.bak 's/^status: active/status: paused/' "$state_md" 2>/dev/null || true
    rm -f "${state_md}.bak" 2>/dev/null || true
  fi

  # Write outcome to history in costs.yaml — H4 fix-round-1: locked append.
  local costs_file="$HANDOFF_DIR/costs.yaml"
  local _row
  _row=$(printf -- '- event: budget_exceeded\n  role: %s\n  burn_usd: %s\n  ceiling_usd: %s\n  outcome: budget_exceeded\n  timestamp: %s\n' \
    "$ROLE" "$current_burn" "$ceiling" "$(date -u +%FT%TZ)")
  _costs_append "$costs_file" "$_row"

  # Compose decision file
  {
    printf -- 'id: auto-abort-%s\n' "$TASK_ID"
    printf -- 'task_id: %s\n' "$TASK_ID"
    printf -- 'trigger: cost_ceiling_100pct\n'
    printf -- 'status: pending\n'
    printf -- 'question: "Task %s exceeded 100%% of its $%s cap (spent $%s). Choose next action:"\n' \
      "$TASK_ID" "$ceiling" "$current_burn"
    printf -- 'options:\n'
    printf -- '  A: "Continue anyway — raise cap to 2x for this task only (founder override)"\n'
    printf -- '  B: "Auto-downgrade remaining work to sonnet (recommended if feasible)"\n'
    printf -- '  C: "Abort task, mark blocked-on-human, move to next in queue (recommended if durable fix requires more Opus)"\n'
    printf -- 'default_option: B\n'
    printf -- 'state_set: paused\n'
    printf -- 'created_at: %s\n' "$(date -u +%FT%TZ)"
  } > "$decision_file" 2>/dev/null || true
  echo "[claude-subsession] AUTO-ABORT decision written: $decision_file" >&2
}

# ---------------------------------------------------------------------------
# _append_status_warn — append WARN line to LEAD_V2_STATUS.md
# ---------------------------------------------------------------------------
_append_status_warn() {
  local msg="$1"
  local status_md="$PROJECT_ROOT/docs/LEAD_V2_STATUS.md"
  {
    printf -- '\n> WARN [%s]: %s\n' "$(date -u +%FT%TZ)" "$msg"
  } >> "$status_md" 2>/dev/null || true
}

_check_cost_ceiling

# ---------------------------------------------------------------------------
# T8 latent-bug fix (Critical, UNCONDITIONAL — no flag): rebuild the --model
# element of CLAUDE_ARGS now that _check_cost_ceiling has had its final say
# on $MODEL. Bash arrays copy the VALUE of $MODEL at construction time (line
# ~261) — mutating $MODEL afterwards (the pre-existing 60%-cost-ceiling
# downgrade) could never reach the already-frozen array element without this
# rebuild (Codex + critic, fix-round-1 Critical finding — confirmed dead
# wire: the 60%-downgrade only ever affected subsequent spawns, never the
# current one, before this fix). Self-locating (finds "--model" by value,
# not a magic index) so it stays correct if CLAUDE_ARGS is ever reordered.
for _cargs_i in "${!CLAUDE_ARGS[@]}"; do
  if [[ "${CLAUDE_ARGS[$_cargs_i]}" == "--model" ]]; then
    CLAUDE_ARGS[_cargs_i + 1]="$MODEL"
    break
  fi
done
unset _cargs_i

# ---------------------------------------------------------------------------
# warm_chain() — deprecated zero-cost compatibility function.
#
# Usage: warm_chain "architect:opus" "critic:opus" "developer:sonnet"
#
# Each argument is "<role>:<model>". Skipped if warmer script not found.
# ---------------------------------------------------------------------------
warm_chain() {
  echo "[warm_chain] skipped: standalone API warming cannot warm the exact Claude Code prefix; rely on cache_read_input_tokens" >&2
  return 0
}

# ---------------------------------------------------------------------------
# Empty-session detection — called after spawn completes.
# Logs "empty_session" event to costs.yaml; orchestrator passes
# signals.empty_previous=true to router on retry to trigger stop rules.
# ---------------------------------------------------------------------------
_detect_empty_session() {
  local deliverable="$HANDOFF_DIR/${ROLE}.summary.md"
  # Fall back to .md if .summary.md not present (legacy delivery)
  [[ -f "$deliverable" ]] || deliverable="$HANDOFF_DIR/${ROLE}.md"
  [[ -f "$deliverable" ]] || return 0
  local word_count
  word_count=$(wc -w < "$deliverable" 2>/dev/null || printf '0')
  local threshold=50
  if [[ "$word_count" -lt "$threshold" ]]; then
    echo "[claude-subsession] WARN: empty_session — ${ROLE}.summary.md has ${word_count} words (< ${threshold})" >&2
    # H4 fix-round-1: locked append.
    local costs_file="$HANDOFF_DIR/costs.yaml"
    local _row
    _row=$(printf -- '- event: empty_session\n  role: %s\n  model: %s\n  word_count: %s\n  timestamp: %s\n' \
      "$ROLE" "$MODEL" "$word_count" "$(date -u +%FT%TZ)")
    _costs_append "$costs_file" "$_row"
  fi
}

# ---------------------------------------------------------------------------
# D5 DRY_RUN chokepoint — call site 1 of 4 (claude-subsession.sh spawn).
# leadv2_dry_run_guard() is sourced from leadv2-helpers.sh above.
# When LEADV2_DRY_RUN=1: logs "[DRY_RUN] subsession spawn ..." and exits 0
# without launching any claude CLI process (byte-identical when flag absent, D6).
# ---------------------------------------------------------------------------
if declare -f leadv2_dry_run_guard >/dev/null 2>&1; then
  if leadv2_dry_run_guard "subsession spawn: role=${ROLE} model=${MODEL} task=${TASK_ID}"; then
    exit 0
  fi
fi

if [[ "$WAIT" == "1" ]]; then
  _start_epoch=$(date +%s)
  run_subsession
  parse_and_record_cost "$STREAM_OUT" "$ROLE" "$MODEL" "$SESSION_ID" "$HANDOFF_DIR" "$_start_epoch" "$PREFIX_CHECKSUM"
  _detect_empty_session
  # Two-file protocol: DELIVERABLE_COMPLETE lives in .full.md; .summary.md must also exist.
  FULL_FILE="$HANDOFF_DIR/${ROLE}.full.md"
  SUMMARY_FILE="$HANDOFF_DIR/${ROLE}.summary.md"
  # Backward compat: also accept legacy single-file delivery for one cycle
  LEGACY_FILE="$HANDOFF_DIR/${ROLE}.md"

  if grep -q "DELIVERABLE_COMPLETE" "$FULL_FILE" 2>/dev/null && [[ -f "$SUMMARY_FILE" ]]; then
    # Create backward-compat symlink if not already present
    if [[ ! -e "$LEGACY_FILE" ]]; then
      ln -sf "${ROLE}.full.md" "$LEGACY_FILE" 2>/dev/null || true
    fi
    echo "LABEL=$SESSION_LABEL SESSION_ID=$SESSION_ID"
    exit 0
  elif grep -q "DELIVERABLE_COMPLETE" "$LEGACY_FILE" 2>/dev/null; then
    # Legacy single-file delivery — accept for one cycle
    echo "[claude-subsession] WARN: legacy single-file delivery detected for ${ROLE} (no .full.md/.summary.md split)" >&2
    echo "LABEL=$SESSION_LABEL SESSION_ID=$SESSION_ID"
    exit 0
  else
    # SOFT_FINISH fallback: if .full.md has substantive content but missing marker, auto-promote
    if [[ -f "$FULL_FILE" ]]; then
      size=$(wc -c < "$FULL_FILE" 2>/dev/null || echo 0)
      if [[ $size -gt 200 ]] && grep -qiE "(fixed|added|changed|implemented|diff|^\#\#)" "$FULL_FILE" 2>/dev/null; then
        echo "[claude-subsession] SOFT_FINISH detected on ${ROLE}.full.md (${size} bytes, no marker) — auto-promoting" >&2
        printf '\n\nDELIVERABLE_COMPLETE\n# auto-marker added by SOFT_FINISH fallback\n' >> "$FULL_FILE"
        [[ -f "$SUMMARY_FILE" ]] && return 0
      fi
    fi
    # Check if this failure was due to a model refusal (stop_reason='refusal').
    # Refusal exit code 2 lets callers distinguish refusal from ordinary missing-marker failures.
    if [[ "${_SUBSESSION_REFUSAL_DETECTED:-0}" == "1" ]]; then
      echo "[claude-subsession] HARD FAILURE: stop_reason=refusal detected — role=${ROLE} model=${MODEL} — no DELIVERABLE_COMPLETE written" >&2
      exit 2
    fi
    echo "[claude-subsession] no DELIVERABLE_COMPLETE in ${ROLE}.full.md (or missing .summary.md)" >&2
    exit 1
  fi
else
  _start_epoch=$(date +%s)
  run_subsession &
  PID=$!

  # W6-fix: async cost-recorder (was: background subshell may not fire if parent exits first).
  # Strategy: write a marker file so leadv2-cost-flush.sh can compute costs post-hoc even if
  # the parent shell exits before the background wait completes.
  MARKER_FILE="$HANDOFF_DIR/${ROLE}.cost-pending.yaml"
  printf -- 'session_id: %s\nrole: %s\nmodel: %s\nstream_file: %s\nstart_epoch: %s\nhandoff_dir: %s\nprompt_prefix_checksum: %s\n' \
    "$SESSION_ID" "$ROLE" "$MODEL" "$STREAM_OUT" "$_start_epoch" "$HANDOFF_DIR" "$PREFIX_CHECKSUM" > "$MARKER_FILE"

  # Still attempt inline cost record — but now a detached setsid process so it survives parent exit.
  (setsid bash -c "
    wait $PID 2>/dev/null || true
    rm -f '$MARKER_FILE'
  " 2>/dev/null || true) &
  # Inline record (fires if parent stays alive long enough)
  (
    wait "$PID" 2>/dev/null || true
    parse_and_record_cost "$STREAM_OUT" "$ROLE" "$MODEL" "$SESSION_ID" "$HANDOFF_DIR" "$_start_epoch" "$PREFIX_CHECKSUM"
    _detect_empty_session
    rm -f "$MARKER_FILE"
  ) &
  echo "PID=$PID LABEL=$SESSION_LABEL SESSION_ID=$SESSION_ID STREAM=$STREAM_OUT"
  exit 0
fi
