#!/usr/bin/env bash
# leadv2-rules-load.sh — Load and validate .rule.md files for the quality engine.
#
# Usage:
#   leadv2-rules-load.sh [--validate-only]
#
# Reads per-repo config via _lv2_load_quality_engine_config().
# Config keys used (l_a block):
#   rules_dir   — directory containing *.rule.md files
#   rule_glob   — glob pattern (default: *.rule.md)
#
# Output (stdout, JSON):
#   { "rules": [...], "count": N, "warnings": [...] }
#
# Exit codes:
#   0 = ok (all rules loaded and valid)
#   3 = at least one rule file failed schema validation
#   4 = quality_engine disabled or missing (no-op)

set -euo pipefail

# shellcheck source=./leadv2-helpers.sh
source "$(dirname "$(readlink -f "$0")")/leadv2-helpers.sh"

_lv2_load_quality_engine_config "l_a" || exit 4

log()       { printf -- '[leadv2-rules-load] %s\n' "$*" >&2; }
log_warn()  { printf -- '[leadv2-rules-load] WARN: %s\n' "$*" >&2; }
log_error() { printf -- '[leadv2-rules-load] ERROR: %s\n' "$*" >&2; }

# ── argument parsing ──────────────────────────────────────────────────────────
VALIDATE_ONLY=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --validate-only) VALIDATE_ONLY=true; shift ;;
    -h|--help)
      printf -- 'Usage: leadv2-rules-load.sh [--validate-only]\n' >&2
      exit 0
      ;;
    *) log_error "unknown argument: $1"; exit 2 ;;
  esac
done

# ── resolve config paths ──────────────────────────────────────────────────────
RULES_DIR="${LV2_QE_L_A_RULES_DIR:-}"
RULE_GLOB="${LV2_QE_L_A_RULE_GLOB:-*.rule.md}"
SCHEMA_FILE="$(dirname "$(readlink -f "$0")")/../contracts/leadv2-rule.schema.json"

if [[ -z "$RULES_DIR" ]]; then
  RULES_DIR="${LEADV2_PROJECT_ROOT}/.claude/leadv2-overrides/rules"
fi

# Make absolute
if [[ "${RULES_DIR}" != /* ]]; then
  RULES_DIR="${LEADV2_PROJECT_ROOT}/${RULES_DIR}"
fi

if [[ ! -d "$RULES_DIR" ]]; then
  log "rules_dir not found: $RULES_DIR — emitting empty rule set"
  printf -- '{"rules":[],"count":0,"warnings":["rules_dir_not_found"]}\n'
  exit 0
fi

# ── Python-based loader ───────────────────────────────────────────────────────
# Uses python-frontmatter (or manual YAML fence parse as fallback) to extract
# YAML frontmatter from .rule.md files.

python3 - "$RULES_DIR" "$RULE_GLOB" "$SCHEMA_FILE" "$VALIDATE_ONLY" <<'PYEOF'
import sys
import os
import json
import re
import glob

rules_dir    = sys.argv[1]
rule_glob    = sys.argv[2]
schema_file  = sys.argv[3]
validate_only = sys.argv[4].lower() == "true"

# Try to import yaml; if not available, error cleanly.
try:
    import yaml
except ImportError:
    print(json.dumps({"rules": [], "count": 0, "warnings": ["yaml_not_installed"]}))
    sys.exit(3)

# Load JSON schema for validation (optional — skip if schema file missing)
schema = None
try:
    with open(schema_file) as sf:
        schema = json.load(sf)
except (FileNotFoundError, json.JSONDecodeError) as e:
    print(f"[leadv2-rules-load] WARN: schema not loaded: {e}", file=sys.stderr)

def validate_against_schema(data: dict, schema: dict | None) -> list[str]:
    """Minimal JSON Schema validator (subset: required + enum + type + pattern)."""
    if schema is None:
        return []
    errors = []
    required = schema.get("required", [])
    for req in required:
        if req not in data:
            errors.append(f"missing required field: {req}")
    props = schema.get("properties", {})
    for k, v in data.items():
        if k not in props:
            continue
        prop_schema = props[k]
        # type check
        type_map = {"string": str, "integer": int, "number": (int, float), "object": dict, "array": list, "boolean": bool}
        if "type" in prop_schema:
            expected = type_map.get(prop_schema["type"])
            if expected and not isinstance(v, expected):
                errors.append(f"field '{k}': expected {prop_schema['type']}, got {type(v).__name__}")
        # enum check
        if "enum" in prop_schema and v not in prop_schema["enum"]:
            errors.append(f"field '{k}': value '{v}' not in enum {prop_schema['enum']}")
        # pattern check (strings)
        if "pattern" in prop_schema and isinstance(v, str):
            if not re.match(prop_schema["pattern"], v):
                errors.append(f"field '{k}': value '{v}' does not match pattern {prop_schema['pattern']!r}")
        # nested object validation (scan, match, aggregate, check)
        if isinstance(v, dict) and "properties" in prop_schema:
            sub_errs = validate_against_schema(v, prop_schema)
            errors.extend(f"{k}.{e}" for e in sub_errs)
    return errors

def parse_frontmatter(text: str) -> tuple[dict | None, str]:
    """Extract YAML frontmatter from markdown. Returns (data, body)."""
    if not text.startswith("---"):
        return None, text
    end = text.find("\n---", 3)
    if end == -1:
        return None, text
    fm_text = text[3:end].strip()
    body = text[end + 4:].strip()
    try:
        data = yaml.safe_load(fm_text)
        return data, body
    except yaml.YAMLError as e:
        return None, str(e)

# Glob rule files
pattern = os.path.join(rules_dir, rule_glob)
files = sorted(glob.glob(pattern))

rules = []
warnings = []
has_error = False

for filepath in files:
    filename = os.path.basename(filepath)
    try:
        with open(filepath) as fh:
            content = fh.read()
    except OSError as e:
        warnings.append(f"cannot_read:{filename}:{e}")
        has_error = True
        print(f"[leadv2-rules-load] ERROR: cannot read {filepath}: {e}", file=sys.stderr)
        continue

    data, body = parse_frontmatter(content)
    if data is None:
        warnings.append(f"no_frontmatter:{filename}")
        has_error = True
        print(f"[leadv2-rules-load] ERROR: no frontmatter in {filepath}", file=sys.stderr)
        continue

    # Schema validation
    errs = validate_against_schema(data, schema)
    if errs:
        for e in errs:
            print(f"[leadv2-rules-load] ERROR: schema violation in {filename}: {e}", file=sys.stderr)
        warnings.append(f"schema_invalid:{filename}")
        has_error = True
        if validate_only:
            continue
        # Still include rule but mark invalid
        data["_schema_errors"] = errs

    # Skip stale low-severity rules (seen_count == 0 AND severity in low/medium)
    seen_count = data.get("seen_count", 0)
    severity = data.get("severity", "medium")
    if seen_count == 0 and severity in ("low",):
        print(f"[leadv2-rules-load] INFO: skipping stale low rule {data.get('id', filename)}", file=sys.stderr)
        continue

    # Attach body as remediation text
    data["_remediation"] = body
    data["_source_file"] = filename
    rules.append(data)

result = {"rules": rules, "count": len(rules), "warnings": warnings}
print(json.dumps(result))
sys.exit(3 if has_error else 0)
PYEOF

EXIT_CODE=$?
exit $EXIT_CODE
