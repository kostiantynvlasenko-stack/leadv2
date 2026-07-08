#!/usr/bin/env bash
# leadv2-mem-backup.sh — MEM-BACKUP-RESTORE-01 sourceable helper.
#
# Backup + integrity-check + auto-restore for leadv2 learned-memory YAML/JSONL
# stores (immune-patterns.yaml, leadv2-negative-memory.yaml,
# leadv2-negative-memory-archive.yaml). A corrupt/truncated write to any of
# these silently poisons recall for every future task.
#
# FLAG-GATED, default-OFF, BYTE-IDENTICAL (hard constraint):
#   LEADV2_MEM_BACKUP=0 (unset/0, default) => every function below returns 0
#   immediately with ZERO side effects (no mkdir, no date call, no stdout,
#   no stderr). Sourcing this file itself is also silent in that mode.
#   Only LEADV2_MEM_BACKUP=1 activates any behavior.
#
# FAIL-OPEN + LOUD, and SAFE UNDER `set -e` CALLERS (fix round 1, items
# 2-4 — Codex empirically confirmed `true && false; return 0` still exits 1
# under set -e: the ABORT happens at the failing statement itself, a later
# `return 0` line is never reached. Every place below that could put a
# possibly-failing command in the FINAL position of an `&&`/`||` list now
# ends that list with `|| true`, which POSIX/bash exempts from errexit):
#   - Every PUBLIC function (mem_backup_snapshot, mem_backup_integrity_check,
#     mem_backup_verify_or_restore, mem_backup_restore_latest_good) always
#     returns 0 on every path — confirmed safe to call bare under set -e.
#   - A detected corruption (real runtime event, not misconfiguration) is
#     always logged to stderr — this is observability, not a pipeline block.
#   - A genuine MISCONFIGURATION (flag=1 but python3 missing, or the backup
#     dir cannot be created) is routed through strict_or_warn (T5,
#     FAIL-LOUD-FLAGS-01) via the single choke point `_mem_backup_python_ok`
#     so strict mode makes it loud — and NEVER mislabeled as content
#     corruption (fix round 1, item 3): every public function checks
#     python3-presence FIRST and returns 0 immediately (skipping the
#     corruption-reporting path entirely) before it ever touches
#     `_mem_backup_parses`. Guarded with `command -v strict_or_warn` so a
#     missing scripts/leadv2-strict.sh never breaks this file.
#
# NO INJECTION: memory/YAML/JSONL content is only ever read as DATA via
# yaml.safe_load / json.loads — never eval'd, never spliced into shell/python
# source text.
#
# Usage (sourced from a writer script, around its write of <store-file>):
#   source ".../leadv2-mem-backup.sh"
#   mem_backup_snapshot "<store-file>" "<top_key>"          # BEFORE write
#   ... write the store file ...
#   mem_backup_verify_or_restore "<store-file>" "<top_key>" # AFTER write
#
# Rotation + integrity (fix round 1, item 5): mem_backup_snapshot now
# integrity-checks the SOURCE before copying it into rotation — a source
# that fails its own check is never snapshotted. This means every snapshot
# that ever enters `.mem-backups/` is already known-good, so the plain
# recency-based eviction below can never rotate out "the last good state"
# in favor of a corrupt one — corrupt content simply never gets in. Keeps
# the last LEADV2_MEM_BACKUP_KEEP (default 5) snapshots per store file,
# oldest deleted. Snapshots live in a hidden sibling dir:
#   <dirname>/.mem-backups/<basename>/<basename>.<UTC-timestamp>.bak

_MEM_BACKUP_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -f "${_MEM_BACKUP_SELF_DIR}/leadv2-strict.sh" ]]; then
  # shellcheck source=/dev/null
  source "${_MEM_BACKUP_SELF_DIR}/leadv2-strict.sh" 2>/dev/null || true
fi

_mem_backup_dir_for() {
  local store="$1" dir base
  dir="$(cd "$(dirname "$store")" 2>/dev/null && pwd)" || return 1
  base="$(basename "$store")"
  printf -- '%s/.mem-backups/%s\n' "$dir" "$base"
}

# _mem_backup_python_ok — single choke point for the python3-presence check
# (fix round 1, item 3). Returns 0 if python3 is on PATH. If absent, warns
# ONCE via strict_or_warn as genuine MISCONFIGURATION (never as content
# corruption) and returns 1. The trailing `|| true` is load-bearing (fix
# round 1, item 2): `command -v X && X ...` puts X in the FINAL position of
# the list, so X's own failure (strict_or_warn returns 1 when
# LEADV2_REQUIRE_STRICT=1) would otherwise abort a set -e caller BEFORE this
# function's own `return 1` below ever runs.
_mem_backup_python_ok() {
  command -v python3 >/dev/null 2>&1 && return 0
  command -v strict_or_warn >/dev/null 2>&1 && \
    strict_or_warn "mem-backup-no-python3" "LEADV2_MEM_BACKUP=1 but python3 not found — integrity checks disabled" || true
  return 1
}

# _mem_backup_parses <path> [expected_top_key]
# Internal. Returns 0 = parses + (no key requested OR key present as a dict
# key). Returns 1 = missing / unparsable / truncated / key missing. Callers
# MUST check python3 availability themselves via _mem_backup_python_ok
# first (this function's own `command -v python3` line is only a bare
# defense-in-depth safety net — it does NOT warn, to avoid double-firing
# strict_or_warn per call). Reads content as DATA only (yaml.safe_load /
# json.loads) — never eval.
_mem_backup_parses() {
  local path="$1" expect_key="${2:-}"
  [[ -f "$path" && -s "$path" ]] || return 1
  command -v python3 >/dev/null 2>&1 || return 1
  python3 - "$path" "$expect_key" <<'PYEOF' >/dev/null 2>&1
import sys, json
path, expect_key = sys.argv[1], sys.argv[2]
# Format dispatch by ORIGINAL extension, not the trailing rotation suffix —
# snapshots are named "<basename>.<utc-ts>.bak", so a plain path.endswith()
# check would miss "store.yaml.20260101T000000Z.bak" entirely (H-bug found
# in T6 own test run: substring check fixes it without needing the caller
# to pass an explicit format hint).
is_yaml = ".yaml." in path or ".yml." in path or path.endswith((".yaml", ".yml"))
is_jsonl = ".jsonl." in path or path.endswith(".jsonl")
try:
    if is_yaml:
        import yaml
        with open(path, encoding="utf-8") as fh:
            data = yaml.safe_load(fh)
    elif is_jsonl:
        data = None
        with open(path, encoding="utf-8") as fh:
            saw_line = False
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                json.loads(line)
                saw_line = True
            data = {"__jsonl_ok__": True} if saw_line else None
    else:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
except Exception:
    sys.exit(1)
if data is None:
    sys.exit(1)
if expect_key and (not isinstance(data, dict) or expect_key not in data):
    sys.exit(1)
sys.exit(0)
PYEOF
}

# mem_backup_snapshot <path> [expected_top_key]
# Copies <path> into its rotation dir before a write. No-op if flag off, if
# python3 is unavailable (misconfig, loudly warned via strict_or_warn — see
# _mem_backup_python_ok, item 3), if <path> doesn't exist yet (nothing to
# protect), or if <path> ITSELF fails its own integrity check (item 5 —
# never propagate known-corrupt content into rotation).
mem_backup_snapshot() {
  [[ "${LEADV2_MEM_BACKUP:-0}" == "1" ]] || return 0
  local store="$1" expect_key="${2:-}"
  [[ -f "$store" ]] || return 0
  _mem_backup_python_ok || return 0
  if ! _mem_backup_parses "$store" "$expect_key"; then
    printf -- '[mem-backup] SKIP SNAPSHOT: %s fails its own integrity check — not propagating corrupt content into rotation\n' "$store" >&2
    return 0
  fi
  local bdir
  bdir="$(_mem_backup_dir_for "$store")" || return 0
  if ! mkdir -p "$bdir" 2>/dev/null; then
    command -v strict_or_warn >/dev/null 2>&1 && \
      strict_or_warn "mem-backup-dir-unwritable" "LEADV2_MEM_BACKUP=1 but cannot create backup dir for $store" || true
    return 0
  fi
  local ts snap keep
  ts="$(date -u +%Y%m%dT%H%M%S.%NZ 2>/dev/null || date -u +%Y%m%dT%H%M%SZ)"
  snap="${bdir}/$(basename "$store").${ts}.bak"
  cp -p "$store" "$snap" 2>/dev/null || return 0
  keep="${LEADV2_MEM_BACKUP_KEEP:-5}"
  local -a snaps
  mapfile -t snaps < <(ls -1t "${bdir}/$(basename "$store")".*.bak 2>/dev/null)
  local i
  for ((i = keep; i < ${#snaps[@]}; i++)); do
    rm -f "${snaps[$i]}" 2>/dev/null || true
  done
  return 0
}

# mem_backup_integrity_check <path> [expected_top_key]
# Standalone check for callers/tests that just want a verdict. Fix round 1,
# item 4: this is a PUBLIC function, so it must NEVER abort a bare `set -e`
# caller — it now ALWAYS returns 0 and reports the verdict on stdout
# ("good" / "bad") instead of via exit code. (Nothing in this codebase
# calls it today — confirmed dormant by review — so this is a safe,
# non-breaking contract change.)
mem_backup_integrity_check() {
  [[ "${LEADV2_MEM_BACKUP:-0}" == "1" ]] || return 0
  _mem_backup_python_ok || return 0
  if _mem_backup_parses "$1" "${2:-}"; then
    printf -- 'good\n'
  else
    printf -- 'bad\n'
  fi
  return 0
}

# mem_backup_restore_latest_good <path> [expected_top_key]
# Scans rotation dir newest-first, restores the first snapshot that itself
# passes the integrity check. No-op if flag off or python3 unavailable
# (misconfig already loudly warned — never reported as "no good backup",
# item 3). Always returns 0 (fail-open) — logs to stderr whether restore
# succeeded or no good backup was found.
mem_backup_restore_latest_good() {
  [[ "${LEADV2_MEM_BACKUP:-0}" == "1" ]] || return 0
  local path="$1" expect_key="${2:-}" bdir
  _mem_backup_python_ok || return 0
  bdir="$(_mem_backup_dir_for "$path")" || return 0
  local -a snaps
  mapfile -t snaps < <(ls -1t "${bdir}/$(basename "$path")".*.bak 2>/dev/null)
  local snap
  for snap in "${snaps[@]:-}"; do
    [[ -n "$snap" ]] || continue
    if _mem_backup_parses "$snap" "$expect_key"; then
      if cp -p "$snap" "$path" 2>/dev/null; then
        printf -- '[mem-backup] RESTORED %s from %s (corruption detected)\n' "$path" "$snap" >&2
        return 0
      fi
    fi
  done
  printf -- '[mem-backup] NO GOOD BACKUP for %s — corrupt/missing file left as-is\n' "$path" >&2
  return 0
}

# mem_backup_verify_or_restore <path> [expected_top_key]
# The wire-it-fires orchestration call: run AFTER a writer touches <path>,
# UNCONDITIONALLY — even (especially) when the writer itself failed/exited
# non-zero (fix round 1, item 1: callers MUST capture the writer's exit
# code with `|| rc=$?`, never let a bare failing writer abort under set -e
# before this runs). No-op if flag off or python3 unavailable (misconfig
# already loudly warned, never reported as corruption, item 3). Good ->
# silent no-op. Bad -> logs loudly (stderr, always — this is a real
# corruption event) and attempts restore. Always returns 0 — never blocks
# the caller's pipeline.
mem_backup_verify_or_restore() {
  [[ "${LEADV2_MEM_BACKUP:-0}" == "1" ]] || return 0
  local path="$1" expect_key="${2:-}"
  _mem_backup_python_ok || return 0
  if _mem_backup_parses "$path" "$expect_key"; then
    return 0
  fi
  printf -- '[mem-backup] INTEGRITY FAIL: %s (missing/corrupt/truncated) — attempting restore\n' "$path" >&2
  mem_backup_restore_latest_good "$path" "$expect_key"
  return 0
}
