#!/usr/bin/env bash
# regression-density.sh — analyze git log for regression commit density per module
#
# Usage: regression-density.sh [--since YYYY-MM-DD] [--min-total N]
# Default --since: 2026-01-01, --min-total 10 (filters noise from tiny modules)
#
# Output: sorted table of modules by regression density.
# On interactive 'y', writes top3.yaml and appends tasks to docs/tasks.yaml.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
readonly REPO_ROOT
readonly HANDOFF_DIR="${REPO_ROOT}/docs/handoff/REGR-DENSITY-01"
readonly TASKS_YAML="${REPO_ROOT}/docs/tasks.yaml"

log()       { printf -- '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }
log_info()  { log "INFO: $*"; }
log_error() { log "ERROR: $*"; }

# ── argument parsing ──────────────────────────────────────────────────────────
SINCE="2026-01-01"
MIN_TOTAL="10"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --since)
      SINCE="${2:?--since requires a date argument}"
      shift 2
      ;;
    --since=*)
      SINCE="${1#--since=}"
      shift
      ;;
    --min-total)
      MIN_TOTAL="${2:?--min-total requires a number}"
      shift 2
      ;;
    --min-total=*)
      MIN_TOTAL="${1#--min-total=}"
      shift
      ;;
    *)
      printf -- 'Usage: %s [--since YYYY-MM-DD] [--min-total N]\n' "$0" >&2
      exit 1
      ;;
  esac
done

# ── dependency checks ─────────────────────────────────────────────────────────
git rev-parse --git-dir >/dev/null 2>&1 || { log_error "not a git repo"; exit 1; }
command -v python3 >/dev/null 2>&1 || { log_error "python3 required"; exit 1; }

# ── temp files ────────────────────────────────────────────────────────────────
PY_SCRIPT=$(mktemp /tmp/regr-density-XXXXXX.py)
GIT_LOG_FILE=$(mktemp /tmp/regr-gitlog-XXXXXX.txt)
trap 'rm -f "${PY_SCRIPT}" "${GIT_LOG_FILE}"' EXIT

cat > "${PY_SCRIPT}" <<'PYEOF'
import sys
import re
from collections import defaultdict

SINCE = sys.argv[1]
log_file = sys.argv[2]
MIN_TOTAL = int(sys.argv[3]) if len(sys.argv) > 3 else 10

with open(log_file, "r", encoding="utf-8") as fh:
    raw = fh.read()

REGR_SUBJECT_RE = re.compile(
    r'^(fix:|revert:|bug:|hotfix:|RECOVERY-)',
    re.IGNORECASE
)
REGR_BODY_RE = re.compile(r'\bregression\b', re.IGNORECASE)

module_stats: dict = defaultdict(lambda: {"total": 0, "regr": 0, "last_regr": None})

def get_module(path: str) -> str:
    path = path.strip().lstrip('"')  # git quotes non-ASCII paths with leading "
    if not path:
        return ""
    parts = path.split("/")
    if len(parts) == 1:
        return "root"
    return parts[0] + "/"

current_hash = None
current_subject = None
current_date = ""
current_files: list = []

def flush_commit() -> None:
    if current_hash is None or current_subject is None:
        return
    is_regr = bool(REGR_SUBJECT_RE.match(current_subject)) or bool(REGR_BODY_RE.search(current_subject))

    touched_modules: set = set()
    for f in current_files:
        mod = get_module(f)
        if mod:
            touched_modules.add(mod)
    if not touched_modules:
        touched_modules.add("root")

    for mod in touched_modules:
        module_stats[mod]["total"] += 1
        if is_regr:
            module_stats[mod]["regr"] += 1
            existing = module_stats[mod]["last_regr"]
            if existing is None or current_date > existing:
                module_stats[mod]["last_regr"] = current_date

for line in raw.splitlines():
    if line.startswith("COMMIT "):
        flush_commit()
        # Format: COMMIT <hash> <YYYY-MM-DD> <subject...>
        parts = line.split(" ", 3)
        current_hash = parts[1] if len(parts) > 1 else "unknown"
        current_date = parts[2] if len(parts) > 2 else ""
        current_subject = parts[3] if len(parts) > 3 else ""
        current_files = []
    elif line.strip() == "":
        pass
    else:
        current_files.append(line.strip())

flush_commit()

if not module_stats:
    print("NO_DATA")
    sys.exit(0)

results = []
for mod, s in module_stats.items():
    total = s["total"]
    regr = s["regr"]
    density = regr / total if total > 0 else 0.0
    last_regr = s["last_regr"] or "-"
    results.append((mod, regr, total, density, last_regr))

results.sort(key=lambda x: (-x[3], -x[1], x[0]))

header = "{:<22} {:>5} {:>6} {:>8}  LAST_REGR".format("MODULE", "REGR", "TOTAL", "DENSITY")
sep    = "-" * len(header)
print(header)
print(sep)
for mod, regr, total, density, last_regr in results:
    print("{:<22} {:>5} {:>6} {:>8.3f}  {}".format(mod, regr, total, density, last_regr))

print("")
filtered = [r for r in results if r[2] >= MIN_TOTAL]
top3 = filtered[:3]
noise = [r for r in results[:3] if r[2] < MIN_TOTAL]
print("Top-3 hotspot modules (density desc, min_total={})".format(MIN_TOTAL) + ":")
if top3:
    for rank, (mod, regr, total, density, last_regr) in enumerate(top3, 1):
        print("  {}. {:<20} density={:.3f}  regr={}/{}  last={}".format(
            rank, mod, density, regr, total, last_regr))
else:
    print("  (no modules with >= {} commits)".format(MIN_TOTAL))
if noise:
    print("  [excluded noise: {}]".format(", ".join("{} ({} commits)".format(r[0],r[2]) for r in noise)))

print("")
print("TOP_DATA_START")
for rank, (mod, regr, total, density, last_regr) in enumerate(top3, 1):
    print("{}|{}|{}|{}|{:.3f}|{}".format(rank, mod, regr, total, density, last_regr))
print("TOP_DATA_END")
PYEOF

# ── collect git log into temp file ───────────────────────────────────────────
log_info "Collecting git log since ${SINCE} ..."

git -C "${REPO_ROOT}" log \
  --since="${SINCE}" \
  --format="COMMIT %H %as %s" \
  --name-only \
  -- . \
  2>/dev/null > "${GIT_LOG_FILE}" || { log_error "git log failed"; exit 1; }

if [[ ! -s "${GIT_LOG_FILE}" ]]; then
  printf -- '\nNo commits found since %s.\n' "${SINCE}"
  exit 0
fi

# ── run analysis ──────────────────────────────────────────────────────────────
ANALYSIS=$(python3 "${PY_SCRIPT}" "${SINCE}" "${GIT_LOG_FILE}" "${MIN_TOTAL}")

# ── handle NO_DATA ────────────────────────────────────────────────────────────
if printf -- '%s\n' "${ANALYSIS}" | grep -q '^NO_DATA$'; then
  printf -- '\nNo module data found for commits since %s.\n' "${SINCE}"
  exit 0
fi

# ── print the table ───────────────────────────────────────────────────────────
# Print everything above TOP_DATA_START
printf -- '%s\n' "${ANALYSIS}" | awk '/^TOP_DATA_START$/{exit} {print}'

# ── extract top-3 structured data ─────────────────────────────────────────────
TOP_DATA=$(printf -- '%s\n' "${ANALYSIS}" | \
  awk '/^TOP_DATA_START$/{found=1; next} /^TOP_DATA_END$/{found=0} found{print}')

if [[ -z "${TOP_DATA}" ]]; then
  log_info "No top-3 data available."
  exit 0
fi

# ── prompt ────────────────────────────────────────────────────────────────────
printf -- 'Confirm top-3 for QUEUE follow-up? [y/N]: '
read -r ANSWER </dev/tty || ANSWER="N"

if [[ "${ANSWER,,}" != "y" ]]; then
  printf -- 'Skipped.\n'
  exit 0
fi

# ── write top3.yaml ───────────────────────────────────────────────────────────
mkdir -p "${HANDOFF_DIR}"
NOW_ISO=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
TOP3_YAML="${HANDOFF_DIR}/top3.yaml"

{
  printf -- 'generated_at: "%s"\n' "${NOW_ISO}"
  printf -- 'since: "%s"\n' "${SINCE}"
  printf -- 'top3:\n'
  while IFS='|' read -r _rank mod regr total density last_regr; do
    printf -- '  - module: "%s"\n' "${mod}"
    printf -- '    regression_count: %s\n' "${regr}"
    printf -- '    total_commits: %s\n' "${total}"
    printf -- '    density: %s\n' "${density}"
    printf -- '    last_regression_date: "%s"\n' "${last_regr}"
  done <<< "${TOP_DATA}"
} > "${TOP3_YAML}"

log_info "Wrote ${TOP3_YAML}"

# ── append tasks to docs/tasks.yaml ──────────────────────────────────────────
# Compute N months from since to today
MONTHS_COUNT=$(python3 - "${SINCE}" <<'PYEOF2'
import sys
from datetime import date
since = date.fromisoformat(sys.argv[1])
today = date.today()
months = (today.year - since.year) * 12 + (today.month - since.month)
print(max(1, months))
PYEOF2
)

while IFS='|' read -r _rank mod regr total density last_regr; do
  # Sanitize module name for task id: strip trailing slash, uppercase, replace / with -
  MOD_CLEAN=$(printf -- '%s' "${mod}" | tr '/' '-' | tr -d '.' | sed 's/-$//' | tr '[:lower:]' '[:upper:]')
  TASK_ID="REGR-HOTSPOT-${MOD_CLEAN}-01"

  # Check if task already exists in tasks.yaml
  if grep -q "id: ${TASK_ID}" "${TASKS_YAML}" 2>/dev/null; then
    log_info "Task ${TASK_ID} already exists in tasks.yaml — skipping."
    continue
  fi

  {
    printf -- '- id: %s\n' "${TASK_ID}"
    printf -- '  lane: action\n'
    printf -- '  priority: low\n'
    printf -- '  status: pending\n'
    printf -- '  title: "Regression hotspot %s: density %s over last %s months — review + add guards"\n' \
      "${mod}" "${density}" "${MONTHS_COUNT}"
    printf -- '  created_at: "%s"\n' "${NOW_ISO}"
    printf -- '  closed_at: null\n'
    printf -- '  origin: regression-density-%s\n' "$(date -u '+%Y-%m-%d')"
    printf -- '  claim:\n'
    printf -- '    by: null\n'
    printf -- '    lease_expires: null\n'
    printf -- '  attempts: 0\n'
    printf -- '  max_attempts: 3\n'
    printf -- '  last_error: null\n'
    printf -- '  reject_reason: null\n'
    printf -- '  summary_one_line: null\n'
    printf -- '  context:\n'
    printf -- '    files: []\n'
    printf -- '    depends_on: []\n'
    printf -- '    note: "regression-density.sh top-3: density=%s, regr_count=%s, total=%s"\n' \
      "${density}" "${regr}" "${total}"
    printf -- '  notes: null\n'
  } >> "${TASKS_YAML}"

  log_info "Appended task ${TASK_ID} to ${TASKS_YAML}"
done <<< "${TOP_DATA}"

printf -- '\nDone. top3.yaml written and tasks appended to docs/tasks.yaml.\n'
