#!/usr/bin/env bash
# /tmp helper (NOT shipped) — drives the EXACT cache-sync body
# leadv2-plugin-sync.sh runs for one subdir, in a sandboxed subprocess, so the
# quarantine-then-reconcile test exercises the real _direction_safety_excludes
# + rsync reconcile path end-to-end without touching the live trees.
# Args: $1 plugin_sync_path  $2 canonical_scripts_root  $3 src/  $4 dst
set -uo pipefail
plugin_sync="$1"; scripts_root="$2"; src="$3"; dst="$4"
set --   # clear positional params: plugin-sync.sh's sourced top-level arg
         # parser would otherwise see these and exit 2 ("Unknown arg") before
         # the cache loop ever runs (same fix as the _vs_call test harness).
# Source only the function-definitions portion (before the top-level body at
# "changed_summary=()"), exactly like the existing _vs_call test harness.
cutoff_line="$(grep -n "^changed_summary=()" "${plugin_sync}" | head -1 | cut -d: -f1)"
cutoff_line="$((cutoff_line - 1))"
# shellcheck disable=SC1090
source <(sed -n "1,${cutoff_line}p" "${plugin_sync}")
# Sourced via process-substitution -> SCRIPT_DIR resolves to a transient fd
# path, so _DIRECTION_SAFETY_CHECK would not find the checker. Point it at the
# real (stateless) canonical checker explicitly. PLUGIN_GIT_ROOT/CANONICAL_ROOT
# already resolved correctly at source time from LEADV2_CANONICAL_ROOT.
_DIRECTION_SAFETY_CHECK="${scripts_root}/leadv2-direction-safety-check.py"
_unsafe_excludes=()
while IFS= read -r _u; do
  [[ -z "${_u}" ]] && continue
  _unsafe_excludes+=(--exclude="${_u}")
done < <(_direction_safety_excludes "warn" "cache/scripts" "scripts" "${src}" "${dst}")
rsync --checksum --recursive --delete "${_unsafe_excludes[@]}" "${src}" "${dst}"
