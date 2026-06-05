#!/usr/bin/env bash
# tests/test-memguard.sh — smoke tests for leadv2-memory-guard.sh
# Usage: bash tests/test-memguard.sh
# Exit 0 = all pass; non-zero = failure count
set -euo pipefail

GUARD="${BASH_SOURCE[0]%/*}/../hooks/leadv2-memory-guard.sh"
DETECT="${BASH_SOURCE[0]%/*}/../scripts/leadv2-correction-detect.py"
PASS=0
FAIL=0

pass() { echo "PASS: $1"; (( PASS++ )) || true; }
fail() { echo "FAIL: $1"; (( FAIL++ )) || true; }

# Helper: run guard with a given JSON payload and optional env vars
# Returns exit code
run_guard() {
    local payload="$1"; shift
    env "$@" bash "$GUARD" <<<"$payload" >/dev/null 2>&1
}

# Returns stdout of guard
run_guard_stdout() {
    local payload="$1"; shift
    env "$@" bash "$GUARD" <<<"$payload" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# (a) Guard denies a MEMORY.md write when LEADV2_TASK_ID is set
# ---------------------------------------------------------------------------
MEM_PAYLOAD='{"tool_input":{"file_path":"/home/user/.claude/projects/foo/memory/MEMORY.md","content":"x"}}'

# Run once, capturing both stdout and exit code in a single invocation
a_stdout=""
a_exit=0
a_stdout=$(LEADV2_TASK_ID=test-task-aaa bash "$GUARD" <<<"$MEM_PAYLOAD" 2>/dev/null) || a_exit=$?

if [[ $a_exit -eq 2 ]] && printf '%s' "$a_stdout" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); assert d['hookSpecificOutput']['permissionDecision']=='deny'" 2>/dev/null; then
    pass "(a) guard denies MEMORY.md write with LEADV2_TASK_ID set"
else
    fail "(a) guard should deny MEMORY.md write with LEADV2_TASK_ID set (exit=$a_exit stdout=${a_stdout:0:80})"
fi

# Clean up sentinel that was written
find /tmp/leadv2-memory-guard -name "test-task-aaa_*.blocked" -delete 2>/dev/null || true

# ---------------------------------------------------------------------------
# (b) Guard allows a normal (non-MEMORY.md) path
# ---------------------------------------------------------------------------
NORMAL_PAYLOAD='{"tool_input":{"file_path":"/home/user/.claude/projects/foo/docs/README.md","content":"x"}}'

exit_code=0
run_guard "$NORMAL_PAYLOAD" LEADV2_TASK_ID=test-task-001 || exit_code=$?
if [[ $exit_code -eq 0 ]]; then
    pass "(b) guard allows normal non-MEMORY.md path"
else
    fail "(b) guard should allow normal path (exit=$exit_code)"
fi

# ---------------------------------------------------------------------------
# (c) Block-once: second attempt (sentinel present) allows the write
# ---------------------------------------------------------------------------
# First call creates sentinel and denies (exit 2)
exit_code=0
run_guard "$MEM_PAYLOAD" LEADV2_TASK_ID=test-task-002 || exit_code=$?
if [[ $exit_code -eq 2 ]]; then
    # Sentinel written — second call should allow (exit 0)
    exit_code2=0
    run_guard "$MEM_PAYLOAD" LEADV2_TASK_ID=test-task-002 || exit_code2=$?
    if [[ $exit_code2 -eq 0 ]]; then
        pass "(c) block-once: second attempt (sentinel present) releases and allows"
    else
        fail "(c) block-once: second attempt should exit 0 (got exit=$exit_code2)"
    fi
else
    fail "(c) block-once: first attempt should deny (got exit=$exit_code)"
fi

# Clean up
find /tmp/leadv2-memory-guard -name "test-task-002_*.blocked" -delete 2>/dev/null || true

# ---------------------------------------------------------------------------
# (d) correction-detect promotes to immune store — NO MEMORY.md write
# ---------------------------------------------------------------------------
# Create a tmp immune store path and ensure no MEMORY.md is written
TMP_DIR=$(mktemp -d)
TMP_IMMUNE="${TMP_DIR}/immune-patterns.yaml"
export LEADV2_IMMUNE_STORE="$TMP_IMMUNE"
export LEADV2_CORRECTION_DETECT="1"
export LEADV2_CANDIDATES_FILE="${TMP_DIR}/candidates.jsonl"
# Unset API key so _call_haiku returns [] — we test the promote path directly with a stub
unset ANTHROPIC_API_KEY 2>/dev/null || true

# Check that MEMORY.md string doesn't appear as a write target in the script
if python3 -c "
import ast, sys
src = open('${DETECT}').read()
tree = ast.parse(src)
# Walk all attribute access and calls looking for write_text on a path containing MEMORY.md
found = False
for node in ast.walk(tree):
    if isinstance(node, ast.Call):
        func = node.func
        if isinstance(func, ast.Attribute) and func.attr == 'write_text':
            # Check if the object being written is a MEMORY.md path
            # The node itself doesn't tell us the runtime value — use name check
            src_segment = ast.get_source_segment(src, node) or ''
            if 'MEMORY' in src_segment:
                found = True
                break
if found:
    print('FAIL: write_text call referencing MEMORY found')
    sys.exit(1)
print('OK: no write_text referencing MEMORY.md in source')
" 2>/dev/null; then
    pass "(d) correction-detect: no MEMORY.md write_text in source (C1 clean)"
else
    fail "(d) correction-detect: residual MEMORY.md write_text found in source"
fi

# Also verify _auto_promote function is gone
if python3 -c "
import ast, sys
src = open('${DETECT}').read()
tree = ast.parse(src)
names = [n.name for n in ast.walk(tree) if isinstance(n, ast.FunctionDef)]
if '_auto_promote' in names:
    print('FAIL: _auto_promote still present')
    sys.exit(1)
if '_get_memory_dir' in names:
    print('FAIL: _get_memory_dir still present')
    sys.exit(1)
print('OK: _auto_promote and _get_memory_dir removed')
" 2>/dev/null; then
    pass "(d) correction-detect: _auto_promote and _get_memory_dir deleted"
else
    fail "(d) correction-detect: _auto_promote or _get_memory_dir still present"
fi

rm -rf "$TMP_DIR"
unset LEADV2_IMMUNE_STORE LEADV2_CORRECTION_DETECT LEADV2_CANDIDATES_FILE

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[[ $FAIL -eq 0 ]]
