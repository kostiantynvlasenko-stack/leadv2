#!/usr/bin/env bash
# Offline test for Opus selection and provider-owned quota fallback.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/leadv2-temp.sh"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$TEST_DIR/../leadv2-main-model-check.sh"
ROOT="$(lv2_mktemp_dir "leadv2-main-model-test")"
trap 'rm -rf "$ROOT"' EXIT
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf -- '[TEST] PASS: %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf -- '[TEST] FAIL: %s\n' "$1"; }

mkdir -p "$ROOT/project/.claude/ref"
QUOTA="$ROOT/quota"
cat > "$QUOTA" <<'STUB'
#!/usr/bin/env bash
if [[ -n "${TEST_ANTHROPIC_QUOTA:-}" ]]; then
  printf -- '%s\n' "$TEST_ANTHROPIC_QUOTA"
else
  printf -- '{}\n'
fi
STUB
chmod +x "$QUOTA"

plain="$(PROJECT_ROOT="$ROOT/project" LEADV2_QUOTA_LIVE="$QUOTA" "$CHECK" 2>/dev/null)"
if [[ "$plain" == "sonnet" ]]; then
  pass "missing config defaults ordinary lead to Sonnet"
else
  fail "missing config default=$plain"
fi

forced="$(TEST_ANTHROPIC_QUOTA='{"status":"ok","accounts":[{"five_hour_pct":20,"seven_day_pct":30}]}' \
  PROJECT_ROOT="$ROOT/project" LEADV2_QUOTA_LIVE="$QUOTA" LEADV2_FORCE_OPUS_LEAD=1 \
  "$CHECK" 2>/dev/null)"
if [[ "$forced" == "opus" ]]; then
  pass "explicit Opus lead survives guardrails with live quota headroom"
else
  fail "forced Opus result=$forced"
fi

fallback="$(TEST_ANTHROPIC_QUOTA='{"status":"ok","accounts":[{"five_hour_pct":96,"seven_day_pct":40}]}' \
  PROJECT_ROOT="$ROOT/project" LEADV2_QUOTA_LIVE="$QUOTA" LEADV2_FORCE_OPUS_LEAD=1 \
  "$CHECK" 2>/dev/null)"
if [[ "$fallback" == "sonnet" ]]; then
  pass "Opus falls back to Sonnet at the live provider quota threshold"
else
  fail "quota fallback result=$fallback"
fi

printf -- '[TEST] Results: PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
