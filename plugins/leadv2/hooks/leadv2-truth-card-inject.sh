#!/usr/bin/env bash
# SessionStart hook: pull persona_truth_card from Supabase, inject as additionalContext.
# Spec: docs/handoff/ANTI-AMNESIA-01/design.md §2A §2B §3C
#
# Staleness rules (as_of age):
#   <2h  -> [FRESH]
#   2-6h -> [STALE: last seen Nh ago]
#   >6h  -> [STALE-CRITICAL: engine may be down]
#   no row -> [NO TRUTH CARD]
#
# On Supabase failure: injects failure notice. NEVER falls back to disk caches.
# Non-blocking: exits 0 always. curl max-time 5s.
set -euo pipefail
export PYTHONWARNINGS="ignore::DeprecationWarning"  # LEAD-ANCHOR-01: never let py warnings hit stderr as a hook error
trap 'exit 0' ERR

INPUT="$(python3 -c "import sys; print(sys.stdin.read())" 2>/dev/null || true)"

CWD="$(printf -- '%s' "$INPUT" | python3 -c "import sys,json; d=json.loads(sys.stdin.read() or '{}'); print(d.get('cwd',''))" 2>/dev/null || true)"
[[ -z "$CWD" ]] && CWD="${CLAUDE_PROJECT_DIR:-${PWD:-}}"
printf '%s|invoked|cwd=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${CWD:-?}" >> /tmp/leadv2-truth-card-inject.log 2>/dev/null || true

# ---- Resolve persona slug (slug only -- UUID is rejected) ---------------
_SP_YAML="${CWD}/.claude/leadv2-overrides/state-paths.yaml"
PERSONA_SLUG=""
_read_slug_from_yaml() {
  local yaml_path="$1"
  [[ -f "$yaml_path" ]] || return 0
  grep -E "^[[:space:]]*persona_id[[:space:]]*:" "$yaml_path" 2>/dev/null \
    | head -1 \
    | sed -E "s/^[[:space:]]*persona_id[[:space:]]*:[[:space:]]*//" \
    | sed -E "s/^['\"']//; s/['\"'][[:space:]]*$//" \
    | tr -d '\r' || true
}
PERSONA_SLUG="$(_read_slug_from_yaml "$_SP_YAML")"

# Worktree fallback: if CWD is inside .claude/worktrees/, the state-paths.yaml
# there may not have persona_id. Resolve main repo root via --git-common-dir
# (returns <main>/.git for any linked worktree) and read its state-paths.yaml.
if [[ -z "$PERSONA_SLUG" || "$PERSONA_SLUG" == "null" ]]; then
  _GIT_COMMON_DIR="$(git -C "$CWD" rev-parse --git-common-dir 2>/dev/null || true)"
  if [[ -n "$_GIT_COMMON_DIR" && "$_GIT_COMMON_DIR" != ".git" ]]; then
    # --git-common-dir returns absolute path to <main-repo>/.git; strip /.git suffix
    _MAIN_ROOT="${_GIT_COMMON_DIR%/.git}"
    _MAIN_SP_YAML="${_MAIN_ROOT}/.claude/leadv2-overrides/state-paths.yaml"
    _FALLBACK_SLUG="$(_read_slug_from_yaml "$_MAIN_SP_YAML")"
    if [[ -n "$_FALLBACK_SLUG" && "$_FALLBACK_SLUG" != "null" ]]; then
      PERSONA_SLUG="$_FALLBACK_SLUG"
      printf '%s|worktree-fallback|main_root=%s|slug=%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_MAIN_ROOT" "$PERSONA_SLUG" \
        >> /tmp/leadv2-truth-card-inject.log 2>/dev/null || true
    fi
  fi
fi

[[ -z "$PERSONA_SLUG" || "$PERSONA_SLUG" == "null" ]] && PERSONA_SLUG="${PERSONA_ID:-}"
# Reject UUID-shaped values -- canonical key is slug.
if printf -- '%s' "$PERSONA_SLUG" | grep -qE '^[0-9a-f]{8}-'; then PERSONA_SLUG=""; fi

if [[ -z "$PERSONA_SLUG" ]]; then
  printf '{}'; exit 0
fi

# ---- Supabase credentials from .env -------------------------------------
_ENV_FILE="${CWD}/.env"
SUPABASE_URL=""
SUPABASE_SERVICE_ROLE_KEY=""
if [[ -f "$_ENV_FILE" ]]; then
  SUPABASE_URL="$(grep -E "^SUPABASE_URL[[:space:]]*=" "$_ENV_FILE" 2>/dev/null | head -1 | sed -E "s/^SUPABASE_URL[[:space:]]*=[[:space:]]*//" | tr -d "'\"\r" || true)"
  SUPABASE_SERVICE_ROLE_KEY="$(grep -E "^SUPABASE_SERVICE_ROLE_KEY[[:space:]]*=" "$_ENV_FILE" 2>/dev/null | head -1 | sed -E "s/^SUPABASE_SERVICE_ROLE_KEY[[:space:]]*=[[:space:]]*//" | tr -d "'\"\r" || true)"
fi
if [[ -z "$SUPABASE_URL" || -z "$SUPABASE_SERVICE_ROLE_KEY" ]]; then
  python3 -c "import json; print(json.dumps({'additionalContext': '[TRUTH CARD FAILED] Supabase credentials not found in .env. Run /persona-state to retry after credentials are available.'}))"
  exit 0
fi

# ---- Pull single row from persona_truth_card ----------------------------
SAFE_SLUG="$(printf -- '%s' "$PERSONA_SLUG" | tr -cd 'A-Za-z0-9._-')"
[[ -z "$SAFE_SLUG" ]] && exit 0

RAW_RESPONSE="$(curl --silent --max-time 5 \
  -H "apikey: ${SUPABASE_SERVICE_ROLE_KEY}" \
  -H "Authorization: Bearer ${SUPABASE_SERVICE_ROLE_KEY}" \
  -H "Accept: application/json" \
  "${SUPABASE_URL}/rest/v1/persona_truth_card?persona_slug=eq.${SAFE_SLUG}&select=*&limit=1" 2>/dev/null || true)"

# ---- Format and emit additionalContext -------------------------------------
# M3: pass RAW_RESPONSE via a temp file, not as argv (avoids ARG_MAX + quote injection).
# P0 portable-temp fix (leadv2 0.2): BSD/macOS mktemp requires the XXXXXX run to
# be the trailing component of the template — a literal ".json" suffix after it
# is NOT randomized on BSD, causing deterministic collisions. Drop the suffix
# (this is a throwaway scratch file consumed by path, not by extension) and log
# loudly on failure instead of letting the ERR trap above fail-open silently.
DATA_FILE="$(mktemp "${TMPDIR:-/tmp}/lv2-tc-data.XXXXXX")" || {
  printf '%s|card-emit-error|mktemp failed, aborting truth-card inject\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> /tmp/leadv2-truth-card-inject.log 2>/dev/null || true
  exit 0
}
trap 'rm -f "$DATA_FILE"' EXIT
printf -- '%s' "$RAW_RESPONSE" > "$DATA_FILE"

printf '%s|card-emit|slug=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$PERSONA_SLUG" >> /tmp/leadv2-truth-card-inject.log 2>/dev/null || true
python3 - "$PERSONA_SLUG" "$DATA_FILE" << 'RUN_FMT'
import sys, json, datetime, os

slug     = sys.argv[1]
data_fp  = sys.argv[2]

def fail(r):
    return json.dumps({'additionalContext':
        '[TRUTH CARD FAILED] persona=' + slug + ' reason=' + r +
        '\nAction: run /persona-state to retry. NEVER use disk caches.'})

def age(s):
    try:
        t = datetime.datetime.fromisoformat(s.replace('Z', '+00:00'))
        h = (datetime.datetime.now(datetime.timezone.utc) - t).total_seconds() / 3600
        if h < 2:
            return '[FRESH -- as_of: ' + s + ']'
        elif h < 6:
            return '[STALE: last seen ' + f'{h:.1f}h ago -- as_of: ' + s + ']'
        else:
            return '[STALE-CRITICAL: engine may be down (' + f'{h:.1f}h ago) -- as_of: ' + s + ']'
    except Exception:
        return '[STALE: cannot parse as_of ' + s + ']'

try:
    with open(data_fp) as fh:
        raw = fh.read()
except Exception as e:
    print(fail('cannot read data file: ' + str(e)))
    sys.exit(0)

if not raw.strip():
    print(fail('empty response'))
    sys.exit(0)

try:
    rows = json.loads(raw)
except Exception as e:
    print(fail('invalid JSON: ' + str(e)))
    sys.exit(0)

if isinstance(rows, dict) and 'message' in rows:
    print(fail('Supabase error: ' + rows['message'][:120]))
    sys.exit(0)

if not isinstance(rows, list) or not rows:
    print(json.dumps({'additionalContext':
        '[NO TRUTH CARD] No row for ' + slug +
        '. Run one cycle with pe_truth_card_write() wired, then /persona-state.'}))
    sys.exit(0)

r   = rows[0]
hdr = age(r.get('as_of', 'unknown'))
f   = lambda v: '--' if v is None or v == '' else str(v)
fb  = lambda v: 'ON' if v is True or v == 'true' else ('OFF' if v is False or v == 'false' else f(v))
flags = r.get('active_flags') or {}
if isinstance(flags, str):
    try:
        flags = json.loads(flags)
    except Exception:
        flags = {}
fs = ', '.join(
    k + '=' + ('ON' if (v.get('on') if isinstance(v, dict) else v) else 'OFF')
    for k, v in sorted(flags.items())
) if flags else '(none)'

lines = [
    '=== PERSONA TRUTH CARD: ' + slug + ' ===',
    hdr, '',
    'ENGINE STATE',
    '  RUN_MODE:             ' + f(r.get('run_mode')),
    '  CONTROL_MODE:         ' + f(r.get('control_mode')),
    '  V4_DETERMINISTIC:     ' + fb(r.get('v4_deterministic')),
    '  LLM_BACKEND:          ' + f(r.get('llm_backend')),
    '  ACTIVE_FLAGS:         ' + fs, '',
    'LAST ACTIVITY',
    '  Last post media_id:   ' + f(r.get('last_post_media_id')),
    '  Last post timestamp:  ' + f(r.get('last_post_ts')),
    '  Last post slug:       ' + f(r.get('last_post_slug')),
    '  Last comment graph_id:' + f(r.get('last_comment_graph_id')),
    '  Last comment ts:      ' + f(r.get('last_comment_ts')), '',
    'PIPELINE HEALTH',
    '  Post count (7d):      ' + f(r.get('post_count_7d')),
    '  Defer queue depth:    ' + f(r.get('defer_queue_depth')),
    '  Pending proposals:    ' + f(r.get('pending_proposals')),
    '  NMC count (new):      ' + f(r.get('nmc_count')),
    '  Bandit updates:       ' + f(r.get('bandit_updates')), '',
    'WORKING HOURS',
    '  Schedule:             ' + f(r.get('working_hours_json')),
    '  Auth cookie mtime:    ' + f(r.get('auth_cookie_mtime')), '',
    "VERIFICATION RULES (hardcoded -- NEVER use status=confirmed alone)",
    "  Posts:    action_log WHERE action_type='post' AND context->>'media_id' IS NOT NULL",
    "  Comments: action_log WHERE action_type='comment' AND metadata->>'graph_id' IS NOT NULL",
    '=== END TRUTH CARD ===',
]
print(json.dumps({'additionalContext': '\n'.join(lines)}))
RUN_FMT

exit 0
