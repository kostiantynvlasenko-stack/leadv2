#!/usr/bin/env bash
# leadv2-scripts-symlink-plan.sh — Stage 3 dry-run enumeration + (guarded)
# apply/rollback for per-file .claude/scripts/ symlink conversion.
#
# Background: plugin single-source distribution Stage 3 (docs/handoff/
# supervisor-scope/plugin-distribution.md in persona-engine). A naive
# directory-level symlink (`.claude/scripts -> canonical`) was ruled out —
# .claude/scripts/ is a MIXED directory in every live repo (repo-native
# tooling sits directly alongside vendored plugin files; persona-engine has
# 36 such files, respiro-ios 22, m3-market 38+its own node_modules/lib/docs).
# The real, safe mechanism is PER-FILE symlinks: only files that are actually
# part of the canonical plugin get linked; everything else stays a real file,
# untouched.
#
# The link SET is derived FROM canonical (never hardcoded) — canonical's own
# plugins/leadv2/scripts/ (top-level files + tests/ subdir, recursively) IS
# the ground truth. A repo file classifies as:
#   would-link         name matches a canonical file AND content is BYTE-
#                       IDENTICAL to canonical right now — safe to replace
#                       with a symlink, nothing is lost.
#   ambiguous          name matches a canonical file but content DIFFERS —
#                       unreconciled drift. Needs the same classify-then-
#                       reconcile treatment the persona-engine 12-file pass
#                       got BEFORE it is safe to link (could be a real local
#                       fix never upstreamed — linking would silently delete
#                       it, same class of bug this whole task exists to
#                       prevent). NEVER auto-included in the link set.
#   would-leave-native  no canonical file has this name — repo-specific
#                       tooling or a personal script. Never touched.
#   already-linked      destination is already a symlink (informational only,
#                       not counted in the three headline buckets).
#   missing-in-repo     canonical has this file but the repo never vendored
#                       it at all (informational only — out of scope for a
#                       "convert what's already vendored" pass; NOT
#                       auto-created by --apply).
#
# Modes:
#   (no flag)   PLAN — dry run. Prints per-bucket counts to stdout; writes
#               full per-file lists to a report file. Writes NOTHING to the
#               repo. Default and safe to run anytime.
#   --apply     Converts every would-link file to a per-file symlink to
#               canonical. Before linking, moves the original vendored file
#               into a timestamped backup dir
#               (<repo>/.claude/scripts-vendor-backup-<UTC-ts>/<name>) so the
#               conversion is a single-step rollback, never a re-derive.
#               Touches ONLY would-link files — ambiguous and native files
#               are never touched by --apply.
#   --rollback <backup-dir>  Restores every file from the given backup dir
#               back to its original path, removing the symlink first.
#
# Usage:
#   leadv2-scripts-symlink-plan.sh <repo_root>                  # plan
#   leadv2-scripts-symlink-plan.sh <repo_root> --apply
#   leadv2-scripts-symlink-plan.sh <repo_root> --rollback <backup-dir>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CANONICAL_ROOT="${LEADV2_CANONICAL_ROOT:-${HOME}/Projects/leadv2}"
CANONICAL_SCRIPTS="${CANONICAL_ROOT}/plugins/leadv2/scripts"

if [[ ! -d "${CANONICAL_SCRIPTS}" ]]; then
  echo "ERROR: canonical scripts dir not found: ${CANONICAL_SCRIPTS}" >&2
  exit 2
fi

REPO_ROOT="${1:-}"
MODE="plan"
BACKUP_DIR_ARG=""
if [[ "${2:-}" == "--apply" ]]; then
  MODE="apply"
elif [[ "${2:-}" == "--rollback" ]]; then
  MODE="rollback"
  BACKUP_DIR_ARG="${3:-}"
fi

if [[ -z "${REPO_ROOT}" ]]; then
  echo "usage: leadv2-scripts-symlink-plan.sh <repo_root> [--apply | --rollback <backup-dir>]" >&2
  exit 2
fi
REPO_ROOT="$(cd "${REPO_ROOT}" 2>/dev/null && pwd || true)"
if [[ -z "${REPO_ROOT}" || ! -d "${REPO_ROOT}/.claude/scripts" ]]; then
  echo "ERROR: ${1} has no .claude/scripts/ directory" >&2
  exit 2
fi
PROJ_SCRIPTS="${REPO_ROOT}/.claude/scripts"

if [[ "${MODE}" == "rollback" ]]; then
  if [[ -z "${BACKUP_DIR_ARG}" || ! -d "${BACKUP_DIR_ARG}" ]]; then
    echo "ERROR: --rollback requires a valid backup dir (got: '${BACKUP_DIR_ARG}')" >&2
    exit 2
  fi
  restored=0
  while IFS= read -r -d '' bfile; do
    relpath="${bfile#"${BACKUP_DIR_ARG}"/}"
    dest="${PROJ_SCRIPTS}/${relpath}"
    if [[ -L "${dest}" ]]; then
      rm -f "${dest}"
    fi
    mkdir -p "$(dirname "${dest}")"
    cp -p "${bfile}" "${dest}"
    restored=$((restored + 1))
  done < <(find "${BACKUP_DIR_ARG}" -type f -print0)
  echo "ROLLBACK: restored ${restored} file(s) from ${BACKUP_DIR_ARG} into ${PROJ_SCRIPTS}"
  exit 0
fi

REPORT_FILE="/tmp/leadv2-symlink-plan-$(basename "${REPO_ROOT}").txt"

RESULT="$(CANONICAL_SCRIPTS="${CANONICAL_SCRIPTS}" PROJ_SCRIPTS="${PROJ_SCRIPTS}" MODE="${MODE}" python3 <<'PYEOF'
import hashlib, os, sys

canonical = os.environ["CANONICAL_SCRIPTS"]
proj = os.environ["PROJ_SCRIPTS"]
mode = os.environ["MODE"]

def sha256_file(path):
    try:
        with open(path, "rb") as f:
            return hashlib.sha256(f.read()).hexdigest()
    except OSError:
        return None

# Canonical ground-truth set: top-level files + tests/ subdir, recursively.
# Mirrors leadv2-drift-guard.sh's own comparison scope exactly (H4 fix there).
canon_relpaths = []
for fn in sorted(os.listdir(canonical)):
    full = os.path.join(canonical, fn)
    if os.path.isfile(full):
        canon_relpaths.append(fn)
tests_dir = os.path.join(canonical, "tests")
if os.path.isdir(tests_dir):
    for root, _dirs, files in os.walk(tests_dir):
        for fn in files:
            full = os.path.join(root, fn)
            rel = os.path.relpath(full, canonical)
            canon_relpaths.append(rel)
canon_set = set(canon_relpaths)

would_link = []
ambiguous = []
already_linked = []
missing_in_repo = []

for rel in sorted(canon_relpaths):
    dest = os.path.join(proj, rel)
    canon_file = os.path.join(canonical, rel)
    if os.path.islink(dest):
        already_linked.append(rel)
        continue
    if not os.path.isfile(dest):
        missing_in_repo.append(rel)
        continue
    if sha256_file(dest) == sha256_file(canon_file):
        would_link.append(rel)
    else:
        ambiguous.append(rel)

# would-leave-native: every real file under proj (top-level + tests/,
# mirroring canon_relpaths' own scope) whose relpath is NOT in canon_set.
native = []
for fn in sorted(os.listdir(proj)) if os.path.isdir(proj) else []:
    full = os.path.join(proj, fn)
    if os.path.isfile(full) and fn not in canon_set:
        native.append(fn)
proj_tests = os.path.join(proj, "tests")
if os.path.isdir(proj_tests):
    for root, _dirs, files in os.walk(proj_tests):
        for fn in files:
            full = os.path.join(root, fn)
            rel = os.path.relpath(full, proj)
            if rel not in canon_set:
                native.append(rel)

print("---WOULD_LINK---")
for r in would_link: print(r)
print("---AMBIGUOUS---")
for r in ambiguous: print(r)
print("---NATIVE---")
for r in native: print(r)
print("---ALREADY_LINKED---")
for r in already_linked: print(r)
print("---MISSING_IN_REPO---")
for r in missing_in_repo: print(r)
print("---COUNTS---")
print(f"would_link={len(would_link)}")
print(f"ambiguous={len(ambiguous)}")
print(f"native={len(native)}")
print(f"already_linked={len(already_linked)}")
print(f"missing_in_repo={len(missing_in_repo)}")
PYEOF
)"

# Write full lists to the report file, print only counts + report path.
printf -- '%s\n' "${RESULT}" > "${REPORT_FILE}"
echo "=== leadv2-scripts-symlink-plan: ${REPO_ROOT} ==="
grep '^[a-z_]*=' "${REPORT_FILE}"
echo "full lists: ${REPORT_FILE}"

if [[ "${MODE}" == "apply" ]]; then
  TS="$(date -u '+%Y%m%dT%H%M%SZ')"
  BACKUP_DIR="${REPO_ROOT}/.claude/scripts-vendor-backup-${TS}"
  applied=0
  in_section=""
  while IFS= read -r line; do
    case "${line}" in
      "---WOULD_LINK---") in_section="wl"; continue ;;
      "---AMBIGUOUS---"|"---NATIVE---"|"---ALREADY_LINKED---"|"---MISSING_IN_REPO---"|"---COUNTS---") in_section=""; continue ;;
    esac
    if [[ "${in_section}" == "wl" && -n "${line}" ]]; then
      dest="${PROJ_SCRIPTS}/${line}"
      canon_file="${CANONICAL_SCRIPTS}/${line}"
      backup_file="${BACKUP_DIR}/${line}"
      mkdir -p "$(dirname "${backup_file}")"
      mv "${dest}" "${backup_file}"
      ln -s "${canon_file}" "${dest}"
      applied=$((applied + 1))
    fi
  done < "${REPORT_FILE}"
  echo "APPLIED: ${applied} file(s) converted to per-file symlinks. Backup + rollback: ${BACKUP_DIR}"
  echo "Rollback command: leadv2-scripts-symlink-plan.sh ${REPO_ROOT} --rollback ${BACKUP_DIR}"
fi
