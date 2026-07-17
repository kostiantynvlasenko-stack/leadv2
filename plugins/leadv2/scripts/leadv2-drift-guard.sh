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

# C3 test-hook: LEADV2_HOME_ROOT lets tests sandbox the $HOME-anchored copies
# (plugin-cache, leadv2-shared, cross-repo-paths.yaml) under a temp dir
# instead of touching the real ones — same test-isolation pattern already
# used by LEADV2_CANONICAL_ROOT. Never set this for a real run.
_HOME_ROOT="${LEADV2_HOME_ROOT:-${HOME}}"
CROSS_REPO_CONFIG="${_HOME_ROOT}/.claude/leadv2-shared/cross-repo-paths.yaml"

declare -a COPY_NAMES
declare -a COPY_PATHS
COPY_NAMES+=("leadv2-repo-vendored")
COPY_PATHS+=("${CANONICAL_ROOT}/.claude/scripts")
COPY_NAMES+=("plugin-cache")
COPY_PATHS+=("${_HOME_ROOT}/.claude/plugins/cache/leadv2-local/leadv2/0.1.0/scripts")
COPY_NAMES+=("leadv2-shared")
COPY_PATHS+=("${_HOME_ROOT}/.claude/leadv2-shared/scripts")

if [[ -f "${CROSS_REPO_CONFIG}" ]]; then
  # vendors_scripts: false (e.g. campaign-platform, symlink-only architecture)
  # repos are skipped here entirely — they never carry a vendored
  # .claude/scripts/ by design (C2/C1-adjacent fix, fix1), so including them
  # would make MISSING_DIR a permanent false-positive drift on every run.
  while IFS= read -r proj_root; do
    [[ -z "${proj_root}" ]] && continue
    name="$(basename "${proj_root}")"
    COPY_NAMES+=("vendored[${name}]")
    COPY_PATHS+=("${proj_root}/.claude/scripts")
  done < <(python3 - "${CROSS_REPO_CONFIG}" <<'PYEOF'
import sys, yaml, os

def vendors_scripts_disabled(entry):
    # L-B fix (review-2.md): mirror leadv2-plugin-sync.sh's normalization —
    # a quoted `vendors_scripts: "false"` must still be treated as disabled,
    # not just the unquoted-bool `is False` identity check.
    v = entry.get("vendors_scripts", True)
    if isinstance(v, bool):
        return v is False
    return str(v).strip().lower() in ("false", "no", "off", "0")

config = yaml.safe_load(open(sys.argv[1])) or {}
repos = config.get("repos") or {}
for name, entry in repos.items():
    entry = entry or {}
    if vendors_scripts_disabled(entry):
        continue
    raw = entry.get("path", "")
    expanded = os.path.expanduser(raw)
    if expanded:
        print(expanded)
PYEOF
  )
else
  log "WARN: cross-repo-paths.yaml not found at ${CROSS_REPO_CONFIG} — skipping per-repo vendored copies"
fi

# ── Build the canonical relative-path set (real leadv2 script files only) ──
# maxdepth 1, *.sh/*.py only: CANONICAL_SCRIPTS also contains node_modules/
# (playwright + deps, hundreds of files) and __pycache__/ (generated
# bytecode). Sweeping all of those in (372 files, not ~150 real scripts) made
# the guard take minutes per copy — unacceptable given leadv2-fanout.sh calls
# this synchronously as a preflight.
#
# H4 fix (review-1.md, fix1): tests/ is now INCLUDED — the prior comment
# claiming it "is not synced by leadv2-plugin-sync.sh's subdir list to (c)/(d)
# targets" was factually wrong (verified live: _sync_project_root's
# --recursive rsync to (c) DOES vendor scripts/tests/ into every per-repo
# .claude/scripts/, and it had ALREADY diverged there — 3 extra files in
# persona-engine's copy going undetected). tests/ is only 38 files (27
# top-level test-*.sh + 11 fixtures/), nowhere near the 372-file
# node_modules/__pycache__ problem this exclusion originally solved, so it is
# cheap to include and closes a real false-negative.
mapfile -t CANONICAL_RELPATHS < <(
  {
    find "${CANONICAL_SCRIPTS}" -maxdepth 1 -type f \( -name '*.sh' -o -name '*.py' \) -print
    [[ -d "${CANONICAL_SCRIPTS}/tests" ]] && find "${CANONICAL_SCRIPTS}/tests" -type f -print
  } | sed "s|^${CANONICAL_SCRIPTS}/||" | sort
)

# ── Single in-process comparison (was: 2 shasum forks per file per copy —
# over 1000 forks for 150 files x 7 copies, ~80s wall clock; unacceptable
# given leadv2-fanout.sh calls this synchronously as a preflight). One
# python3 process hashes canonical once and every copy once, in-process. ──
_names_csv="$(IFS=$'\x1f'; echo "${COPY_NAMES[*]}")"
_paths_csv="$(IFS=$'\x1f'; echo "${COPY_PATHS[*]}")"
_relpaths_csv="$(IFS=$'\x1f'; echo "${CANONICAL_RELPATHS[*]}")"

COMPARE_OUT="$(NAMES="${_names_csv}" PATHS="${_paths_csv}" RELPATHS="${_relpaths_csv}" \
  CANONICAL_SCRIPTS="${CANONICAL_SCRIPTS}" python3 <<'PYEOF'
import hashlib, os

def sha256_file(path):
    try:
        with open(path, "rb") as f:
            return hashlib.sha256(f.read()).hexdigest()
    except OSError:
        return None

canonical_scripts = os.environ["CANONICAL_SCRIPTS"]
names = os.environ["NAMES"].split("\x1f")
paths = os.environ["PATHS"].split("\x1f")
relpaths = os.environ["RELPATHS"].split("\x1f")

canon_hashes = {rp: sha256_file(os.path.join(canonical_scripts, rp)) for rp in relpaths}

drift_found = False
report = []
for name, path in zip(names, paths):
    if not os.path.isdir(path):
        drift_found = True
        report.append(f"{name}:MISSING_DIR")
        print(f"MISSING copy dir: {name} ({path})")
        continue
    for rp in relpaths:
        copy_file = os.path.join(path, rp)
        if not os.path.isfile(copy_file):
            drift_found = True
            report.append(f"{name}:{rp}:MISSING")
            print(f"DRIFT [{name}]: missing file {rp}")
            continue
        if sha256_file(copy_file) != canon_hashes[rp]:
            drift_found = True
            report.append(f"{name}:{rp}:CONTENT_DIFFERS")
            print(f"DRIFT [{name}]: content differs for {rp}")

print("---REPORT---")
for r in report:
    print(r)
print(f"---STATUS---\n{'DRIFT' if drift_found else 'OK'}")
PYEOF
)"

drift_found=0
declare -a drift_report
_section=""
while IFS= read -r _line; do
  case "${_line}" in
    "---REPORT---") _section="report"; continue ;;
    "---STATUS---") _section="status"; continue ;;
  esac
  case "${_section}" in
    report) drift_report+=("${_line}") ;;
    status) [[ "${_line}" == "DRIFT" ]] && drift_found=1 ;;
    *) log "${_line}" ;;
  esac
done <<< "${COMPARE_OUT}"

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
