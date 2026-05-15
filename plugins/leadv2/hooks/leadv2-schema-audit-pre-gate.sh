#!/usr/bin/env bash
# leadv2-schema-audit-pre-gate.sh
# PreToolUse hook: scan new migration files for known schema pitfalls.
# NON-BLOCKING — emits additionalContext warnings only, never denies.
#
# Checks:
#   a) Partial unique index (WHERE clause) -> upsert without on_conflict predicate (HIGH)
#   b) Date index without timestamptz/UTC cast + code uses current_date (MEDIUM)
#   c) INSERT referencing columns not in the just-created table (HIGH)
#
# Trigger: PreToolUse Bash on git commit.
# Skip: no migration files in staged diff.

set -euo pipefail
trap 'exit 0' ERR

HOOK_NAME="leadv2-schema-audit-pre-gate"
REPO="${CLAUDE_PROJECT_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"

# ── PO-064: profiling ───────────────────────────────────────────────────────
_HOOK_START_MS=0
if [[ "${LEADV2_HOOK_PROFILE:-0}" == "1" ]]; then
  _HOOK_START_MS=$(python3 -c "import time; print(int(time.time()*1000))" 2>/dev/null || echo 0)
fi
_hook_profile_end() {
  if [[ "${LEADV2_HOOK_PROFILE:-0}" == "1" && "$_HOOK_START_MS" -gt 0 ]]; then
    local end_ms
    end_ms=$(python3 -c "import time; print(int(time.time()*1000))" 2>/dev/null || echo 0)
    local dur=$(( end_ms - _HOOK_START_MS ))
    mkdir -p "$HOME/.claude/state/leadv2"
    printf '%s,%s\n' "$HOOK_NAME" "$dur" \
      >> "$HOME/.claude/state/leadv2/hook-profile.log"
  fi
}
trap '_hook_profile_end; exit 0' EXIT

log_info() {
  printf -- '[%s] %s\n' "$HOOK_NAME" "$*" >&2
}

# ── mode detection ─────────────────────────────────────────────────────────────

MANUAL_MODE=0
if [[ $# -gt 0 ]]; then
  MANUAL_MODE=1
  INPUT=""
else
  INPUT=$(cat)

  TOOL_CMD=$(printf -- '%s' "$INPUT" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('tool_input', {}).get('command', ''))
except Exception:
    print('')
" 2>/dev/null || true)

  case "$TOOL_CMD" in
    *"git commit"*) : ;;
    *)
      printf -- '{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "allow"}}\n'
      exit 0
      ;;
  esac
fi

# ── find staged migration files ────────────────────────────────────────────────

MIGRATION_FILES=()
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  case "$f" in
    supabase/migrations/*.sql) MIGRATION_FILES+=("$REPO/$f") ;;
  esac
done < <(git -C "$REPO" diff --name-only --cached 2>/dev/null || true)

if [[ ${#MIGRATION_FILES[@]} -eq 0 ]]; then
  if [[ "$MANUAL_MODE" -eq 1 ]]; then
    log_info "No migration files in staged diff — skip"
    exit 0
  fi
  printf -- '{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "allow"}}\n'
  exit 0
fi

# ── analysis via Python ────────────────────────────────────────────────────────

FINDINGS=$(python3 << PYEOF
import re
import sys
import os

REPO = "$REPO"
migration_files = """${MIGRATION_FILES[*]}""".split()

findings = []

for mfile in migration_files:
    if not os.path.isfile(mfile):
        continue
    fname = os.path.basename(mfile)
    try:
        sql = open(mfile, encoding='utf-8').read()
    except OSError as e:
        findings.append(f"MEDIUM [{fname}] Could not read file: {e}")
        continue

    sql_upper = sql.upper()
    sql_lines = sql.splitlines()

    # ── (a) Partial unique index -> upsert without explicit on_conflict ────────
    partial_idx_tables = []
    for m in re.finditer(
        r'CREATE\s+(?:UNIQUE\s+)?INDEX\s+\S+\s+ON\s+(\w+)[^;]+WHERE\s',
        sql, re.IGNORECASE
    ):
        partial_idx_tables.append(m.group(1).lower())

    if partial_idx_tables:
        # Scan platform/ and agent/ python files for naive upsert on these tables
        naive_upsert_refs = []
        for root, dirs, files in os.walk(os.path.join(REPO, 'platform')):
            dirs[:] = [d for d in dirs if not d.startswith('.')]
            for fn in files:
                if not fn.endswith('.py'):
                    continue
                fpath = os.path.join(root, fn)
                try:
                    code = open(fpath, encoding='utf-8').read()
                except OSError:
                    continue
                for tbl in partial_idx_tables:
                    if re.search(
                        rf'["\']({re.escape(tbl)})["\'].*\.upsert\(',
                        code, re.IGNORECASE
                    ) and 'on_conflict' not in code[
                        max(0, code.lower().find(f'"{tbl}"') - 20):
                        code.lower().find(f'"{tbl}"') + 200
                    ]:
                        rel = os.path.relpath(fpath, REPO)
                        naive_upsert_refs.append(f"{rel} (table: {tbl})")
        for ref in naive_upsert_refs:
            findings.append(
                f"HIGH [{fname}] Partial unique index on table in migration; "
                f"naive .upsert() found without on_conflict predicate: {ref} "
                f"— PGRST102 likely at runtime"
            )
        if partial_idx_tables and not naive_upsert_refs:
            for t in partial_idx_tables:
                findings.append(
                    f"HIGH [{fname}] Partial unique index on '{t}' (WHERE clause). "
                    f"Verify any upsert uses explicit on_conflict matching the predicate."
                )

    # ── (b) Date index without UTC cast + code uses created_at::date/current_date
    date_col_pattern = re.compile(
        r'CREATE\s+(?:UNIQUE\s+)?INDEX\s+\S+\s+ON\s+\w+\s*\(([^)]+)\)',
        re.IGNORECASE
    )
    for m in date_col_pattern.finditer(sql):
        cols = m.group(1)
        if re.search(r'\bdate\b|\bcreated_at\b|\bupdated_at\b', cols, re.IGNORECASE):
            if 'timestamptz' not in cols.lower() and 'at time zone' not in cols.lower():
                # Check if code references created_at::date or current_date
                code_risk = False
                for root, dirs, files in os.walk(os.path.join(REPO, 'platform')):
                    dirs[:] = [d for d in dirs if not d.startswith('.')]
                    for fn in files:
                        if not fn.endswith('.py'):
                            continue
                        fpath = os.path.join(root, fn)
                        try:
                            code = open(fpath, encoding='utf-8').read()
                        except OSError:
                            continue
                        if re.search(r'created_at::date|current_date|DATE\(', code, re.IGNORECASE):
                            code_risk = True
                            break
                    if code_risk:
                        break
                if code_risk:
                    findings.append(
                        f"MEDIUM [{fname}] Index on date column without "
                        f"'::timestamptz AT TIME ZONE ''UTC''' cast; "
                        f"code uses created_at::date or current_date — potential UTC mismatch"
                    )

    # ── (c) INSERT in migration body referencing undefined columns ─────────────
    # Collect CREATE TABLE column names
    created_tables: dict[str, set] = {}
    for m in re.finditer(
        r'CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?(\w+)\s*\(([^;]+?)\)',
        sql, re.IGNORECASE | re.DOTALL
    ):
        tbl_name = m.group(1).lower()
        body = m.group(2)
        cols = set()
        for line in body.splitlines():
            line = line.strip().rstrip(',')
            # First token is column name if it doesn't start with a constraint keyword
            if not line:
                continue
            first = re.split(r'\s+', line)[0].strip('"').lower()
            if first in ('primary', 'unique', 'check', 'foreign', 'constraint', 'index'):
                continue
            if re.match(r'^[a-z_][a-z0-9_]*$', first):
                cols.add(first)
        created_tables[tbl_name] = cols

    # Check INSERT statements
    for m in re.finditer(
        r'INSERT\s+INTO\s+(\w+)\s*\(([^)]+)\)',
        sql, re.IGNORECASE
    ):
        tbl = m.group(1).lower()
        insert_cols = {c.strip().strip('"').lower() for c in m.group(2).split(',')}
        if tbl in created_tables:
            defined = created_tables[tbl]
            unknown = insert_cols - defined
            if unknown:
                findings.append(
                    f"HIGH [{fname}] INSERT INTO {tbl} references undefined columns: "
                    f"{', '.join(sorted(unknown))} — migration will fail"
                )

if findings:
    print('\n'.join(findings))
else:
    print('NO_FINDINGS')
PYEOF
) || FINDINGS="ANALYSIS_ERROR: python3 exited non-zero"

# ── emit result ────────────────────────────────────────────────────────────────

if [[ "$MANUAL_MODE" -eq 1 ]]; then
  if [[ "$FINDINGS" == "NO_FINDINGS" ]]; then
    log_info "No schema issues found in ${#MIGRATION_FILES[@]} migration file(s)"
  else
    log_info "Schema audit findings:"
    printf -- '%s\n' "$FINDINGS" >&2
  fi
  exit 0
fi

if [[ "$FINDINGS" == "NO_FINDINGS" ]]; then
  printf -- '{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "allow"}}\n'
  exit 0
fi

# Non-blocking: always allow, but surface findings as additionalContext
python3 -c "
import json, sys
findings_text = sys.argv[1]
out = {
    'hookSpecificOutput': {
        'hookEventName': 'PreToolUse',
        'permissionDecision': 'allow',
        'additionalContext': 'Schema audit findings:\n' + findings_text
    }
}
print(json.dumps(out))
" "$FINDINGS"
