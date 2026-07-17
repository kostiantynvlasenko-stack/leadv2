#!/usr/bin/env bash
# leadv2-glm-quota-gate.sh — pre-launch quota gate for GLM lanes.
#
# Read the live GLM (z.ai) percentage before a lane starts. Rules (founder,
# 2026-07-17):
#   §1  ≥THRESHOLD (default 80) on EITHER the 5h OR the weekly window  ⇒  REROUTE
#       (not stop). Exit non-zero AND print the reroute: current % on both
#       windows, human-readable reset time, and the preferred fallback bucket.
#       Intent: "at 80%, fall back to Codex + Anthropic so the persona's work
#       never suffers." Dev work continues on another bucket; only GLM headroom
#       is protected. (The Respiro engine shares this exact account with no
#       provider fallback — the headroom is the persona's, not ours.)
#   §2  Peak awareness. GLM-5.2 costs 3× during 14:00–18:00 UTC+8 = 06:00–10:00
#       UTC. In peak: warn loudly and require GLM_ALLOW_PEAK=1 (not a hard
#       block — a genuine P0 must still run). Prints time until peak ends.
#   §3  Fail OPEN on the gate's OWN failure (network down, 500, malformed JSON):
#       log the error visibly to stderr and ALLOW the lane. A quota gate that
#       wedges all work on a z.ai blip is worse than no gate. Never 2>/dev/null.
#   §4  ~60 s cache lives in the python helper (leadv2-quota-read.py).
#
# Exit codes: 0 = lane may start (GLM headroom OK); non-zero = do NOT start the
# GLM lane — reroute / override per the message on stderr.
#
# Env:
#   GLM_QUOTA_THRESHOLD   reroute threshold pct (default 80; set low to test)
#   GLM_SKIP_QUOTA_GATE=1 bypass entirely (emergencies) — logs to stderr
#   GLM_ALLOW_PEAK=1      allow launching during peak hours (P0 override)
#   GLM_SIMULATE_UTC_HOUR 0-23  force the clock for testing peak behavior
#   LEADV2_QUOTA_LIVE     override path to leadv2-quota-live.sh (tests)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIVE="${LEADV2_QUOTA_LIVE:-"${SCRIPT_DIR}/leadv2-quota-live.sh"}"
THRESHOLD="${GLM_QUOTA_THRESHOLD:-80}"

warn() { printf -- '[glm-quota-gate] %s\n' "$*" >&2; }
info() { printf -- '[glm-quota-gate] %s\n' "$*"; }

# Bypass (emergencies). Logged — never silent.
if [[ "${GLM_SKIP_QUOTA_GATE:-0}" == "1" ]]; then
  warn "GLM_SKIP_QUOTA_GATE=1 — bypassing quota gate (emergency). Lane may start."
  exit 0
fi

if [[ ! -x "$LIVE" && ! -f "$LIVE" ]]; then
  # Fail OPEN: gate infrastructure missing → allow, log visibly.
  warn "FAIL-OPEN: quota-live helper missing ($LIVE). Lane may start."
  exit 0
fi

# ── peak detection (pure clock, no network) ──────────────────────────────────
# GLM peak: 06:00–10:00 UTC (14:00–18:00 UTC+8). Hours 6,7,8,9.
cur_hour="${GLM_SIMULATE_UTC_HOUR:-$(date -u +%H)}"
# strip leading zero
cur_hour=$((10#${cur_hour}))
in_peak=0
if (( cur_hour >= 6 && cur_hour < 10 )); then in_peak=1; fi
peak_ends_at="10:00 UTC"
mins_until_peak_ends=$(( (10 - cur_hour) * 60 - $(date -u +%M) ))
(( mins_until_peak_ends < 0 )) && mins_until_peak_ends=0

# ── live GLM read (fails open on any error) ──────────────────────────────────
glm_json="$("$LIVE" glm 2>/tmp/glm-gate-stderr.$$)"
rc=$?
gate_err="$(cat /tmp/glm-gate-stderr.$$ 2>/dev/null)"; rm -f /tmp/glm-gate-stderr.$$

if [[ $rc -ne 0 ]]; then
  # §3 fail-open on the gate's own failure.
  warn "FAIL-OPEN: quota-live exited $rc (${gate_err:-no stderr}). Lane may start."
  exit 0
fi

# Parse with python (stdlib). Status must be ok; anything else = fail-open.
parsed="$(printf '%s' "$glm_json" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception as e:
    print(json.dumps({"_parse_error": str(e)})); sys.exit(0)
if d.get("status") != "ok":
    print(json.dumps({"_unknown": str(d.get("error",""))[:120]})); sys.exit(0)
fh = d.get("five_hour") or {}; wk = d.get("weekly") or {}
print(json.dumps({"five_pct": fh.get("pct"), "five_reset": (fh.get("reset_iso") or "")[:19],
                  "wk_pct": wk.get("pct"), "wk_reset": (wk.get("reset_iso") or "")[:19]}))
' 2>/dev/null)"

if [[ -z "$parsed" ]]; then
  warn "FAIL-OPEN: quota-live produced no parseable output. Lane may start."
  exit 0
fi
if printf '%s' "$parsed" | grep -q '"_parse_error"'; then
  warn "FAIL-OPEN: malformed GLM JSON ($(printf '%s' "$parsed" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("_parse_error",""))')). Lane may start."
  exit 0
fi
if printf '%s' "$parsed" | grep -q '"_unknown"'; then
  # GLM read itself reported unknown (network/auth/endpoint). §3 fail-open.
  uerr="$(printf '%s' "$parsed" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("_unknown",""))')"
  warn "FAIL-OPEN: GLM quota read is unknown (${uerr}). Cannot gate on a number we do not have — lane may start."
  exit 0
fi

five_pct="$(printf '%s' "$parsed" | python3 -c 'import sys,json;print(json.load(sys.stdin)["five_pct"])' 2>/dev/null)"
wk_pct="$(printf '%s' "$parsed" | python3 -c 'import sys,json;print(json.load(sys.stdin)["wk_pct"])' 2>/dev/null)"
five_reset="$(printf '%s' "$parsed" | python3 -c 'import sys,json;print(json.load(sys.stdin)["five_reset"])' 2>/dev/null)"
wk_reset="$(printf '%s' "$parsed" | python3 -c 'import sys,json;print(json.load(sys.stdin)["wk_reset"])' 2>/dev/null)"
five_pct="${five_pct:-0}"; wk_pct="${wk_pct:-0}"

# ── §1 quota reroute check ───────────────────────────────────────────────────
if (( five_pct >= THRESHOLD || wk_pct >= THRESHOLD )); then
  tripped=""
  (( five_pct >= THRESHOLD )) && tripped="5h=${five_pct}% (resets ${five_reset}Z)"
  (( wk_pct >= THRESHOLD )) && tripped="${tripped:+$tripped AND }weekly=${wk_pct}% (resets ${wk_reset}Z)"
  cat >&2 <<EOF
[glm-quota-gate] REROUTE — GLM quota ≥ ${THRESHOLD}% on: ${tripped}.
  The GLM bucket is low; protect its headroom by running this work elsewhere.
  Fallback preference (SNAPSHOT 2026-07-17 — verify with leadv2-quota-live.sh):
    1. Sonnet via Anthropic Max (was the most comfortable bucket today).
    2. Codex only sparingly (scarcest: 0 credits, resets ~Jul 23) and only at
       --tier standard/volume per CODEX-TIER-DISCIPLINE-01.
  NOTE: the leadv2-glm-first-agent-gate.sh hook currently DENIES Sonnet
  code-writer spawns. To follow this reroute, the spawn must carry the approved
  exception id: glm_quota_gate_80  (being added in parallel). Until then, route
  via leadv2-router.sh / leadv2-supervise.sh which honor the same id.
EOF
  exit 1
fi

# ── §2 peak awareness ────────────────────────────────────────────────────────
if (( in_peak )); then
  if [[ "${GLM_ALLOW_PEAK:-0}" != "1" ]]; then
    cat >&2 <<EOF
[glm-quota-gate] PEAK HOURS — GLM-5.2 costs 3× during 06:00–10:00 UTC (14:00–18:00 UTC+8).
  Peak ends in ~${mins_until_peak_ends} min (at ${peak_ends_at}). Quota is fine
  (5h=${five_pct}% / weekly=${wk_pct}%) but the 3× cost multiplier is in effect.
  For a genuine P0: re-run with GLM_ALLOW_PEAK=1. Otherwise wait until ${peak_ends_at}.
EOF
    exit 2
  fi
  warn "PEAK OVERRIDE active (GLM_ALLOW_PEAK=1): running at 3× cost. Peak ends in ~${mins_until_peak_ends} min. Quota OK (5h=${five_pct}% / weekly=${wk_pct}%)."
fi

# ── allow ────────────────────────────────────────────────────────────────────
info "OK — GLM quota has headroom: 5h=${five_pct}% (resets ${five_reset}Z) / weekly=${wk_pct}% (resets ${wk_reset}Z). Threshold=${THRESHOLD}%. Lane may start."
exit 0
