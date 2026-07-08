#!/usr/bin/env bash
# leadv2-strict.sh — FAIL-LOUD-FLAGS-01 shared strict-mode helper.
#
# Sourceable. Provides strict_or_warn <point-id> <message> — the single choke
# point that converts a CURATED set of silent-degrade spots (flag-on-but-
# artifact-missing, swallowed-error-vs-legitimate-empty) into a loud, visible
# failure, gated behind LEADV2_REQUIRE_STRICT.
#
# Usage at a chosen degrade point:
#   if ! strict_or_warn "<point-id>" "<human-readable message>"; then
#     exit 1   # or: return 1 — caller decides how loud "loud" is
#   fi
#
# LEADV2_REQUIRE_STRICT=0 (default, UNSET counts as 0):
#   strict_or_warn prints NOTHING and returns 0 unconditionally. This file
#   must NEVER change default-mode output/exit-code for any caller — that is
#   the byte-identical contract this whole feature depends on.
#
# LEADV2_REQUIRE_STRICT=1:
#   strict_or_warn prints one line to stderr:
#     STRICT-FAIL[<point-id>]: <message>
#   and returns 1, so the caller can turn it into an `exit 1` / hard failure.
#
# CRITICAL — do NOT wire this into:
#   - T3 (MEM-SEMANTIC-RECALL-01) runtime fail-open paths: Qdrant unreachable,
#     embed helper crash, malformed response. Those must stay silent/fail-open
#     in ALL modes (strict or not) — they are transient runtime conditions,
#     not misconfiguration.
#   - T4 (REFLECT-CAUSAL-CRITIQUE-01) try/catch fail-open skip object. Same
#     reasoning — an agent()/bash() exception there is a runtime condition,
#     not a misconfigured enabling flag.
# The ONLY class of degrade point this helper targets is: "an enabling flag
# is ON, but the artifact/config it depends on is missing or the loader that
# backs it crashed" — i.e. genuine misconfiguration that should surface in
# CI/soak, never a legitimate/transient fail-open outcome.
#
# lean: no severity levels / no structured log sink — a single stderr line is
# enough for CI/soak grep today. Upgrade to a JSON sink (e.g.
# docs/leadv2/strict-violations.jsonl) when a caller needs to swallow this
# script's own stderr (e.g. via `2>/dev/null`) and strict mode still needs to
# be observable — see FAIL-LOUD-FLAGS-01 build.md "known limitation".
strict_or_warn() {
  local point_id="${1:?strict_or_warn: point-id required}"
  local msg="${2:-}"
  [[ "${LEADV2_REQUIRE_STRICT:-0}" == "1" ]] || return 0
  printf -- 'STRICT-FAIL[%s]: %s\n' "$point_id" "$msg" >&2
  return 1
}
