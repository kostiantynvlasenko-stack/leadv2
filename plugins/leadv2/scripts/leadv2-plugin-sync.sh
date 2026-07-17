#!/usr/bin/env bash
# leadv2-plugin-sync.sh — Idempotent sync of plugin scripts/contracts/workflows/hooks
# from the canonical plugin source tree to all runtime locations.
#
# Syncs to:
#   (a) ~/.claude/plugins/cache/leadv2-local/leadv2/0.1.0/  (full plugin cache)
#   (b) ~/.claude/leadv2-shared/                            (scripts + contracts only)
#   (c) <project>/.claude/scripts/                          (per-repo runtimes from cross-repo-paths.yaml)
#   (d) <project>/.claude/contracts/                        (schema files per-repo)
#   (e) ~/.claude/scripts/                                  (user-global leadv2-* scripts; ADDITIVE, no --delete)
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

# CACHE-REFUSAL (PLUGIN-CACHE-THIRD-COPY-REVERTS-FIXES-01): this script must
# only ever run from the git-tracked canonical tree. If $0 resolves to a path
# under the runtime plugin cache, refuse outright — a cache-invoked sync
# would otherwise treat the STALE cache copy as source-of-truth and push its
# staleness back out to every other copy, exactly the incident this task
# exists to fix. Cache-invocation is never legitimate for this script.
case "${SCRIPT_DIR}" in
  "${HOME}"/.claude/plugins/cache/leadv2-local/*)
    printf -- 'REFUSING: leadv2-plugin-sync.sh invoked from the plugin cache (%s) — this script must only run from the git-tracked canonical tree (~/Projects/leadv2/plugins/leadv2/scripts/). Re-invoke from canonical.\n' "${SCRIPT_DIR}" >&2
    exit 3
    ;;
esac

# SOURCE-PIN: canonical is a FIXED path, not derived from dirname($0). Before
# this fix, PLUGIN_ROOT="$(dirname "${SCRIPT_DIR}")" meant whichever COPY
# happened to invoke this script became "the source" for that run — the
# exact bug that let the stale plugin-cache copy silently push itself out to
# vendored repos and the shared tree, reverting 4 already-landed fixes
# (PLUGIN-CACHE-THIRD-COPY-REVERTS-FIXES-01). Only one tree is ever
# canonical: the git-tracked ~/Projects/leadv2/plugins/leadv2/.
CANONICAL_ROOT="${LEADV2_CANONICAL_ROOT:-${HOME}/Projects/leadv2}"
PLUGIN_ROOT="${CANONICAL_ROOT}/plugins/leadv2"
if [[ ! -d "${PLUGIN_ROOT}" ]]; then
  printf -- 'REFUSING: pinned canonical PLUGIN_ROOT does not exist on disk: %s (set LEADV2_CANONICAL_ROOT to override for tests)\n' "${PLUGIN_ROOT}" >&2
  exit 3
fi
PLUGIN_GIT_ROOT="$(git -C "${CANONICAL_ROOT}" rev-parse --show-toplevel 2>/dev/null || printf -- '%s' "${CANONICAL_ROOT}")"

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

# ── Direction-safety (sync_direction_safety decision) ────────────────────────
# Before a --delete rsync push overwrites a target file with different
# content, refuse (don't guess) unless canonical's OWN git history for that
# relative path ever held exactly that content. A downstream copy carrying
# an un-landed fix canonical hasn't seen yet is exactly what silently got
# clobbered in the incident this task fixes. Prints unsafe relpaths (one per
# line) on stdout for the caller to --exclude from the rsync invocation.
_DIRECTION_SAFETY_CHECK="${SCRIPT_DIR}/leadv2-direction-safety-check.py"
_direction_safety_excludes() {
  local subdir="$1" src="$2" dst="$3"
  shift 3
  # M-B fix (review-2.md): optional trailing rsync filter args, e.g.
  # --include='leadv2-*' --exclude='*' for target (e), whose real sync only
  # ever transfers a leadv2-* subset. Scopes this dry-run scan to the same
  # subset instead of checksumming the full (possibly large, e.g.
  # node_modules/) source tree just to compute an exclude list nothing in
  # that tree would ever have matched anyway.
  local -a extra_filters=("$@")
  [[ -f "${_DIRECTION_SAFETY_CHECK}" ]] || return 0
  [[ -d "${dst}" ]] || return 0  # nothing on disk yet to clobber — all safe
  local changed
  changed="$(rsync -rc --delete --dry-run --itemize-changes "${extra_filters[@]}" "${src}" "${dst}" 2>/dev/null \
    | awk '$1 ~ /^>f/ {print $2}')" || true
  [[ -z "${changed}" ]] && return 0
  local relpath
  while IFS= read -r relpath; do
    [[ -z "${relpath}" ]] && continue
    local dst_file="${dst}/${relpath}"
    [[ -f "${dst_file}" ]] || continue  # new file, nothing to clobber — safe
    local canonical_relpath="plugins/leadv2/${subdir}/${relpath}"
    if ! python3 "${_DIRECTION_SAFETY_CHECK}" "${PLUGIN_GIT_ROOT}" "${canonical_relpath}" "${dst_file}"; then
      log_warn "DIRECTION-SAFETY: refusing to overwrite ${dst_file} — its content is not reachable anywhere in canonical's git history for ${canonical_relpath} (possible un-landed fix on this copy). Excluding this file from the sync; land the fix in canonical first."
      printf -- '%s\n' "${relpath}"
    fi
  done <<< "${changed}"
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
  # Parse path + vendors_scripts values from YAML with python3 (no yq
  # dependency). Emits "<path>\t<vendors_scripts>" (default "true" when the
  # field is absent, preserving prior behavior for every repo except any
  # explicitly opted out — C2 fix, PLUGIN-CACHE-THIRD-COPY-REVERTS-FIXES-01).
  python3 - "${CROSS_REPO_CONFIG}" <<'PYEOF'
import sys, yaml, os

def vendors_scripts_enabled(entry):
    # L-B fix (review-2.md): PyYAML only auto-bools UNQUOTED false/no/off/0.
    # A future `vendors_scripts: "false"` (quoted string) would otherwise be
    # a truthy non-empty str -> silently re-vendors the repo with zero
    # warning, the exact incident this field exists to prevent. Accept
    # common string spellings too, not just the bool identity.
    v = entry.get("vendors_scripts", True)
    if isinstance(v, bool):
        return v
    return str(v).strip().lower() not in ("false", "no", "off", "0")

config = yaml.safe_load(open(sys.argv[1])) or {}
repos = config.get("repos") or {}
for name, entry in repos.items():
    entry = entry or {}
    raw = entry.get("path", "")
    expanded = os.path.expanduser(raw)
    if expanded:
        vendors = vendors_scripts_enabled(entry)
        print(f"{expanded}\t{'true' if vendors else 'false'}")
PYEOF
}

# ── Helper: sync (c)/(d) for a single project root ───────────────────────────
# $2 (vendors_scripts, default "true"): when "false", skip (c) .claude/scripts/
# AND (c2) the curated top-level scripts/ subset entirely for this root — a
# repo whose architecture is symlink-only (e.g. campaign-platform,
# cross-repo-paths.yaml `vendors_scripts: false`) must never have a vendored
# scripts tree recreated on it (C2 fix, PLUGIN-CACHE-THIRD-COPY-REVERTS-FIXES-01).
# (d) contracts (schema files, not "scripts") are unaffected by this flag.
_sync_project_root() {
  local root="$1"
  local vendors_scripts="${2:-true}"
  if [[ ! -d "${root}" ]]; then
    log_warn "(c)/(d): project root not found on disk, skipping: ${root}"
    return 0
  fi
  local proj_scripts="${root}/.claude/scripts"
  local proj_contracts="${root}/.claude/contracts"

  local src="${PLUGIN_ROOT}/scripts/"
  if [[ "${vendors_scripts}" == "false" ]]; then
    log_warn "(c): skipping project scripts vendoring for ${root} — vendors_scripts: false (symlink-only architecture)"
  else
    log "Syncing -> project scripts (c): ${proj_scripts}"
    if [[ -d "${src}" ]]; then
      _rsync_or_dry "project/scripts[${root##*/}]" "${src}" "${proj_scripts}" --recursive
    fi
  fi

  # (c2) Some repos ALSO vendor a CURATED subset of leadv2-* scripts at
  # <root>/scripts/ (top-level, NOT .claude/scripts/) — e.g. persona-engine's
  # out-of-worktree control plane (2026-07-14, 6321bf2). This second location was
  # never covered by (c) above, so it silently drifted (SUPERVISE-V2-01 found it
  # missing leadv2-supervise-loop.sh/leadv2-supervise-pick.sh entirely + a stale
  # leadv2-supervise.sh). FIXED SET, not a leadv2-* wildcard: a wildcard rsync
  # dumps the FULL ~150-file canonical scripts/ dir into what has always been a
  # deliberately curated ~13-file subset (confirmed by scoping this list to the
  # pre-existing files there + the 3 hard runtime deps leadv2-supervise.sh's
  # source chain actually requires: active-registry.sh sourced directly by
  # supervise.sh L136-138; tasks-lib.sh sourced directly by supervise-pick.sh
  # L50; loop.sh/pick.sh named explicitly missing by SUPERVISE-V2-01). Extend
  # this list only when a repo's control-plane scripts/ genuinely adopts a new
  # companion — never switch this back to a wildcard.
  local proj_scripts_toplevel="${root}/scripts"
  local -a toplevel_curated_files=(
    leadv2-answer.sh leadv2-ask.sh leadv2-bus.sh leadv2-client-surface-gate.sh
    leadv2-fanout-classify.sh leadv2-fanout.sh leadv2-finish.sh
    leadv2-merge-queue.sh leadv2-provider-rollup.sh leadv2-session-runner.sh
    leadv2-state-path.sh leadv2-supervise.sh leadv2-tasks-regen-gate.sh
    leadv2-active-registry.sh leadv2-supervise-loop.sh leadv2-supervise-pick.sh
    leadv2-tasks-lib.sh
  )
  if [[ "${vendors_scripts}" != "false" ]] && [[ -d "${proj_scripts_toplevel}" ]] && compgen -G "${proj_scripts_toplevel}/leadv2-*" > /dev/null 2>&1; then
    log "Syncing -> project top-level scripts (c2, out-of-worktree control plane): ${proj_scripts_toplevel} [curated set, additive]"
    for cf in "${toplevel_curated_files[@]}"; do
      local cf_src="${src}${cf}"
      if [[ -f "${cf_src}" ]]; then
        if [[ "${DRY_RUN}" == "true" ]]; then
          log "DRY_RUN [project/scripts-toplevel]: cp ${cf_src} ${proj_scripts_toplevel}/${cf}"
        else
          mkdir -p "${proj_scripts_toplevel}"
          cp -p "${cf_src}" "${proj_scripts_toplevel}/${cf}"
        fi
      fi
    done
    log_ok "[project/scripts-toplevel[${root##*/}]] synced curated set -> ${proj_scripts_toplevel}"
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

  # Ensure eval-harness is present (also covered by scripts/ rsync above,
  # explicit for clarity). Guarded by vendors_scripts too — this was the bug
  # that recreated campaign-platform's .claude/scripts/ (1 file) even after
  # the (c) skip above, found live while verifying the C2 fix.
  local harness_src="${PLUGIN_ROOT}/scripts/leadv2-eval-harness.sh"
  if [[ "${vendors_scripts}" != "false" ]] && [[ -f "${harness_src}" ]] && [[ ! "${DRY_RUN}" == "true" ]]; then
    mkdir -p "${proj_scripts}"
    cp -p "${harness_src}" "${proj_scripts}/leadv2-eval-harness.sh"
  fi
}

changed_summary=()

# ── (a) Plugin cache ──────────────────────────────────────────────────────────
log "Syncing -> plugin cache (a): ${CACHE_TARGET}"
for subdir in scripts contracts workflows hooks config skills commands agents docs; do
  src="${PLUGIN_ROOT}/${subdir}/"
  dst="${CACHE_TARGET}/${subdir}"
  if [[ -d "${src}" ]]; then
    _unsafe_excludes=()
    while IFS= read -r _u; do
      [[ -z "${_u}" ]] && continue
      _unsafe_excludes+=(--exclude="${_u}")
    done < <(_direction_safety_excludes "${subdir}" "${src}" "${dst}")
    _rsync_or_dry "cache/${subdir}" "${src}" "${dst}" --recursive --delete "${_unsafe_excludes[@]}"
    changed_summary+=("cache/${subdir}")
  fi
done

# ── (b) leadv2-shared (scripts + contracts only) ─────────────────────────────
log "Syncing -> leadv2-shared (b): ${SHARED_TARGET}"
for subdir in scripts contracts; do
  src="${PLUGIN_ROOT}/${subdir}/"
  dst="${SHARED_TARGET}/${subdir}"
  if [[ -d "${src}" ]]; then
    _unsafe_excludes=()
    while IFS= read -r _u; do
      [[ -z "${_u}" ]] && continue
      _unsafe_excludes+=(--exclude="${_u}")
    done < <(_direction_safety_excludes "${subdir}" "${src}" "${dst}")
    _rsync_or_dry "shared/${subdir}" "${src}" "${dst}" --recursive --delete "${_unsafe_excludes[@]}"
    changed_summary+=("shared/${subdir}")
  fi
done

# ── (e) ~/.claude/scripts/ — user-global leadv2-* scripts ───────────────────
# ADDITIVE ONLY: --include='leadv2-*' --exclude='*' scopes rsync to leadv2-*
# files only. NO --delete — preserves codex-task.sh, ask-lead.sh, cx-tail.sh,
# and all other non-leadv2 user-global scripts (24 files; must never change).
USER_SCRIPTS_TARGET="${HOME}/.claude/scripts"
log "Syncing -> user-global scripts (e): ${USER_SCRIPTS_TARGET} [leadv2-* only, additive, no --delete]"
# H1 fix (review-1.md, fix1): (e) was the only sync target NOT wrapped in
# _direction_safety_excludes — no --delete does not mean no overwrite; rsync
# still clobbers a same-named file when content differs. A locally-patched
# leadv2-*.sh sitting here that hasn't yet landed in canonical would be
# silently overwritten on the next sync (the exact incident class this task
# fixes, for a target context.yaml's "five copies" enumeration didn't name).
_unsafe_excludes=()
while IFS= read -r _u; do
  [[ -z "${_u}" ]] && continue
  _unsafe_excludes+=(--exclude="${_u}")
done < <(_direction_safety_excludes "scripts" "${PLUGIN_ROOT}/scripts/" "${USER_SCRIPTS_TARGET}" --include='leadv2-*' --exclude='*')
# rsync filter rules are first-match-wins: unsafe excludes MUST precede the
# generic --include='leadv2-*' --exclude='*' wildcard, or that wildcard would
# already have claimed (and included) the unsafe leadv2-* filename before its
# specific --exclude is ever reached.
_rsync_or_dry "user-scripts" "${PLUGIN_ROOT}/scripts/" "${USER_SCRIPTS_TARGET}" \
  "${_unsafe_excludes[@]}" --include='leadv2-*' --exclude='*' -d
changed_summary+=("user-scripts")

# ── (f) leadv2 repo's OWN vendored .claude/scripts (copy #2 of the 5,
# PLUGIN-CACHE-THIRD-COPY-REVERTS-FIXES-01 context.yaml) ─────────────────────
# ~/Projects/leadv2/.claude/scripts/ is not this repo's own canonical (that's
# plugins/leadv2/scripts/), but it IS one of the 5 copies the drift-guard
# checks, and — unlike the (c)/(d) targets which iterate cross-repo-paths.yaml
# — it was never an actual sync TARGET here, so it would drift forever and
# perpetually fail the drift-guard/fanout preflight. Sync it the same way as
# (c), hardcoded (this repo is intentionally NOT added to the shared
# cross-repo-paths.yaml — that file is a shared tree, out of this task's
# edit authorization).
LEADV2_REPO_VENDORED="${CANONICAL_ROOT}/.claude/scripts"
if [[ -d "${CANONICAL_ROOT}/.claude" ]]; then
  log "Syncing -> leadv2 repo's own vendored scripts (f): ${LEADV2_REPO_VENDORED}"
  _unsafe_excludes=()
  while IFS= read -r _u; do
    [[ -z "${_u}" ]] && continue
    _unsafe_excludes+=(--exclude="${_u}")
  done < <(_direction_safety_excludes "scripts" "${PLUGIN_ROOT}/scripts/" "${LEADV2_REPO_VENDORED}")
  _rsync_or_dry "leadv2-repo-vendored/scripts" "${PLUGIN_ROOT}/scripts/" "${LEADV2_REPO_VENDORED}" --recursive --delete "${_unsafe_excludes[@]}"
  changed_summary+=("leadv2-repo-vendored")
fi

# ── (c)/(d) Per-project .claude/scripts + .claude/contracts ──────────────────
# Iterate all roots from cross-repo-paths.yaml (or single --project-root
# override). Each line is "<path>\t<vendors_scripts>" (see _resolve_project_roots);
# --project-root bypass emits a bare path with no tab -> defaults to "true".
while IFS=$'\t' read -r proj_root proj_vendors_scripts; do
  [[ -z "${proj_root}" ]] && continue
  _sync_project_root "${proj_root}" "${proj_vendors_scripts:-true}"
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
