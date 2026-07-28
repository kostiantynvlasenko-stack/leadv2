#!/usr/bin/env bash
# leadv2-tasks-clobber-guard.sh — TASKS-YAML-STALE-BASE-CLOBBER-01 (c4e91a70b83d)
#
# A lane that holds a STALE copy of docs/tasks.yaml and writes the whole file
# back (via Edit/Write, bypassing leadv2-tasks-lib.sh) silently erases every
# other lane's work the moment it commits — proven twice in one day
# (92763d76 dropped 32 in-flight rows incl. live P0 a9f34c02e7d1; dc22ad79
# reverted 47af84254005 from done back to queued). The lib's flock only
# serialises lib writers; it cannot see a lane that writes the file directly.
# This guard is the load-bearing backstop: it runs at `git commit` time, so it
# catches EVERY writer regardless of whether the lib was used.
#
# It compares the staged docs/tasks.yaml against HEAD:docs/tasks.yaml and
# BLOCKS the commit when the staged version either:
#   (G1) drops an IN-FLIGHT id — an id that was NON-terminal in HEAD and is
#        absent from the staged tree (the data-loss case: live work erased), OR
#   (G2) regresses an id — terminal in HEAD, non-terminal in staged (the
#        done→queued revert case),
# unless EVERY blocked id is named in the commit message (the legitimate
# "reopen <id>" / "drop <id>" escape hatch) OR PE_SKIP_TASKS_CLOBBER_GUARD=1.
#
# Dropping a TERMINAL id is ALLOWED (that is the archive path — finished rows
# leaving tasks.yaml), so a legit archive commit is not blocked. A normal
# status flip that only adds terminals (e.g. queued→done) is allowed.
#
# Usage:
#   leadv2-tasks-clobber-guard.sh                 # pre-commit mode: reads git
#   leadv2-tasks-clobber-guard.sh --check <head.yaml> <staged.yaml> <msg>
#        # core comparison against explicit files (for tests; no git needed)
#
# Env:
#   PE_SKIP_TASKS_CLOBBER_GUARD=1   bypass (prints a visible BYPASSED line)
#
# Exit codes: 0 = commit may proceed; 1 = commit blocked (named ids printed).
set -uo pipefail

# ── core comparison (no git) ────────────────────────────────────────────────
# args: <head.yaml> <staged.yaml> <message>
# stdout: "OK" on pass; "BLOCKED dropped=<ids> regressed=<ids>" on block
#         (comma-separated ids; empty subset omitted)
core_check() {
  local head_yaml="$1" staged_yaml="$2" message="$3"
  python3 - "$head_yaml" "$staged_yaml" "$message" <<'PY'
import sys, yaml

TERMINAL = {"done","poisoned","rejected","failed","archived",
            "closed","completed","admin-closed","verified_closed"}

def load_items(path):
    try:
        with open(path) as f: doc = yaml.safe_load(f)
    except FileNotFoundError:
        return []
    if doc is None: return []
    if isinstance(doc, list): return doc
    if isinstance(doc, dict):
        for key in ("tasks","items","queues"):
            v = doc.get(key)
            if isinstance(v, list): return v
        return []
    return []

head   = load_items(sys.argv[1])
staged = load_items(sys.argv[2])
msg    = sys.argv[3] or ""

def idmap(items):
    m = {}
    for it in items:
        iid = str(it.get("id","")).strip()
        if iid: m[iid] = str(it.get("status","")).strip()
    return m

hmap = idmap(head)
smap = idmap(staged)

head_ids, staged_ids = set(hmap), set(smap)
dropped        = head_ids - staged_ids
dropped_inflight = {i for i in dropped if hmap[i] not in TERMINAL}   # G1 (data loss)
regressed      = {i for i in hmap if i in smap
                  and hmap[i] in TERMINAL and smap[i] not in TERMINAL}  # G2 (revert)

blocked = dropped_inflight | regressed
if not blocked:
    print("OK")
    sys.exit(0)

# escape hatch: every blocked id must appear as a token in the commit message
def named(iid):
    msg_tokens = set(msg.replace(",", " ").replace(":", " ").split())
    return iid in msg_tokens or iid in msg  # token match OR substring (ids are unique enough)

unnamed = {i for i in blocked if not named(i)}
if not unnamed:
    # author acknowledged every reverted/dropped id explicitly — allow
    print("OK-NAMED")
    sys.exit(0)

parts = []
if dropped_inflight & unnamed: parts.append("dropped_inflight=" + ",".join(sorted(dropped_inflight & unnamed)))
if regressed      & unnamed: parts.append("regressed=" + ",".join(sorted(regressed & unnamed)))
print("BLOCKED " + " ".join(parts))
sys.exit(0)
PY
}

# ── pre-commit mode (default) ───────────────────────────────────────────────
pre_commit() {
  # respect explicit bypass (visible, never silent)
  if [[ "${PE_SKIP_TASKS_CLOBBER_GUARD:-}" == "1" ]]; then
    echo "tasks-clobber-guard: BYPASSED via PE_SKIP_TASKS_CLOBBER_GUARD=1" >&2
    return 0
  fi

  local repo_root staged_present
  repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  [[ -n "$repo_root" ]] || return 0   # not a repo → nothing to guard

  # fast path: only act when docs/tasks.yaml is staged
  staged_present="$(git diff --cached --name-only -- docs/tasks.yaml 2>/dev/null || true)"
  if [[ -z "${staged_present}" ]]; then
    return 0   # tasks.yaml not part of this commit → nothing to guard
  fi

  local tmpdir head_yaml staged_yaml msg result rc
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' RETURN EXIT
  head_yaml="$tmpdir/head.yaml"
  staged_yaml="$tmpdir/staged.yaml"

  # HEAD baseline (empty if first commit / file new to HEAD)
  git show "HEAD:docs/tasks.yaml" >"$head_yaml" 2>/dev/null || : >"$head_yaml"
  # staged (index) version
  git cat-file blob ":docs/tasks.yaml" >"$staged_yaml" 2>/dev/null || : >"$staged.yaml"

  # commit message: .git/COMMIT_EDITMSG is populated before pre-commit runs
  msg=""
  if [[ -f "$repo_root/.git/COMMIT_EDITMSG" ]]; then
    msg="$(cat "$repo_root/.git/COMMIT_EDITMSG" 2>/dev/null || true)"
  elif [[ -d "$repo_root/.git" ]]; then :; fi

  result="$(core_check "$head_yaml" "$staged_yaml" "$msg")"; rc=$?
  case "$result" in
    OK|OK-NAMED)
      return 0
      ;;
    BLOCKED\ *)
      echo "" >&2
      echo "tasks-clobber-guard: BLOCKED commit — staged docs/tasks.yaml would" >&2
      echo "  silently erase or revert in-flight work that HEAD already has:" >&2
      echo "    ${result#BLOCKED }" >&2
      echo "" >&2
      echo "  This is the TASKS-YAML-STALE-BASE-CLOBBER-01 failure mode: you likely" >&2
      echo "  wrote the whole file from a stale in-context copy. To fix safely:" >&2
      echo "    1. Re-read docs/tasks.yaml FRESH (do not reuse an earlier read)." >&2
      echo "    2. Re-apply ONLY your intended change via leadv2-tasks-lib.sh," >&2
      echo "       or make a targeted patch — never a whole-file dump." >&2
      echo "    3. Re-stage and re-commit." >&2
      echo "  If the drop/revert is INTENTIONAL (e.g. reopening <id>), name every" >&2
      echo "  affected id in the commit message and the guard will allow it." >&2
      echo "  Emergency bypass: PE_SKIP_TASKS_CLOBBER_GUARD=1 git commit ..." >&2
      return 1
      ;;
    *)
      # python crash / unexpected output — fail OPEN (never block on a bug in the guard)
      echo "tasks-clobber-guard: internal error (result='$result', rc=$rc) — failing OPEN" >&2
      return 0
      ;;
  esac
}

if [[ "${1:-}" == "--check" ]]; then
  shift
  core_check "$@"
else
  pre_commit
fi
