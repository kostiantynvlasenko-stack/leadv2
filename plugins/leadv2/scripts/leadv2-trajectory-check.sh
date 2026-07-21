#!/usr/bin/env bash
# leadv2-trajectory-check.sh — structural trajectory gate for /leadv2 Phase 5 Review
#
# Usage:
#   leadv2-trajectory-check.sh --task-id <id> --class <Light|Standard|Heavy>
#
# Options:
#   --task-id  <id>           Handoff task directory name (under docs/handoff/)
#   --class    <class>        Task classification: Light | Standard | Heavy
#   --handoff-root <path>     Override handoff root (default: docs/handoff)
#
# Exit codes:
#   0  Trajectory ok — proceed to Phase 5 reviewers
#   1  Trajectory mismatch — missing events or strict-mode extras; redo missing phase
#   2  Error — bad arguments, missing files, Python import failure

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/leadv2-temp.sh"

# ── Constants ───────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
readonly REPO_ROOT

# shellcheck source=leadv2-helpers.sh
source "${SCRIPT_DIR}/leadv2-helpers.sh" || { echo "FATAL: cannot source leadv2-helpers.sh" >&2; exit 1; }

# ── Logging ─────────────────────────────────────────────────────────────────
log()       { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }
log_error() { log "ERROR: $*"; }
log_info()  { log "INFO:  $*"; }

# ── Argument parsing ─────────────────────────────────────────────────────────
TASK_ID=""
TASK_CLASS=""
HANDOFF_ROOT="${REPO_ROOT}/docs/handoff"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --task-id)
      TASK_ID="$2"; shift 2 ;;
    --class)
      TASK_CLASS="$2"; shift 2 ;;
    --handoff-root)
      HANDOFF_ROOT="$2"; shift 2 ;;
    *)
      log_error "Unknown argument: $1"
      exit 2 ;;
  esac
done

# ── Validation ───────────────────────────────────────────────────────────────
if [[ -z "${TASK_ID}" ]]; then
  log_error "--task-id is required"
  exit 2
fi

if [[ -z "${TASK_CLASS}" ]]; then
  log_error "--class is required (Light|Standard|Heavy)"
  exit 2
fi

if [[ ! "${TASK_CLASS}" =~ ^(Light|Standard|Heavy)$ ]]; then
  log_error "Invalid --class value: ${TASK_CLASS}. Must be Light, Standard, or Heavy."
  exit 2
fi

HANDOFF_DIR="${HANDOFF_ROOT}/${TASK_ID}"
if [[ ! -d "${HANDOFF_DIR}" ]]; then
  log_error "Handoff directory not found: ${HANDOFF_DIR}"
  exit 2
fi

# ── Verify Python is available ───────────────────────────────────────────────
PYTHON="${PYTHON:-python3}"
if ! command -v "${PYTHON}" >/dev/null 2>&1; then
  log_error "python3 not found in PATH"
  exit 2
fi

# ── Run trajectory check ─────────────────────────────────────────────────────
log_info "Checking trajectory: task=${TASK_ID} class=${TASK_CLASS}"
log_info "Handoff dir: ${HANDOFF_DIR}"

RESULT_FILE="$(lv2_mktemp_file "trajectory-check" "json")"
trap 'rm -f "${RESULT_FILE}"' EXIT

# Run the module from repo root so relative imports resolve correctly.
# Stdout → JSON result (printed to our stdout).
# Stderr → one-line reason (printed to our stderr via the module).
set +e
"${PYTHON}" -c "
import sys, json
sys.path.insert(0, '${REPO_ROOT}')
# platform/ shadows stdlib platform — load via importlib
import importlib.util, pathlib
spec = importlib.util.spec_from_file_location(
    'platform.leadv2.trajectory_check',
    pathlib.Path('${REPO_ROOT}/platform/leadv2/trajectory_check.py')
)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
result = mod.check_trajectory(
    pathlib.Path('${HANDOFF_DIR}'),
    '${TASK_CLASS}'
)
print(json.dumps(result, indent=2))
sys.stderr.write(result['reason'] + '\n')
sys.exit(0 if result['ok'] else 1)
" 2>&1 | tee "${RESULT_FILE}"

PYTHON_RC="${PIPESTATUS[0]}"
set -e

# ── Write trajectory.yaml to handoff dir ─────────────────────────────────────
# Convert JSON result to YAML and persist for downstream reflection.
_traj_yaml=$("${PYTHON}" -c "
import sys, json, yaml, io
with open('${RESULT_FILE}') as f:
    raw = f.read()
# Extract only the JSON block (ignore any stderr lines mixed in by tee)
lines = []
in_json = False
for line in raw.splitlines():
    if line.strip().startswith('{'):
        in_json = True
    if in_json:
        lines.append(line)
data = json.loads('\n'.join(lines))
_buf = io.StringIO()
yaml.dump(data, _buf, default_flow_style=False, allow_unicode=True)
sys.stdout.write(_buf.getvalue())
" 2>/dev/null) || true
if [[ -n "$_traj_yaml" ]]; then
  _atomic_write_yaml "${HANDOFF_DIR}/trajectory.yaml" "$_traj_yaml" || true
fi

# ── Exit with trajectory check result ────────────────────────────────────────
if [[ "${PYTHON_RC}" -eq 0 ]]; then
  log_info "Trajectory OK — proceed to Phase 5 reviewers"
  exit 0
elif [[ "${PYTHON_RC}" -eq 1 ]]; then
  log_error "Trajectory mismatch — re-run missing phase(s) before review"
  exit 1
else
  log_error "Trajectory check failed with exit code ${PYTHON_RC}"
  exit 2
fi
