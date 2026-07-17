#!/usr/bin/env bash
# leadv2-quota-live.sh — Live, endpoint-backed quota for all three provider
# buckets (GLM / Codex / Anthropic). Thin Bash wrapper over leadv2-quota-read.py
# (the credential-safe Python helper). Each bucket is INDEPENDENT: one provider
# failing never blanks another. Any failure fails OPEN to "unknown" — never 0%.
#
# This SUPERSEDES the heuristic token-sum gauge (leadv2-quota-status.sh), which
# was wrong by ~99.8% because it summed history.db tokens. Here every number is
# the provider's OWN, read live from its real quota endpoint, cached briefly.
#
# Tokens are NEVER printed/logged/cached — the Python helper holds them in
# process memory only and writes only normalized percentages to the cache.
#
# Usage:
#   leadv2-quota-live.sh [report]   # human-readable, all three buckets (default)
#   leadv2-quota-live.sh json       # {"glm":...,"codex":...,"anthropic":...}
#   leadv2-quota-live.sh glm|codex|anthropic   # that bucket's JSON only
#   leadv2-quota-live.sh --no-cache [report|json|<bucket>]   # bypass cache
#
# Env (see leadv2-quota-read.py header for the full list):
#   LEADV2_QUOTA_READ  override path to the python helper (tests)
#   LEADV2_QUOTA_TTL_GLM/CODEX/ANTHROPIC  cache TTLs (default 60/120/300 s)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
READER="${LEADV2_QUOTA_READ:-"${SCRIPT_DIR}/leadv2-quota-read.py"}"

die() { printf -- '[leadv2-quota-live] %s\n' "$*" >&2; exit 2; }

read_bucket() {  # $1 = bucket name; echoes JSON, never fails (helper exits 0)
  python3 "$READER" "$1" ${NO_CACHE_FLAG:+"$NO_CACHE_FLAG"} 2>/dev/null \
    || printf -- '{"provider":"%s","status":"unknown","error":"helper crashed"}' "$1"
}

# ── formatting helpers ──────────────────────────────────────────────────────
fmt_glm() {
  local j="$1"
  local st s5 w5 sw ww lvl
  st=$(printf '%s' "$j" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d.get("status","unknown"))' 2>/dev/null)
  if [[ "$st" != "ok" ]]; then
    local err; err=$(printf '%s' "$j" | python3 -c 'import sys,json;print(str(json.load(sys.stdin).get("error",""))[:70])' 2>/dev/null)
    printf -- 'GLM (z.ai):      UNKNOWN — %s\n' "$err"
    return
  fi
  lvl=$(printf '%s' "$j" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("level") or "?")' 2>/dev/null)
  s5=$(printf '%s' "$j" | python3 -c 'import sys,json;w=json.load(sys.stdin).get("five_hour") or {};print("%s%% (resets %s)"%(w.get("pct","?"),(w.get("reset_iso") or "?")[:19]))' 2>/dev/null)
  sw=$(printf '%s' "$j" | python3 -c 'import sys,json;w=json.load(sys.stdin).get("weekly") or {};print("%s%% (resets %s)"%(w.get("pct","?"),(w.get("reset_iso") or "?")[:19]))' 2>/dev/null)
  printf -- 'GLM (z.ai, %s):  5h=%s | weekly=%s\n' "$lvl" "$s5" "$sw"
}

fmt_codex() {
  local j="$1" st pct win reset plan cred
  st=$(printf '%s' "$j" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("status","unknown"))' 2>/dev/null)
  if [[ "$st" != "ok" ]]; then
    local err; err=$(printf '%s' "$j" | python3 -c 'import sys,json;d=json.load(sys.stdin);e=str(d.get("error",""))[:70];print(e + (" — needs `codex login`" if d.get("needs_login") else ""))' 2>/dev/null)
    printf -- 'Codex (ChatGPT): UNKNOWN — %s\n' "$err"; return
  fi
  plan=$(printf '%s' "$j" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("plan_type") or "?")' 2>/dev/null)
  pct=$(printf '%s' "$j" | python3 -c 'import sys,json;w=(json.load(sys.stdin).get("windows") or [{}])[0];print("%s%% used (%s%% remaining)"%(w.get("used_percent","?"),100-(w.get("used_percent") or 0)))' 2>/dev/null)
  reset=$(printf '%s' "$j" | python3 -c 'import sys,json;w=(json.load(sys.stdin).get("windows") or [{}])[0];print((w.get("reset_iso") or "?")[:19])' 2>/dev/null)
  cred=$(printf '%s' "$j" | python3 -c 'import sys,json;c=json.load(sys.stdin).get("credits") or {};print("yes" if c.get("has_credits") else "NONE (balance %s)"%c.get("balance"))' 2>/dev/null)
  printf -- 'Codex (%s):      %s | resets %s | credits: %s\n' "$plan" "$pct" "$reset" "$cred"
}

fmt_anthropic() {
  local j="$1" st n
  st=$(printf '%s' "$j" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("status","unknown"))' 2>/dev/null)
  if [[ "$st" != "ok" ]]; then
    local err; err=$(printf '%s' "$j" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(str(d.get("error",""))[:80])' 2>/dev/null)
    printf -- 'Anthropic:       UNKNOWN — %s\n' "$err"; return
  fi
  printf '%s' "$j" | python3 -c '
import sys,json
d=json.load(sys.stdin)
for a in d.get("accounts",[]):
    print("Anthropic (%s, %s, tier=%s): 5h=%s%% | weekly=%s%%" % (
        a.get("subscription_type","?"), a.get("entry_suffix","?"), a.get("tier","?"),
        a.get("five_hour_pct","?"), a.get("seven_day_pct","?")))
' 2>/dev/null
}

# ── arg parse ────────────────────────────────────────────────────────────────
NO_CACHE_FLAG=""
MODE="report"
for a in "$@"; do
  case "$a" in
    --no-cache) NO_CACHE_FLAG="--no-cache" ;;
    report|json|glm|codex|anthropic) MODE="$a" ;;
    -h|--help)
      sed -n '3,26p' "$0"; exit 0 ;;
    *) die "unknown arg: $a" ;;
  esac
done

[[ -f "$READER" ]] || die "python helper not found: $READER"

case "$MODE" in
  glm)        read_bucket glm ;;
  codex)      read_bucket codex ;;
  anthropic)  read_bucket anthropic ;;
  json)
    g=$(read_bucket glm); c=$(read_bucket codex); an=$(read_bucket anthropic)
    python3 -c 'import json,sys; print(json.dumps({"glm":json.loads(sys.argv[1]),"codex":json.loads(sys.argv[2]),"anthropic":json.loads(sys.argv[3])},indent=2))' "$g" "$c" "$an"
    ;;
  report|*)
    echo "=== leadv2 live quota (provider-owned numbers) ==="
    echo "GLM-CODER-BUCKET   WINDOW-STATE"
    fmt_glm "$(read_bucket glm)"
    fmt_codex "$(read_bucket codex)"
    fmt_anthropic "$(read_bucket anthropic)"
    echo "  (unknown = read failed; never reported as 0%. Per-bucket TTL cache: GLM 60s / Codex 120s / Anthropic 300s.)"
    ;;
esac
