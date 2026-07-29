#!/usr/bin/env bash
# leadv2-status-collector.sh — collect once, in code, on a schedule.
#
# STATUS-COLLECTOR-01. Replaces "spawn a subagent that makes 20-40 tool calls
# every status turn" with: run this on a timer, write a JSON snapshot, let
# leadv2-status-render.sh format it for free.
#
# Generic framework only. Repo-specific facts (DB, engine health, business
# metrics) come from an optional hook the caller's repo supplies:
#   .claude/leadv2-overrides/status-collector-facts.sh
# defining a function `collect_repo_facts` that prints ONE JSON object to
# stdout. Absent hook = repo_facts section is simply omitted (not an error).
#
# Every section is independently guarded: one failing section never loses
# the rest of the snapshot (constraint in the mission — "resilient").
#
# Writes (atomically, tmp+mv): $STATUS_SNAPSHOT_PATH, default
#   docs/leadv2/status-snapshot.json
#
# Usage: leadv2-status-collector.sh [--project-root <dir>] [--out <path>]
#
# Rollback: touch docs/leadv2/.status-collector-disabled — the renderer
# (leadv2-status-render.sh) checks this sentinel FIRST and tells the caller
# to fall back to the legacy spawn-an-agent status instead of reading a
# snapshot this collector no longer produces. rm the sentinel to re-enable.

set -uo pipefail
trap 'exit 0' ERR   # a probe script's contract: never crash the timer

PROJECT_ROOT="${PROJECT_ROOT:-$(pwd)}"
OUT_PATH=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-root) PROJECT_ROOT="$2"; shift 2;;
    --out) OUT_PATH="$2"; shift 2;;
    -h|--help)
      echo "Usage: leadv2-status-collector.sh [--project-root <dir>] [--out <path>]"
      exit 0;;
    *) shift;;
  esac
done
PROJECT_ROOT="$(cd "$PROJECT_ROOT" && pwd)"
: "${OUT_PATH:=$PROJECT_ROOT/docs/leadv2/status-snapshot.json}"

_SC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_SC_TMPDIR="$(mktemp -d)"
trap '_ec=$?; rm -rf "$_SC_TMPDIR"; exit $_ec' EXIT

# ── section runner: name -> JSON. Never lets one section's failure kill the
#    others; captures stderr into the "error" field instead of the terminal.
_sc_run_section() {
  local name="$1"; shift
  local out_file="$_SC_TMPDIR/${name}.json"
  local err_file="$_SC_TMPDIR/${name}.err"
  if ( set -euo pipefail; "$@" ) >"$out_file" 2>"$err_file"; then
    if python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$out_file" 2>/dev/null; then
      SECTION_NAMES+=("$name")
      SECTION_OK+=("true")
      SECTION_FILES+=("$out_file")
    else
      SECTION_NAMES+=("$name")
      SECTION_OK+=("false")
      printf '"invalid_json_output"' >"$out_file"
      SECTION_FILES+=("$out_file")
    fi
  else
    local msg
    msg="$(tail -c 500 "$err_file" 2>/dev/null | tr -d '\000')"
    SECTION_NAMES+=("$name")
    SECTION_OK+=("false")
    python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$msg" >"$out_file"
    SECTION_FILES+=("$out_file")
  fi
}
SECTION_NAMES=(); SECTION_OK=(); SECTION_FILES=()

# ── generic section: git (local HEAD, unpushed count) ───────────────────
_sc_git_section() {
  cd "$PROJECT_ROOT"
  local head branch unpushed
  head="$(git rev-parse --short HEAD)"
  branch="$(git rev-parse --abbrev-ref HEAD)"
  if git rev-parse --abbrev-ref '@{u}' >/dev/null 2>&1; then
    unpushed="$(git rev-list '@{u}..HEAD' --count)"
  else
    unpushed="null"
  fi
  python3 -c "
import json, sys
head, branch, unpushed = sys.argv[1], sys.argv[2], sys.argv[3]
print(json.dumps({
    'local_head': head,
    'branch': branch,
    'unpushed': (None if unpushed == 'null' else int(unpushed)),
}))
" "$head" "$branch" "$unpushed"
}
_sc_run_section "git" _sc_git_section

# ── generic section: lanes — delegate to the already-correct, already-tested
#    leadv2-supervise.sh --json (arm-aware liveness: pid/mtime for Sonnet
#    lanes, codex-task.sh status for Codex lanes — re-deriving that split
#    here would just re-risk the exact trap it already solves). ──────────
_sc_lanes_section() {
  cd "$PROJECT_ROOT"
  # supervise.sh resolves LEADV2_PROJECT_ROOT before PROJECT_ROOT.  Pin all
  # accepted root variables so an ambient supervisor session cannot make this
  # snapshot read a different repository's control plane.
  LEADV2_PROJECT_ROOT="$PROJECT_ROOT" \
    CLAUDE_PROJECT_DIR="$PROJECT_ROOT" \
    PROJECT_ROOT="$PROJECT_ROOT" \
    bash "$_SC_DIR/leadv2-supervise.sh" --json
}
_sc_run_section "lanes" _sc_lanes_section

# ── repo-specific facts (optional hook) ──────────────────────────────────
# Canonical location is .claude/leadv2-overrides/status-collector-facts.sh
# (per-repo extension point, same convention as deploy.sh/verify.sh/etc).
# STATUS_COLLECTOR_FACTS_HOOK overrides the path for repos that stage the
# hook elsewhere before promoting it into overrides/ (e.g. a write-permission
# boundary during initial rollout) — same contract either way: define
# collect_repo_facts() and print one JSON object.
_SC_FACTS_HOOK="${STATUS_COLLECTOR_FACTS_HOOK:-$PROJECT_ROOT/.claude/leadv2-overrides/status-collector-facts.sh}"
if [[ -f "$_SC_FACTS_HOOK" ]]; then
  _sc_repo_facts_section() {
    cd "$PROJECT_ROOT"
    # shellcheck disable=SC1090
    source "$_SC_FACTS_HOOK"
    if ! declare -F collect_repo_facts >/dev/null; then
      echo "status-collector-facts.sh loaded but defines no collect_repo_facts()" >&2
      return 1
    fi
    collect_repo_facts
  }
  _sc_run_section "repo_facts" _sc_repo_facts_section
fi

# ── assemble + write atomically ──────────────────────────────────────────
_SC_MANIFEST="$_SC_TMPDIR/manifest.json"
{
  python3 -c "
import json, sys
names = sys.argv[1::3]
oks   = sys.argv[2::3]
files = sys.argv[3::3]
sections = {}
for n, ok, f in zip(names, oks, files):
    with open(f) as fh:
        data = json.load(fh)
    sections[n] = {'ok': ok == 'true', 'data': data}
print(json.dumps(sections))
" $(for i in "${!SECTION_NAMES[@]}"; do
      printf '%s %s %s ' "${SECTION_NAMES[$i]}" "${SECTION_OK[$i]}" "${SECTION_FILES[$i]}"
    done)
} >"$_SC_MANIFEST"

COLLECTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
python3 -c "
import json, sys
sections = json.load(open(sys.argv[1]))
snapshot = {
    'collected_at': sys.argv[2],
    'project_root': sys.argv[3],
    'sections': sections,
}
print(json.dumps(snapshot, indent=2, sort_keys=True))
" "$_SC_MANIFEST" "$COLLECTED_AT" "$PROJECT_ROOT" >"$_SC_TMPDIR/snapshot.json"

mkdir -p "$(dirname "$OUT_PATH")"
mv "$_SC_TMPDIR/snapshot.json" "$OUT_PATH"
echo "wrote $OUT_PATH (collected_at=$COLLECTED_AT)" >&2
