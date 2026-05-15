#!/usr/bin/env bash
# leadv2-offlimits-check.sh — structural off_limits enforcement (AST + import-graph)
# Usage: leadv2-offlimits-check.sh --context <path-to-context.yaml> [--start-sha <sha>]
#
# Exit codes:
#   0 = pass
#   2 = direct file or rename match → BLOCK
#   3 = import-graph match (changed file imports off_limits module) → BLOCK
#   4 = warning only (re-export detected, transitive import)
#
# Writes YAML diagnostics to stderr.
set -euo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
readonly REPO_ROOT

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log()       { printf -- '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }
log_info()  { log "INFO:  $*"; }
log_error() { log "ERROR: $*"; }
log_warn()  { log "WARN:  $*"; }

emit_yaml() {
  # Write structured YAML result to stderr
  printf -- '%s\n' "$1" >&2
}

# ---------------------------------------------------------------------------
# Args
# ---------------------------------------------------------------------------
CONTEXT_YAML=""
START_SHA=""

usage() {
  printf -- 'Usage: %s --context <path-to-context.yaml> [--start-sha <sha>]\n' "$(basename "$0")" >&2
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --context)   CONTEXT_YAML="${2:-}"; shift 2 ;;
    --start-sha) START_SHA="${2:-}";    shift 2 ;;
    -h|--help)   usage ;;
    *) log_error "Unknown argument: $1"; usage ;;
  esac
done

[[ -z "$CONTEXT_YAML" ]] && { log_error "--context is required"; usage; }
[[ -f "$CONTEXT_YAML" ]] || { log_error "context.yaml not found: ${CONTEXT_YAML}"; exit 2; }

# Refuse interactive when no tty
if [[ ! -t 0 && "${FORCE_INTERACTIVE:-}" != "true" ]]; then
  log_info "No TTY — non-interactive mode"
fi

cd "$REPO_ROOT"

# ---------------------------------------------------------------------------
# Resolve start SHA
# ---------------------------------------------------------------------------
if [[ -z "$START_SHA" ]]; then
  # Try to read from context.yaml
  START_SHA="$(python3 -c "
import sys, re
with open('${CONTEXT_YAML}') as f:
    content = f.read()
m = re.search(r'start_sha:\s*([a-f0-9]{7,40})', content)
if m:
    print(m.group(1))
else:
    import subprocess
    result = subprocess.run(['git', 'merge-base', 'HEAD', 'main'],
                           capture_output=True, text=True)
    print(result.stdout.strip())
" 2>/dev/null || git merge-base HEAD main)"
fi

log_info "Checking diff from ${START_SHA}..HEAD"

# ---------------------------------------------------------------------------
# Extract off_limits list from context.yaml
# ---------------------------------------------------------------------------
OFF_LIMITS_LIST="$(python3 - "${CONTEXT_YAML}" <<'PYEOF'
import sys, re

path = sys.argv[1]
with open(path) as f:
    content = f.read()

# Simple YAML parsing for off_limits list (no external deps)
in_block = False
items = []
for line in content.splitlines():
    if re.match(r'^off_limits\s*:', line):
        in_block = True
        continue
    if in_block:
        m = re.match(r'^\s+-\s+(.+)', line)
        if m:
            items.append(m.group(1).strip().strip('"\''))
        elif line and not line.startswith(' ') and not line.startswith('\t'):
            break
for item in items:
    print(item)
PYEOF
)"

if [[ -z "$OFF_LIMITS_LIST" ]]; then
  log_info "No off_limits entries in context.yaml — check passes"
  emit_yaml '{"check": "off_limits", "result": "pass", "details": {"reason": "no off_limits defined"}}'
  exit 0
fi

log_info "off_limits entries:"
printf -- '%s\n' "$OFF_LIMITS_LIST" | while read -r entry; do log_info "  $entry"; done

# ---------------------------------------------------------------------------
# Python helper script (stdlib only: ast, json, pathlib)
# Written to a temp file to avoid heredoc stdin conflicts
# ---------------------------------------------------------------------------
PY_HELPER="$(mktemp /tmp/leadv2-offlimits-XXXXXX.py)"

# shellcheck disable=SC2329
cleanup() { rm -f "$PY_HELPER"; }
trap 'cleanup' EXIT

python3 - "$PY_HELPER" <<'PYEOF'
import sys, pathlib

dest = sys.argv[1]
code = r'''
import ast
import json
import sys
import pathlib
import subprocess
import re

def resolve_module_to_path(module_name: str, repo_root: str) -> list[str]:
    """Convert dotted module name to potential file paths relative to repo root."""
    parts = module_name.split(".")
    candidates = []
    # package/module.py
    candidates.append("/".join(parts) + ".py")
    # package/module/__init__.py
    candidates.append("/".join(parts) + "/__init__.py")
    # top-level only
    if len(parts) >= 2:
        candidates.append(parts[0] + "/" + "/".join(parts[1:]) + ".py")
    return [c for c in candidates if pathlib.Path(repo_root, c).exists()]

def get_imports(filepath: str) -> list[dict]:
    """Parse Python file and return all import statements."""
    try:
        src = pathlib.Path(filepath).read_text(encoding="utf-8", errors="replace")
        tree = ast.parse(src, filename=filepath)
    except SyntaxError:
        return []
    imports = []
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                imports.append({"type": "import", "module": alias.name, "line": node.lineno})
        elif isinstance(node, ast.ImportFrom):
            if node.module:
                base = "." * (node.level or 0) + node.module
                names = [a.name for a in node.names]
                imports.append({"type": "from", "module": base, "names": names, "line": node.lineno})
    return imports

def is_reexport_only(filepath: str, off_limits_paths: list[str]) -> bool:
    """Detect thin re-export wrappers: file only imports from off_limits and re-exports."""
    try:
        src = pathlib.Path(filepath).read_text(encoding="utf-8", errors="replace")
        tree = ast.parse(src, filename=filepath)
    except SyntaxError:
        return False
    stmts = [n for n in ast.walk(tree) if isinstance(n, ast.stmt)]
    import_stmts = [n for n in stmts if isinstance(n, (ast.Import, ast.ImportFrom))]
    non_import = [n for n in stmts if not isinstance(n, (ast.Import, ast.ImportFrom,
                                                          ast.Expr, ast.Pass, ast.If,
                                                          ast.Try))]
    if non_import:
        return False
    # Check if all imports are from off_limits
    for node in import_stmts:
        if isinstance(node, ast.ImportFrom) and node.module:
            resolved = resolve_module_to_path(node.module, repo_root)
            if any(any(p == r or r.startswith(p.rstrip("/")) for p in off_limits_paths)
                   for r in resolved):
                return True
    return False

def normalize_off_limits(off_limits_raw: list[str], repo_root: str) -> list[str]:
    """Normalize off_limits entries to relative file paths where possible."""
    normalized = []
    for entry in off_limits_raw:
        p = pathlib.Path(repo_root, entry)
        if p.exists():
            normalized.append(str(p.relative_to(repo_root)))
        else:
            # Try as module path
            resolved = resolve_module_to_path(entry, repo_root)
            if resolved:
                normalized.extend(resolved)
            else:
                normalized.append(entry)  # keep as-is (may be a directory prefix)
    return list(dict.fromkeys(normalized))  # deduplicate, preserve order

def path_matches_off_limits(path: str, off_limits: list[str]) -> bool:
    """Check if path matches any off_limits entry (exact or prefix)."""
    for ol in off_limits:
        if path == ol:
            return True
        if ol.endswith("/") and path.startswith(ol):
            return True
        if path.startswith(ol.rstrip("/") + "/"):
            return True
    return False

# ── Main ────────────────────────────────────────────────────────────────────

repo_root = sys.argv[1]
start_sha = sys.argv[2]
off_limits_raw = sys.argv[3].splitlines()

off_limits = normalize_off_limits(off_limits_raw, repo_root)
results = {
    "direct": {"result": "pass", "matches": []},
    "rename": {"result": "pass", "matches": []},
    "import_graph": {"result": "pass", "matches": []},
    "reexport": {"result": "pass", "matches": []},
}
exit_code = 0

# ── Check A: Direct file diff ─────────────────────────────────────────────
diff_files_raw = subprocess.run(
    ["git", "diff", "--name-only", f"{start_sha}..HEAD"],
    capture_output=True, text=True, cwd=repo_root
).stdout.strip()
diff_files = [f for f in diff_files_raw.splitlines() if f]

for f in diff_files:
    if path_matches_off_limits(f, off_limits):
        results["direct"]["matches"].append(f)

if results["direct"]["matches"]:
    results["direct"]["result"] = "block"
    exit_code = max(exit_code, 2)

# ── Check B: Rename check ────────────────────────────────────────────────
diff_status_raw = subprocess.run(
    ["git", "diff", "--name-status", f"{start_sha}..HEAD"],
    capture_output=True, text=True, cwd=repo_root
).stdout.strip()

for line in diff_status_raw.splitlines():
    if line.startswith("R"):
        parts = line.split("\t")
        if len(parts) >= 3:
            src, dst = parts[1], parts[2]
            if path_matches_off_limits(src, off_limits) or path_matches_off_limits(dst, off_limits):
                results["rename"]["matches"].append({"from": src, "to": dst})

if results["rename"]["matches"]:
    results["rename"]["result"] = "block"
    exit_code = max(exit_code, 2)

# ── Check C: Import-graph check ──────────────────────────────────────────
py_changed = [f for f in diff_files if f.endswith(".py")]

for pyfile in py_changed:
    abs_path = str(pathlib.Path(repo_root, pyfile))
    if not pathlib.Path(abs_path).exists():
        continue
    imports = get_imports(abs_path)
    for imp in imports:
        module = imp["module"].lstrip(".")
        resolved_paths = resolve_module_to_path(module, repo_root)
        for rp in resolved_paths:
            if path_matches_off_limits(rp, off_limits):
                results["import_graph"]["matches"].append({
                    "importer": pyfile,
                    "imported_module": module,
                    "resolved": rp,
                    "line": imp["line"],
                    "depth": 1,
                })
                break
            # Depth-2: check if resolved path itself imports from off_limits
            abs_resolved = str(pathlib.Path(repo_root, rp))
            if pathlib.Path(abs_resolved).exists():
                sub_imports = get_imports(abs_resolved)
                for si in sub_imports:
                    sub_module = si["module"].lstrip(".")
                    sub_resolved = resolve_module_to_path(sub_module, repo_root)
                    for sr in sub_resolved:
                        if path_matches_off_limits(sr, off_limits):
                            results["import_graph"]["matches"].append({
                                "importer": pyfile,
                                "imported_module": module,
                                "resolved": rp,
                                "transitive_via": sr,
                                "line": imp["line"],
                                "depth": 2,
                                "warning_only": True,
                            })

if results["import_graph"]["matches"]:
    # Depth-1 = block; depth-2 = warning only
    depth1 = [m for m in results["import_graph"]["matches"] if m.get("depth", 1) == 1]
    depth2 = [m for m in results["import_graph"]["matches"] if m.get("depth", 1) == 2]
    if depth1:
        results["import_graph"]["result"] = "block"
        exit_code = max(exit_code, 3)
    elif depth2:
        results["import_graph"]["result"] = "warn"
        exit_code = max(exit_code, 4)

# ── Check D: Re-export detection ─────────────────────────────────────────
for pyfile in py_changed:
    abs_path = str(pathlib.Path(repo_root, pyfile))
    if not pathlib.Path(abs_path).exists():
        continue
    if is_reexport_only(abs_path, off_limits):
        results["reexport"]["matches"].append({"file": pyfile})

if results["reexport"]["matches"]:
    results["reexport"]["result"] = "warn"
    exit_code = max(exit_code, 4)

# ── Aggregate result ─────────────────────────────────────────────────────
overall = "pass"
if exit_code == 2:
    overall = "block"
elif exit_code == 3:
    overall = "block"
elif exit_code >= 4:
    overall = "warn"

output = {
    "check": "off_limits",
    "result": overall,
    "exit_code": exit_code,
    "off_limits": off_limits,
    "details": results,
}
print(json.dumps(output, indent=2))
sys.exit(exit_code)
'''
pathlib.Path(dest).write_text(code)
PYEOF

# ---------------------------------------------------------------------------
# Run the Python checker
# ---------------------------------------------------------------------------
log_info "Running structural off_limits check"

set +e
RESULT_JSON="$(python3 "$PY_HELPER" "$REPO_ROOT" "$START_SHA" "$OFF_LIMITS_LIST" 2>/dev/null)"
CHECK_RC=$?
set -e

if [[ -z "$RESULT_JSON" ]]; then
  log_error "off_limits checker produced no output (possible syntax/import error)"
  emit_yaml '{"check": "off_limits", "result": "error", "details": {"reason": "checker script failed"}}'
  exit 2
fi

emit_yaml "$RESULT_JSON"

# ---------------------------------------------------------------------------
# Human-readable summary
# ---------------------------------------------------------------------------
OVERALL="$(printf -- '%s' "$RESULT_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['result'])")"

case "$OVERALL" in
  pass)
    log_info "off_limits check: PASS"
    ;;
  warn)
    log_warn "off_limits check: WARN — re-export or transitive import detected (not blocking)"
    ;;
  block)
    log_error "off_limits check: BLOCK — diff touches restricted paths"
    ;;
  *)
    log_error "off_limits check: UNKNOWN result '${OVERALL}'"
    ;;
esac

exit $CHECK_RC
