#!/bin/bash
# leadv2-mission-lint.sh — reject mission files >100 lines or that duplicate context.yaml.
# Mission must orient + delegate, not re-spec. Source-of-truth lives in context.yaml.
#
# Usage: leadv2-mission-lint.sh <mission-file>
# Exit 0 = pass. Exit 2 = too long. Exit 3 = looks like context dup.

set -euo pipefail

# shellcheck source=leadv2-helpers.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/leadv2-helpers.sh"

MAX_LINES="${LEADV2_MISSION_MAX_LINES:-100}"
file="${1:?usage: $0 <mission-file>}"
[[ -f "$file" ]] || { echo "[mission-lint] missing: $file" >&2; exit 1; }

lines=$(wc -l <"$file" | tr -d ' ')
if [[ "$lines" -gt "$MAX_LINES" ]]; then
  echo "MISSION_TOO_LONG file=$file lines=$lines max=$MAX_LINES"
  echo "→ keep mission ≤${MAX_LINES} lines. Move spec content to context.yaml; reference it: 'see docs/handoff/<id>/context.yaml §plan.steps'"
  exit 2
fi

# Heuristic: missions usually shouldn't contain top-level YAML keys that belong in context.yaml
# Use grep -qE + counter to avoid grep -c's exit-1-on-no-match (which trips pipefail+set-e).
context_keys="^(decisions|off_limits|plan|verification|risks|prior_art):"
hits=0
while IFS= read -r _line; do hits=$((hits+1)); done < <(grep -E "$context_keys" "$file" 2>/dev/null || true)
if [[ "$hits" -ge 2 ]]; then
  echo "MISSION_LOOKS_LIKE_CONTEXT_DUP file=$file context_keys=$hits"
  echo "→ remove duplicated context.yaml sections. Reference instead."
  exit 3
fi

# SQL/migration routing guard (PO-030 lesson): missions touching .sql or migrations
# must be assigned to postgres-pro, never frontend-developer or developer. Other roles
# miss Postgres conventions (REVOKE PUBLIC, search_path lock, jsonb_set NULL guards).
# Use `|| true` to avoid pipefail killing the script on no-match (grep -E exits 1).
sql_signal=$( { grep -qE '\.sql\b|supabase/migrations/|jsonb_set|SECURITY DEFINER|CREATE OR REPLACE FUNCTION' "$file" 2>/dev/null && echo 1; } || echo 0 )
non_pg_role=$( { grep -qE '^# (PO|task|mission)[^—]*— (developer|frontend-developer|devops-engineer)\b|owner: *(developer|frontend-developer|devops-engineer)\b' "$file" 2>/dev/null && echo 1; } || echo 0 )
if [[ "$sql_signal" -eq 1 && "$non_pg_role" -eq 1 ]]; then
  echo "MISSION_SQL_NEEDS_POSTGRES_PRO file=$file"
  echo "→ migrations and .sql work go to postgres-pro. Other roles miss REVOKE PUBLIC, search_path, jsonb_set NULL guards. Re-route or split mission."
  exit 4
fi

# PostgREST PATCH on JSONB guard (NM-05): missions instructing PATCH on personas.config
# silently replace the entire JSONB column — partial-update intent causes full data-loss.
# Use jsonb_set() via psql or Supabase RPC instead.
# Only active when stack.yaml db == supabase (PE uses supabase; non-supabase repos skip).
_lv2_db=$(_lv2_stack_scalar db "")
if [[ "$_lv2_db" == "supabase" ]]; then
  patch_signal=$( { grep -qiE '\bPATCH\b' "$file" 2>/dev/null && echo 1; } || echo 0 )
  personas_signal=$( { grep -qiE '\bpersona(s(\.config)?)?\b' "$file" 2>/dev/null && echo 1; } || echo 0 )
  if [[ "$patch_signal" -eq 1 && "$personas_signal" -eq 1 ]]; then
    echo "MISSION_JSONB_PATCH_RISK file=$file"
    echo "→ PostgREST PATCH replaces the entire JSONB column (NM-05). Use jsonb_set() via psql or Supabase RPC for partial updates to personas.config."
    exit 5
  fi
fi

# [CODEMAP-CONTEXT-01, fix-round-1 #5] Real Build-side enforcement (not prose-only): if
# LEADV2_CODEMAP=1 and the sibling context.yaml has a non-empty code_map, this mission file
# MUST carry it forward under a '## Graph context' heading (per mission-template.md / the
# subagent protocol §2/§6.5) — otherwise Build-phase subagents silently re-discover the repo
# instead of reusing the already-fetched map. Flag-gated + fail-open + default-off
# byte-identical: LEADV2_CODEMAP unset/0 => this whole block never runs (identical to
# pre-CODEMAP-CONTEXT-01 mission-lint behavior). Any error reading/parsing context.yaml, or
# code_map simply absent, is a silent no-op — this check never blocks on a dependency it
# doesn't own.
if [[ "${LEADV2_CODEMAP:-0}" == "1" ]]; then
  _cm_ctx_file="$(dirname "$file")/context.yaml"
  if [[ -f "$_cm_ctx_file" ]]; then
    _cm_has_code_map=$(python3 -c "
import yaml, sys
try:
    d = yaml.safe_load(open('$_cm_ctx_file')) or {}
except Exception:
    d = {}
v = d.get('code_map')
print('1' if isinstance(v, str) and v.strip() else '0')
" 2>/dev/null || echo "0")
    if [[ "$_cm_has_code_map" == "1" ]] && ! grep -q '^## Graph context' "$file" 2>/dev/null; then
      echo "MISSION_MISSING_GRAPH_CONTEXT file=$file"
      echo "→ context.yaml.code_map is present (LEADV2_CODEMAP=1) but this mission file has no '## Graph context' heading. Copy context.yaml's code_map verbatim under a '## Graph context' heading before spawning (see mission-template.md)."
      exit 6
    fi
  fi
fi

exit 0
