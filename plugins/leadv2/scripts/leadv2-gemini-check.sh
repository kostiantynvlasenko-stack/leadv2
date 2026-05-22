#!/bin/bash
# leadv2-gemini-check.sh — capability probe for Antigravity CLI (Gemini 3.5 Flash)
#
# Usage:
#   if bash leadv2-gemini-check.sh; then GEMINI_OK=1; else GEMINI_OK=0; fi
#
# Exit codes:
#   0 — agy binary found AND responds to --print within probe timeout
#   1 — agy not installed (Antigravity CLI missing)
#   2 — agy installed but health probe failed (auth/quota/network)
#
# Stdout (on success): version line. On failure: short diagnostic.
# Stderr: full diagnostic.
#
# Cost: one cached prompt (~5 tokens) per probe. Cache the result in caller scope.
set -uo pipefail

PROBE_TIMEOUT="${GEMINI_PROBE_TIMEOUT:-15}"

# 1. Locate agy on PATH or default install location.
AGY_BIN=""
if command -v agy >/dev/null 2>&1; then
  AGY_BIN="$(command -v agy)"
elif [[ -x "$HOME/.local/bin/agy" ]]; then
  AGY_BIN="$HOME/.local/bin/agy"
else
  echo "agy: not found" >&2
  exit 1
fi

# 2. Health probe — minimal prompt, short timeout. agy default model = Gemini 3.5 Flash.
# DO NOT pass --print-timeout: that flag triggers tool-use exploration in agy 1.0.1.
# Use shell `timeout` only.
PROBE_OUT="$(timeout "$PROBE_TIMEOUT" "$AGY_BIN" --print "Reply with the single word: pong" 2>&1)" || {
  echo "agy: health probe failed (exit=$?)" >&2
  echo "$PROBE_OUT" | head -5 >&2
  exit 2
}

# 3. Sanity check on output.
if [[ -z "$PROBE_OUT" ]]; then
  echo "agy: empty response" >&2
  exit 2
fi

echo "agy: ok ($AGY_BIN)"
exit 0
