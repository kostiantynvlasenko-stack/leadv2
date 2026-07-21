#!/usr/bin/env bash
# Deterministic provider/model router tests. All provider and quota probes are
# stubbed; this suite never calls a real model or consumes subscription quota.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROUTER="${SCRIPT_DIR}/../leadv2-session-route.sh"
PASS=0
FAIL=0
ERRORS=()
SANDBOX="$(mktemp -d /tmp/leadv2-route-test-XXXXXX)"
trap 'rm -rf "$SANDBOX"' EXIT

pass() { PASS=$((PASS + 1)); printf -- '[TEST] PASS: %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); ERRORS+=("$1"); printf -- '[TEST] FAIL: %s\n' "$1"; }

CODEX_STUB="$SANDBOX/codex"
QUOTA_STUB="$SANDBOX/quota"

cat > "$CODEX_STUB" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "login" && "${2:-}" == "status" ]]; then
  exit 0
fi
exit 0
STUB

cat > "$QUOTA_STUB" <<'STUB'
#!/usr/bin/env bash
printf -- '%s\n' "${TEST_QUOTA_JSON:-}"
STUB
chmod +x "$CODEX_STUB" "$QUOTA_STUB"

route() {
  TEST_QUOTA_JSON="${TEST_QUOTA_JSON:-}" \
  LEADV2_CODEX_BIN="$CODEX_STUB" \
  LEADV2_CODEX_SKILL_READY=1 \
  LEADV2_QUOTA_LIVE="$QUOTA_STUB" \
    "$ROUTER" "$@"
}

assert_fields() {
  local name="$1" output="$2"
  shift 2
  local expected
  for expected in "$@"; do
    if [[ "$output" != *"$expected"* ]]; then
      fail "$name missing '$expected' in: $output"
      return
    fi
  done
  pass "$name"
}

if bash -n "$ROUTER"; then
  pass "router syntax"
else
  fail "router syntax"
fi

TEST_QUOTA_JSON='{"codex":{"windows":[{"used_percent":20}]},"anthropic":{"accounts":[{"five_hour_pct":50,"seven_day_pct":40}]}}'
out="$(route --class Standard --provider auto)"
assert_fields "routine Standard -> Codex Terra" "$out" \
  'provider=codex' 'model=gpt-5.6-terra' 'effort=medium' 'codex_used_percent=20'

out="$(route --class Light --provider auto)"
assert_fields "Light -> Codex Luna" "$out" \
  'provider=codex' 'model=gpt-5.6-luna' 'effort=low'

out="$(route --class Heavy --provider auto)"
assert_fields "Heavy -> Claude Opus" "$out" \
  'provider=claude' 'model=opus' 'effort=high' 'high_risk=true'

out="$(route --class Standard --risk-tags auth --provider codex)"
assert_fields "high-risk tag blocks explicit Codex" "$out" \
  'provider=claude' 'model=opus' 'high_risk=true'

TEST_QUOTA_JSON='{"codex":{"windows":[{"used_percent":90}]}}'
out="$(route --class Standard --provider auto)"
assert_fields "Codex quota threshold -> Claude fallback" "$out" \
  'provider=claude' 'model=sonnet' 'codex_used_percent=90' 'reached policy threshold'

TEST_QUOTA_JSON='{}'
out="$(LEADV2_CODEX_BIN="$SANDBOX/missing-codex" LEADV2_CODEX_SKILL_READY=1 \
  LEADV2_QUOTA_LIVE="$QUOTA_STUB" "$ROUTER" --class Standard --provider auto)"
assert_fields "missing Codex CLI -> Claude fallback" "$out" \
  'provider=claude' 'model=sonnet' 'codex binary unavailable'

out="$(route --class Standard --provider claude)"
assert_fields "explicit Claude override" "$out" \
  'provider=claude' 'model=sonnet' 'explicit provider override: claude'

printf -- '[TEST] Results: PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
  printf -- '[TEST] %s\n' "${ERRORS[@]}"
  exit 1
fi
