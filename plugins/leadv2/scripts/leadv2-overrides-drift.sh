#!/usr/bin/env bash
# scripts/leadv2-overrides-drift.sh — OVERRIDES-INVENTORY-01 drift check
#
# Keeps docs/OVERRIDES.md honest against what the plugin (and the target
# repo's own project-local docs/hooks) actually read. Mirrors the
# UNDOCUMENTED/STALE shape of engine-reference-drift.sh (persona-engine
# scripts/engine-reference-drift.sh), applied to the override mechanism:
#
#   ORPHAN        — a file exists under <repo>/.claude/leadv2-overrides/ but
#                    nothing (plugin scripts/hooks/skills, nor the repo's own
#                    extensions.md/CLAUDE.md) references its path anywhere.
#                    This is the dangerous direction — an override that looks
#                    wired (it parses, it has a plausible name) but never
#                    fires.
#   UNDOCUMENTED  — an override filename IS referenced by the plugin (a real
#                    reader exists) but has no row in docs/OVERRIDES.md, so a
#                    repo has no way to discover the extension point.
#
# Pure local scan — no network. Run once per repo (--repo defaults to cwd).
#
# Usage:
#   bash scripts/leadv2-overrides-drift.sh [--quiet] [--repo <path>] [--plugin-root <path>]
#
# Exit 0 = no drift | Exit 1 = drift found (ORPHAN and/or UNDOCUMENTED non-empty)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT_DEFAULT="$(cd "${SCRIPT_DIR}/.." && pwd)"

QUIET=0
REPO_ROOT="$(pwd)"
PLUGIN_ROOT="${PLUGIN_ROOT_DEFAULT}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --quiet)       QUIET=1; shift ;;
    --repo)        REPO_ROOT="$2"; shift 2 ;;
    --plugin-root) PLUGIN_ROOT="$2"; shift 2 ;;
    *) echo "ERROR: unknown argument: $1" >&2; exit 2 ;;
  esac
done

OVERRIDES_DIR="${REPO_ROOT}/.claude/leadv2-overrides"
DOC_PATH="${PLUGIN_ROOT}/docs/OVERRIDES.md"

if [[ ! -d "$OVERRIDES_DIR" ]]; then
  [[ "$QUIET" -eq 0 ]] && echo "no ${OVERRIDES_DIR} -- nothing to check (repo has zero overrides)"
  exit 0
fi
if [[ ! -f "$DOC_PATH" ]]; then
  echo "ERROR: doc not found: $DOC_PATH" >&2
  exit 2
fi

# Search corpus for "does anything reference this filename":
#  1. the plugin's own scripts/hooks/skills/config/commands (the mechanism)
#  2. the target repo's own extensions.md + CLAUDE.md (project-local readers,
#     e.g. gate1.sh is invoked by the LEAD per extensions.md instruction, not
#     by plugin code -- still a real, provable reader)
search_readers() {
  local fname="$1"
  # pipefail note: grep -rl legitimately exits 1 on zero matches (the ORPHAN
  # case we're looking for) -- `|| true` keeps that from tripping set -e at
  # the call site (readers="$(search_readers ...)" is a bare assignment, not
  # `local`, so command-substitution failure WOULD otherwise abort the script).
  # Repo-local corpus: live code + policy surfaces only. docs/handoff (task
  # history) and other generated/archive dirs are excluded on purpose -- a
  # mention in a closed task's handoff proves the file was read ONCE in the
  # past, not that anything reads it now.
  local -a repo_roots=()
  for d in .claude/leadv2-overrides/extensions.md .claude/CLAUDE.md \
           .claude/skills .claude/hooks .claude/scripts \
           scripts platform agent docs/specs docs/systems-map; do
    [[ -e "${REPO_ROOT}/${d}" ]] && repo_roots+=("${REPO_ROOT}/${d}")
  done
  { grep -rl -- "$fname" \
    "${PLUGIN_ROOT}/scripts" "${PLUGIN_ROOT}/hooks" "${PLUGIN_ROOT}/skills" \
    "${PLUGIN_ROOT}/config" "${PLUGIN_ROOT}/commands" \
    "${repo_roots[@]}" \
    --exclude-dir=.git --exclude-dir=node_modules --exclude-dir=.mypy_cache \
    --exclude-dir=__pycache__ --exclude-dir=.pytest_cache \
    2>/dev/null \
    | grep -v -- "/leadv2-overrides/${fname}$" \
    | wc -l | tr -d ' '; } || true
}

ORPHAN=()
UNDOCUMENTED=()

while IFS= read -r -d '' f; do
  fname="$(basename "$f")"
  readers="$(search_readers "$fname")"
  if [[ "$readers" -eq 0 ]]; then
    ORPHAN+=("$fname")
    continue
  fi
  if ! grep -qF -- "$fname" "$DOC_PATH" 2>/dev/null; then
    UNDOCUMENTED+=("$fname")
  fi
done < <(find "$OVERRIDES_DIR" -maxdepth 1 -type f -print0 | sort -z)

if [[ "$QUIET" -eq 0 ]]; then
  echo "=== leadv2-overrides-drift: ${REPO_ROOT} ==="
  echo "-- ORPHAN (file exists, zero readers found) --"
  if [[ "${#ORPHAN[@]}" -eq 0 ]]; then echo "  (none)"; else printf '  %s\n' "${ORPHAN[@]}"; fi
  echo "-- UNDOCUMENTED (has a real reader, missing from docs/OVERRIDES.md) --"
  if [[ "${#UNDOCUMENTED[@]}" -eq 0 ]]; then echo "  (none)"; else printf '  %s\n' "${UNDOCUMENTED[@]}"; fi
fi

[[ "${#ORPHAN[@]}" -eq 0 && "${#UNDOCUMENTED[@]}" -eq 0 ]] && exit 0
exit 1
