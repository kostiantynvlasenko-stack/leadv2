#!/usr/bin/env bash
# leadv2-plugin-sync.sh — Idempotent sync of plugin scripts/contracts/workflows/hooks
# from the canonical plugin source tree to all runtime locations.
#
# Syncs to:
#   (a) ~/.claude/plugins/cache/leadv2-local/leadv2/0.1.0/  (full plugin cache)
#   (b) ~/.claude/leadv2-shared/                            (scripts + contracts only)
#   (c) <project>/.claude/scripts/                          (per-repo runtimes from cross-repo-paths.yaml)
#   (d) <project>/.claude/contracts/                        (schema files per-repo)
#
# (c)/(d): reads project roots from ~/.claude/leadv2-shared/cross-repo-paths.yaml.
# Missing root on disk → WARN + skip (never silent).
# --project-root overrides to a single root (bypasses yaml iteration).
#
# Also calls leadv2-workflows-sync.sh to sync JS workflow files to ~/.claude/workflows/.
#
# Usage:
#   bash leadv2-plugin-sync.sh [--dry-run] [--project-root <path>]
#
# --dry-run      Print what would change; no writes.
# --project-root Sync (c)/(d) to this single root only (skips yaml iteration).
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

log()      { printf -- '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }
log_ok()   { printf -- '[%s] OK: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }
log_warn() { printf -- '[%s] WARN: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }

# ── Target directories ────────────────────────────────────────────────────────
CACHE_TARGET="${HOME}/.claude/plugins/cache/leadv2-local/leadv2/0.1.0"
SHARED_TARGET="${HOME}/.claude/leadv2-shared"
CROSS_REPO_CONFIG="${HOME}/.claude/leadv2-shared/cross-repo-paths.yaml"

# --checksum only (no -u): mtime skew must never cause silent content divergence.
_rsync_or_dry() {
  local label="$1" src="$2" dst="$3"
  shift 3
  local extra_flags=("$@")
  if [[ "${DRY_RUN}" == "true" ]]; then
    log "DRY_RUN [${label}]: rsync --checksum ${extra_flags[*]} ${src} ${dst}"
    rsync --checksum --dry-run "${extra_flags[@]}" "${src}" "${dst}" 2>&1 | python3 -c "
import sys
for l in sys.stdin:
    if l.startswith('>') or l.startswith('<') or l.startswith('*'):
        print(l, end='')
" | head -20 || true
  else
    mkdir -p "${dst}"
    rsync --checksum "${extra_flags[@]}" "${src}" "${dst}" && log_ok "[${label}] synced ${src} -> ${dst}"
  fi
}

# ── Resolve list of (c)/(d) project roots ────────────────────────────────────
_resolve_project_roots() {
  if [[ -n "${PROJECT_ROOT_OVERRIDE}" ]]; then
    printf -- '%s\n' "${PROJECT_ROOT_OVERRIDE}"
    return
  fi
  if [[ -n "${LEADV2_PROJECT_ROOT:-}" ]]; then
    printf -- '%s\n' "${LEADV2_PROJECT_ROOT}"
    return
  fi
  if [[ ! -f "${CROSS_REPO_CONFIG}" ]]; then
    log_warn "(c)/(d): cross-repo-paths.yaml not found at ${CROSS_REPO_CONFIG}; skipping project sync"
    return
  fi
  # Parse path values from YAML with python3 (no yq dependency).
  python3 - "${CROSS_REPO_CONFIG}" <<'PYEOF'
import sys, yaml, os
config = yaml.safe_load(open(sys.argv[1])) or {}
repos = config.get("repos") or {}
for name, entry in repos.items():
    raw = (entry or {}).get("path", "")
    expanded = os.path.expanduser(raw)
    if expanded:
        print(expanded)
PYEOF
}

# ── Helper: sync (c)/(d) for a single project root ───────────────────────────
_sync_project_root() {
  local root="$1"
  if [[ ! -d "${root}" ]]; then
    log_warn "(c)/(d): project root not found on disk, skipping: ${root}"
    return 0
  fi
  local proj_scripts="${root}/.claude/scripts"
  local proj_contracts="${root}/.claude/contracts"

  log "Syncing -> project scripts (c): ${proj_scripts}"
  local src="${PLUGIN_ROOT}/scripts/"
  if [[ -d "${src}" ]]; then
    _rsync_or_dry "project/scripts[${root##*/}]" "${src}" "${proj_scripts}" --recursive
  fi

  log "Syncing -> project contracts (d): ${proj_contracts}"
  for schema_file in leadv2-scorecard.schema.json leadv2-shadow-proposal.schema.json; do
    local schema_src="${PLUGIN_ROOT}/contracts/${schema_file}"
    if [[ -f "${schema_src}" ]]; then
      if [[ "${DRY_RUN}" == "true" ]]; then
        log "DRY_RUN [project/contracts]: cp ${schema_src} ${proj_contracts}/${schema_file}"
      else
        mkdir -p "${proj_contracts}"
        cp -p "${schema_src}" "${proj_contracts}/${schema_file}"
        log_ok "[project/contracts] copied ${schema_file} -> ${root##*/}"
      fi
    else
      log_warn "source not found, skipping: ${schema_src}"
    fi
  done

  # Ensure eval-harness is present (also covered by scripts/ rsync above, explicit for clarity)
  local harness_src="${PLUGIN_ROOT}/scripts/leadv2-eval-harness.sh"
  if [[ -f "${harness_src}" ]] && [[ ! "${DRY_RUN}" == "true" ]]; then
    mkdir -p "${proj_scripts}"
    cp -p "${harness_src}" "${proj_scripts}/leadv2-eval-harness.sh"
  fi
}

changed_summary=()

# ── (a) Plugin cache ──────────────────────────────────────────────────────────
log "Syncing -> plugin cache (a): ${CACHE_TARGET}"
for subdir in scripts contracts workflows hooks config; do
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

# ── (c)/(d) Per-project .claude/scripts + .claude/contracts ──────────────────
# Iterate all roots from cross-repo-paths.yaml (or single --project-root override).
while IFS= read -r proj_root; do
  [[ -z "${proj_root}" ]] && continue
  _sync_project_root "${proj_root}"
  changed_summary+=("project[${proj_root##*/}]")
done < <(_resolve_project_roots)

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
