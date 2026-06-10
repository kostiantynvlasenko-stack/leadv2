#!/usr/bin/env bash
# leadv2-plugin-sync.sh — Idempotent sync of plugin scripts/contracts/workflows/hooks
# from the canonical plugin source tree to all runtime locations.
#
# Syncs to:
#   (a) ~/.claude/plugins/cache/leadv2-local/leadv2/0.1.0/  (full plugin cache)
#   (b) ~/.claude/leadv2-shared/                            (scripts + contracts only)
#   (c) <project>/.claude/scripts/                          (persona-engine runtime)
#   (d) <project>/.claude/contracts/                        (schema files for runtime)
#
# Also calls leadv2-workflows-sync.sh to sync JS workflow files to ~/.claude/workflows/.
#
# Usage:
#   bash leadv2-plugin-sync.sh [--dry-run] [--project-root <path>]
#
# --dry-run      Print what would change; no writes.
# --project-root Override project root for (c)/(d) targets (default: auto-detect).
#
# Idempotent: safe to re-run after any plugin edit.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(dirname "${SCRIPT_DIR}")"  # plugins/leadv2/

DRY_RUN=false
PROJECT_ROOT_OVERRIDE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true ;;
    --project-root) shift; PROJECT_ROOT_OVERRIDE="$1" ;;
    *) printf -- 'Unknown arg: %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

log()    { printf -- '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }
log_ok() { printf -- '[%s] OK: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }

# ── Resolve project root for (c)/(d) targets ─────────────────────────────────
if [[ -n "${PROJECT_ROOT_OVERRIDE}" ]]; then
  LEADV2_PROJECT_ROOT="${PROJECT_ROOT_OVERRIDE}"
elif [[ -n "${LEADV2_PROJECT_ROOT:-}" ]]; then
  : # already set
elif [[ -n "${PROJECT_ROOT:-}" ]]; then
  LEADV2_PROJECT_ROOT="${PROJECT_ROOT}"
else
  LEADV2_PROJECT_ROOT="$(git -C "${SCRIPT_DIR}" rev-parse --show-toplevel 2>/dev/null || true)"
  if [[ -z "${LEADV2_PROJECT_ROOT}" ]]; then
    log "WARN: cannot resolve project root; skipping (c)/(d) targets"
  fi
fi

# ── Target directories ────────────────────────────────────────────────────────
CACHE_TARGET="${HOME}/.claude/plugins/cache/leadv2-local/leadv2/0.1.0"
SHARED_TARGET="${HOME}/.claude/leadv2-shared"
PROJ_SCRIPTS_TARGET="${LEADV2_PROJECT_ROOT:-}/.claude/scripts"
PROJ_CONTRACTS_TARGET="${LEADV2_PROJECT_ROOT:-}/.claude/contracts"

_rsync_or_dry() {
  local label="$1" src="$2" dst="$3"
  shift 3
  local extra_flags=("$@")
  if [[ "${DRY_RUN}" == "true" ]]; then
    log "DRY_RUN [${label}]: rsync -u --checksum ${extra_flags[*]} ${src} ${dst}"
    rsync -u --checksum --dry-run "${extra_flags[@]}" "${src}" "${dst}" 2>&1 | grep -E '^>' | head -20 || true
  else
    mkdir -p "${dst}"
    rsync -u --checksum "${extra_flags[@]}" "${src}" "${dst}" && log_ok "[${label}] synced ${src} -> ${dst}"
  fi
}

changed_summary=()

# ── (a) Plugin cache ──────────────────────────────────────────────────────────
log "Syncing -> plugin cache (a): ${CACHE_TARGET}"
for subdir in scripts contracts workflows hooks; do
  src="${PLUGIN_ROOT}/${subdir}/"
  dst="${CACHE_TARGET}/${subdir}"
  if [[ -d "${src}" ]]; then
    _rsync_or_dry "cache/${subdir}" "${src}" "${dst}" --recursive --delete
    changed_summary+=("cache/${subdir}")
  fi
done

# ── (b) leadv2-shared (scripts + contracts only) ─────────────────────────────
log "Syncing -> leadv2-shared (b): ${SHARED_TARGET}"
for subdir in scripts contracts; do
  src="${PLUGIN_ROOT}/${subdir}/"
  dst="${SHARED_TARGET}/${subdir}"
  if [[ -d "${src}" ]]; then
    _rsync_or_dry "shared/${subdir}" "${src}" "${dst}" --recursive --delete
    changed_summary+=("shared/${subdir}")
  fi
done

# ── (c) Project .claude/scripts (persona-engine runtime) ─────────────────────
if [[ -n "${LEADV2_PROJECT_ROOT:-}" ]]; then
  log "Syncing -> project scripts (c): ${PROJ_SCRIPTS_TARGET}"
  src="${PLUGIN_ROOT}/scripts/"
  if [[ -d "${src}" ]]; then
    _rsync_or_dry "project/scripts" "${src}" "${PROJ_SCRIPTS_TARGET}" --recursive
    changed_summary+=("project/scripts")
  fi

  # ── (d) Project .claude/contracts (schema files) ─────────────────────────
  log "Syncing -> project contracts (d): ${PROJ_CONTRACTS_TARGET}"
  for schema_file in leadv2-scorecard.schema.json leadv2-shadow-proposal.schema.json; do
    schema_src="${PLUGIN_ROOT}/contracts/${schema_file}"
    if [[ -f "${schema_src}" ]]; then
      if [[ "${DRY_RUN}" == "true" ]]; then
        log "DRY_RUN [project/contracts]: cp ${schema_src} ${PROJ_CONTRACTS_TARGET}/${schema_file}"
      else
        mkdir -p "${PROJ_CONTRACTS_TARGET}"
        cp -p "${schema_src}" "${PROJ_CONTRACTS_TARGET}/${schema_file}"
        log_ok "[project/contracts] copied ${schema_file}"
      fi
      changed_summary+=("project/contracts/${schema_file}")
    else
      log "WARN: source not found, skipping: ${schema_src}"
    fi
  done

  # eval-harness lives in scripts/ — also copy to .claude/scripts (already done above via rsync)
  # but explicitly ensure it is present:
  harness_src="${PLUGIN_ROOT}/scripts/leadv2-eval-harness.sh"
  if [[ -f "${harness_src}" ]]; then
    if [[ "${DRY_RUN}" == "true" ]]; then
      log "DRY_RUN [project/scripts]: ensure leadv2-eval-harness.sh present"
    else
      mkdir -p "${PROJ_SCRIPTS_TARGET}"
      cp -p "${harness_src}" "${PROJ_SCRIPTS_TARGET}/leadv2-eval-harness.sh"
      log_ok "[project/scripts] ensured leadv2-eval-harness.sh"
    fi
    changed_summary+=("project/scripts/leadv2-eval-harness.sh")
  fi
fi

# ── Subsume: sync workflow JS files ──────────────────────────────────────────
WORKFLOWS_SYNC="${SCRIPT_DIR}/leadv2-workflows-sync.sh"
if [[ -f "${WORKFLOWS_SYNC}" ]]; then
  log "Calling leadv2-workflows-sync.sh..."
  if [[ "${DRY_RUN}" == "true" ]]; then
    bash "${WORKFLOWS_SYNC}" --dry-run
  else
    bash "${WORKFLOWS_SYNC}"
  fi
  changed_summary+=("workflows")
fi

# ── Summary ───────────────────────────────────────────────────────────────────
if [[ ${#changed_summary[@]} -gt 0 ]]; then
  log "Sync complete. Targets touched: ${changed_summary[*]}"
else
  log "Nothing synced (empty target list or all dry-run)."
fi
