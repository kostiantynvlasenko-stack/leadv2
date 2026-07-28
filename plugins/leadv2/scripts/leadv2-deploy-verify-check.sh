#!/usr/bin/env bash
# leadv2-deploy-verify-check.sh — DEPLOY-CLASS-VERIFY-GATE-01 D3 schema
# validation + failure matrix for the deploy-verify artifact.
#
# Usage:
#   leadv2-deploy-verify-check.sh <task_id>
#   LEADV2_TASK_ID=T1 leadv2-deploy-verify-check.sh
#
# Exit codes:
#   0  PASS  -- artifact present, valid, fresh, all targets verified
#              (or legitimately bypassed with a non-empty reason)
#   1  FAIL  -- artifact missing/malformed/stale/unverified (see stderr)
#   2  usage error (missing task_id)
#   3  N/A   -- task classified `code` (not `deploy`) -- not a failure
#
# Artifact lookup: control plane (leadv2-state-path.sh --no-link
# "deploy-verify/<task_id>.yaml", worktree-independent) preferred, falls
# back to the docs/handoff/<task_id>/deploy-verify.yaml mirror.
#
# TTL: stack.yaml `deploy_verify.max_age_hours` (default 6h) via the
# existing _lv2_stack_scalar reader.
#
# Shared across 4 repos; vendored per repo under .claude/scripts/. No
# persona-engine host/IP/service-name/path may ever appear here. Siblings
# resolved via SCRIPT_DIR so this file works byte-identically from either
# tree.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${CLAUDE_PROJECT_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
export LEADV2_PROJECT_ROOT="${LEADV2_PROJECT_ROOT:-${PROJECT_ROOT}}"

# shellcheck source=leadv2-helpers.sh
source "${SCRIPT_DIR}/leadv2-helpers.sh"
_lv2_load_paths

TASK_ID="${1:-${LEADV2_TASK_ID:-}}"
if [[ -z "$TASK_ID" ]]; then
  echo "task_id required (arg1 or LEADV2_TASK_ID env)" >&2
  exit 2
fi

# ── classify: N/A for non-deploy tasks ───────────────────────────────────────
CLASSIFIER="${SCRIPT_DIR}/leadv2-deploy-classify.sh"
if [[ -f "$CLASSIFIER" ]]; then
  CLASSIFICATION="$(bash "$CLASSIFIER" "$TASK_ID" 2>/dev/null || echo code)"
else
  CLASSIFICATION="code"
fi
if [[ "$CLASSIFICATION" != "deploy" ]]; then
  echo "deploy-verify: N/A (task_class=code)" >&2
  exit 3
fi

# ── D7 bypass: env-driven skip, read BEFORE artifact lookup so this gate and
# leadv2-deploy-merge.sh's producer see identical bypass state (critic1 B2:
# previously this script never read the env pair at all, only the artifact's
# bypassed:true field -- and the producer hardcoded bypassed:False, so the
# sanctioned escape hatch was dead). An empty/missing reason still fails --
# never a silent unconditional skip.
if [[ "${LEADV2_SKIP_DEPLOY_VERIFY:-}" == "1" ]]; then
  SKIP_REASON="${LEADV2_SKIP_DEPLOY_VERIFY_REASON:-}"
  if [[ -n "$SKIP_REASON" ]]; then
    echo "WARN: deploy-verify BYPASSED (env) -- ${SKIP_REASON}"
    exit 0
  else
    echo "FAIL: LEADV2_SKIP_DEPLOY_VERIFY=1 requires non-empty LEADV2_SKIP_DEPLOY_VERIFY_REASON" >&2
    exit 1
  fi
fi

# ── locate artifact: control plane preferred, handoff mirror fallback ───────
CONTROL_PLANE_PATH="$(PROJECT_ROOT="$LEADV2_PROJECT_ROOT" "${SCRIPT_DIR}/leadv2-state-path.sh" --no-link "deploy-verify/${TASK_ID}.yaml")"
HANDOFF_MIRROR_PATH="${LEADV2_HANDOFF_DIR}/${TASK_ID}/deploy-verify.yaml"

ARTIFACT=""
if [[ -f "$CONTROL_PLANE_PATH" ]]; then
  ARTIFACT="$CONTROL_PLANE_PATH"
elif [[ -f "$HANDOFF_MIRROR_PATH" ]]; then
  ARTIFACT="$HANDOFF_MIRROR_PATH"
fi

if [[ -z "$ARTIFACT" ]]; then
  echo "FAIL: deploy-verify.yaml missing for ${TASK_ID} -- Phase 6 (leadv2-deploy-merge.sh) did not run or did not deploy" >&2
  exit 1
fi

# critic1 L2: _lv2_stack_scalar matches ANY top-level-indifferent line named
# max_age_hours anywhere in stack.yaml, not just under deploy_verify: -- a
# future unrelated key earlier in the file would silently win. Scope the read
# to the deploy_verify: block explicitly (self-contained here, no change to
# the shared leadv2-helpers.sh reader).
_lv2_deploy_verify_scoped_scalar() {
  local _key="${1:-}" _default="${2:-}"
  local _yaml="${LEADV2_PROJECT_ROOT}/.claude/leadv2-overrides/stack.yaml"
  [[ -f "$_yaml" ]] || { printf -- '%s' "$_default"; return 0; }
  local _val
  _val="$(awk -v key="$_key" '
    /^deploy_verify:[[:space:]]*$/ { in_section=1; next }
    in_section && /^[^[:space:]]/ { in_section=0 }
    in_section && $0 ~ "^[[:space:]]+" key "[[:space:]]*:" {
      sub("^[[:space:]]+" key "[[:space:]]*:[[:space:]]*", "");
      print;
      exit
    }
  ' "$_yaml" 2>/dev/null | sed -E "s/^['\"]//; s/['\"][[:space:]]*\$//" | tr -d '\r')"
  if [[ -z "$_val" ]]; then
    printf -- '%s' "$_default"
  else
    printf -- '%s' "$_val"
  fi
}
MAX_AGE_HOURS="$(_lv2_deploy_verify_scoped_scalar 'max_age_hours' '6')"

set +e
python3 - "$ARTIFACT" "$TASK_ID" "$MAX_AGE_HOURS" <<'PYEOF'
import sys, yaml
from datetime import datetime, timezone

artifact_path, task_id, max_age_hours_raw = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    max_age_hours = float(max_age_hours_raw)
except ValueError:
    max_age_hours = 6.0

try:
    with open(artifact_path, encoding="utf-8") as fh:
        d = yaml.safe_load(fh)
except Exception as e:
    print(f"FAIL: deploy-verify.yaml malformed: {e}", file=sys.stderr)
    sys.exit(1)

if not isinstance(d, dict):
    print("FAIL: deploy-verify.yaml malformed: not a mapping", file=sys.stderr)
    sys.exit(1)

if d.get("schema_version") != 1:
    print(f"FAIL: unsupported schema_version={d.get('schema_version')!r}", file=sys.stderr)
    sys.exit(1)

if str(d.get("task_id", "")) != task_id:
    print(f"FAIL: artifact task_id={d.get('task_id')!r} != {task_id} (stale copy)", file=sys.stderr)
    sys.exit(1)

REQUIRED = ["verified_at", "target_commit", "producer", "targets", "bypassed"]
for k in REQUIRED:
    if k not in d:
        print(f"FAIL: required field {k} missing", file=sys.stderr)
        sys.exit(1)

# Bypass short-circuits the rest of the validation (schema note: targets
# len>=1 "unless bypassed"). Checked BEFORE staleness/targets so a bypass
# stub with an old verified_at or empty targets is still a legitimate PASS.
bypassed = d.get("bypassed")
if bypassed is True:
    reason = d.get("bypass_reason")
    if isinstance(reason, str) and reason.strip():
        print(f"WARN: deploy-verify BYPASSED -- {reason}")
        sys.exit(0)
    else:
        print("FAIL: bypass requires LEADV2_SKIP_DEPLOY_VERIFY_REASON", file=sys.stderr)
        sys.exit(1)

verified_at = d.get("verified_at")
# PyYAML's safe_load auto-parses bare ISO8601 timestamps into datetime
# objects (no quotes needed in the artifact) -- handle both that and a
# plain string so the schema doc's unquoted example round-trips correctly.
if isinstance(verified_at, datetime):
    vdt = verified_at if verified_at.tzinfo else verified_at.replace(tzinfo=timezone.utc)
else:
    try:
        vdt = datetime.strptime(str(verified_at), "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except Exception:
        print(f"FAIL: deploy-verify.yaml malformed: bad verified_at {verified_at!r}", file=sys.stderr)
        sys.exit(1)
now = datetime.now(timezone.utc)
age_s = (now - vdt).total_seconds()
ttl_s = max_age_hours * 3600
if age_s > ttl_s:
    print(f"FAIL: deploy-verify stale ({int(age_s)}s > {int(ttl_s)}s) -- re-deploy or re-probe", file=sys.stderr)
    sys.exit(1)

targets = d.get("targets")
if not isinstance(targets, list):
    print("FAIL: required field targets missing", file=sys.stderr)
    sys.exit(1)

producer_gap = d.get("producer_gap")
if len(targets) == 0:
    print("FAIL: no deploy targets -- add .claude/leadv2-overrides/deploy-verify.sh", file=sys.stderr)
    sys.exit(1)

target_commit = d.get("target_commit")
for t in targets:
    if not isinstance(t, dict):
        print("FAIL: required field targets missing", file=sys.stderr)
        sys.exit(1)
    for tk in ("name", "deployed_sha", "previous_sha", "sha_advanced", "probe"):
        if tk not in t:
            print(f"FAIL: required field {tk} missing", file=sys.stderr)
            sys.exit(1)
    name = t.get("name")
    deployed_sha = t.get("deployed_sha")
    sha_advanced = t.get("sha_advanced")
    if sha_advanced is False and deployed_sha != target_commit:
        print(f"FAIL: {name} prod sha did not advance ({deployed_sha} != {target_commit})", file=sys.stderr)
        sys.exit(1)
    if deployed_sha != target_commit:
        print(f"FAIL: {name} running {deployed_sha}, expected {target_commit}", file=sys.stderr)
        sys.exit(1)
    probe = t.get("probe")
    if not isinstance(probe, dict):
        print("FAIL: required field probe missing", file=sys.stderr)
        sys.exit(1)
    for pk in ("cmd", "exit_code", "observed_at", "result"):
        if pk not in probe:
            print(f"FAIL: required field probe.{pk} missing", file=sys.stderr)
            sys.exit(1)
    if probe.get("result") != "pass":
        print(f"FAIL: {name} post-deploy probe failed (exit {probe.get('exit_code')}): {probe.get('cmd')}", file=sys.stderr)
        sys.exit(1)

print(f"PASS: {len(targets)} target(s) verified at {target_commit}")
sys.exit(0)
PYEOF
rc=$?
set -e
exit $rc
