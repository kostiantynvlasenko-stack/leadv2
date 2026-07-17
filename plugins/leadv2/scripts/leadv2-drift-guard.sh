#!/usr/bin/env bash
# leadv2-drift-guard.sh — 5-way parity check across every copy of the leadv2
# plugin scripts/ tree (PLUGIN-CACHE-THIRD-COPY-REVERTS-FIXES-01).
#
# Root cause this guards against: there are FIVE copies of the plugin
# scripts, not two or three. A parity check over the wrong perimeter
# manufactures false confidence — that is exactly what let a stale plugin
# cache silently revert 4 shipped fixes for an hour undetected.
#
# The five copies:
#   (1) canonical  ~/Projects/leadv2/plugins/leadv2/scripts/        [git-tracked source of truth]
#   (2) leadv2-repo-vendored  ~/Projects/leadv2/.claude/scripts/
#   (3) plugin cache  ~/.claude/plugins/cache/leadv2-local/leadv2/0.1.0/scripts/
#   (4) shared tree  ~/.claude/leadv2-shared/scripts/
#   (5) per-repo vendored <repo>/.claude/scripts/ for each repo in
#       ~/.claude/leadv2-shared/cross-repo-paths.yaml
#
# Comparison scope: hash the CANONICAL relative-path SET only (per
# drift_guard_comparison decision) — vendored repos legitimately carry extra
# files (repo-specific scripts) that must never false-positive a drift
# report. A file present in canonical but MISSING or DIFFERENT in a copy is
# drift; a file present in a copy but absent from canonical is NOT drift.
#
# Usage:
#   leadv2-drift-guard.sh [--quiet] [--json]
#
# Exit 0 = all 5 copies match canonical on the canonical path set.
# Exit 1 = drift detected in at least one copy.
# Exit 2 = usage error / canonical tree missing.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

QUIET=0
JSON=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --quiet) QUIET=1; shift ;;
    --json)  JSON=1; shift ;;
    *) echo "ERROR: unknown argument: $1" >&2; exit 2 ;;
  esac
done

log() { [[ "${QUIET}" -eq 1 ]] && return 0; printf -- '[drift-guard] %s\n' "$*" >&2; }

CANONICAL_ROOT="${LEADV2_CANONICAL_ROOT:-${HOME}/Projects/leadv2}"
CANONICAL_SCRIPTS="${CANONICAL_ROOT}/plugins/leadv2/scripts"

if [[ ! -d "${CANONICAL_SCRIPTS}" ]]; then
  echo "ERROR: canonical scripts dir not found: ${CANONICAL_SCRIPTS}" >&2
  exit 2
fi

CROSS_REPO_CONFIG="${HOME}/.claude/leadv2-shared/cross-repo-paths.yaml"

declare -a COPY_NAMES
declare -a COPY_PATHS
COPY_NAMES+=("leadv2-repo-vendored")
COPY_PATHS+=("${CANONICAL_ROOT}/.claude/scripts")
COPY_NAMES+=("plugin-cache")
COPY_PATHS+=("${HOME}/.claude/plugins/cache/leadv2-local/leadv2/0.1.0/scripts")
COPY_NAMES+=("leadv2-shared")
COPY_PATHS+=("${HOME}/.claude/leadv2-shared/scripts")

if [[ -f "${CROSS_REPO_CONFIG}" ]]; then
  while IFS= read -r proj_root; do
    [[ -z "${proj_root}" ]] && continue
    name="$(basename "${proj_root}")"
    COPY_NAMES+=("vendored[${name}]")
    COPY_PATHS+=("${proj_root}/.claude/scripts")
  done < <(python3 - "${CROSS_REPO_CONFIG}" <<'PYEOF'
import sys, yaml, os
config = yaml.safe_load(open(sys.argv[1])) or {}
repos = config.get("repos") or {}
for name, entry in repos.items():
    raw = (entry or {}).get("path", "")
    expanded = os.path.expanduser(raw)
    if expanded:
        print(expanded)
PYEOF
  )
else
  log "WARN: cross-repo-paths.yaml not found at ${CROSS_REPO_CONFIG} — skipping per-repo vendored copies"
fi

# ── Build the canonical relative-path set (regular files only) ─────────────
mapfile -t CANONICAL_RELPATHS < <(cd "${CANONICAL_SCRIPTS}" && find . -type f | sed 's|^\./||' | sort)

drift_found=0
declare -a drift_report

for i in "${!COPY_NAMES[@]}"; do
  name="${COPY_NAMES[$i]}"
  path="${COPY_PATHS[$i]}"

  if [[ ! -d "${path}" ]]; then
    log "MISSING copy dir: ${name} (${path})"
    drift_found=1
    drift_report+=("${name}:MISSING_DIR")
    continue
  fi

  for relpath in "${CANONICAL_RELPATHS[@]}"; do
    canon_file="${CANONICAL_SCRIPTS}/${relpath}"
    copy_file="${path}/${relpath}"

    if [[ ! -f "${copy_file}" ]]; then
      log "DRIFT [${name}]: missing file ${relpath}"
      drift_found=1
      drift_report+=("${name}:${relpath}:MISSING")
      continue
    fi

    canon_hash="$(shasum -a 256 "${canon_file}" 2>/dev/null | awk '{print $1}')"
    copy_hash="$(shasum -a 256 "${copy_file}" 2>/dev/null | awk '{print $1}')"
    if [[ "${canon_hash}" != "${copy_hash}" ]]; then
      log "DRIFT [${name}]: content differs for ${relpath}"
      drift_found=1
      drift_report+=("${name}:${relpath}:CONTENT_DIFFERS")
    fi
  done
done

if [[ "${JSON}" -eq 1 ]]; then
  printf -- '{"drift":%s,"entries":[' "$([[ ${drift_found} -eq 1 ]] && echo true || echo false)"
  for i in "${!drift_report[@]}"; do
    [[ $i -gt 0 ]] && printf -- ','
    printf -- '"%s"' "${drift_report[$i]}"
  done
  printf -- ']}\n'
fi

if [[ ${drift_found} -eq 1 ]]; then
  log "DRIFT DETECTED across ${#drift_report[@]} entr$([[ ${#drift_report[@]} -eq 1 ]] && echo y || echo ies) — re-run leadv2-plugin-sync.sh from canonical (~/Projects/leadv2/plugins/leadv2/scripts/) to reconcile."
  exit 1
fi

log "OK: all ${#COPY_NAMES[@]} copies match canonical on ${#CANONICAL_RELPATHS[@]} files."
exit 0
