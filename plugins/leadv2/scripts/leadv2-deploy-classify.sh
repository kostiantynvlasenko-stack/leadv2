#!/usr/bin/env bash
# leadv2-deploy-classify.sh — DEPLOY-CLASS-VERIFY-GATE-01 D2 classifier.
#
# Stdout: `deploy` or `code`. ALWAYS exits 0 -- a classifier that blocks is a
# new failure mode, not the fix.
#
# Precedence, first match wins:
#   P0    env LEADV2_DEPLOY_TASK=1|0   -- explicit escape hatch, both
#         directions, logged to stderr.
#   P-err context.yaml present but unparseable / not a mapping -- fails
#         CLOSED to `deploy` (a malformed file must never silently degrade
#         to `code` and let a real deploy task through ungated).
#   P1    context.yaml.task_class in {deploy, ops, rollout}
#   P2    context.yaml.deploy_targets non-empty (list or non-empty string)
#   P1.5  context.yaml.task_class explicitly set to anything else (e.g.
#         "general") -- an explicit non-deploy classification beats keyword
#         guessing outright; short-circuits straight to `code`, skipping P3.
#   P3    keyword regex (deploy|rollout|restart|systemd|vps|promote|cutover|
#         rollback) over context.yaml.mission + task_id, AND-gated by a
#         *verified* empty tracked diff: git diff must have exited 0 AND
#         printed nothing. A missing branch or a failed git command is never
#         treated as positive evidence of "no code change" -- both leave the
#         AND-gate closed (falls through to `code`). Note: by the time this
#         runs, both call sites are post-Phase-6 (branch already ff-merged
#         and deleted), so this branch is now effectively inert in practice;
#         P1/P1.5/P2/P0 are the only signals expected to actually fire.
#   else  `code`
#
# Usage:
#   leadv2-deploy-classify.sh <task_id>
#   LEADV2_TASK_ID=T1 leadv2-deploy-classify.sh
#
# Shared across 4 repos (~/.claude/leadv2-shared/scripts/, vendored per repo
# under .claude/scripts/). No persona-engine host/IP/service-name/path may
# ever appear here. Sibling scripts resolved via SCRIPT_DIR so this file
# works byte-identically from either tree.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${CLAUDE_PROJECT_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
export LEADV2_PROJECT_ROOT="${LEADV2_PROJECT_ROOT:-${PROJECT_ROOT}}"

# shellcheck source=leadv2-helpers.sh
source "${SCRIPT_DIR}/leadv2-helpers.sh"
_lv2_load_paths

TASK_ID="${1:-${LEADV2_TASK_ID:-}}"
if [[ -z "$TASK_ID" ]]; then
  printf -- '[leadv2-deploy-classify] WARN: no task_id given -- defaulting to code\n' >&2
  echo "code"
  exit 0
fi

# ── P0: explicit env escape hatch, both directions ──────────────────────────
if [[ "${LEADV2_DEPLOY_TASK:-}" == "1" ]]; then
  printf -- '[leadv2-deploy-classify] P0: LEADV2_DEPLOY_TASK=1 -> deploy (explicit override, task=%s)\n' "$TASK_ID" >&2
  echo "deploy"
  exit 0
fi
if [[ "${LEADV2_DEPLOY_TASK:-}" == "0" ]]; then
  printf -- '[leadv2-deploy-classify] P0: LEADV2_DEPLOY_TASK=0 -> code (explicit override, task=%s)\n' "$TASK_ID" >&2
  echo "code"
  exit 0
fi

CONTEXT_YAML="${LEADV2_HANDOFF_DIR}/${TASK_ID}/context.yaml"

if [[ ! -f "$CONTEXT_YAML" ]]; then
  printf -- '[leadv2-deploy-classify] WARN: context.yaml not found (%s) -- defaulting to code\n' "$CONTEXT_YAML" >&2
  echo "code"
  exit 0
fi

# ── P-err/P1/P2/P1.5: task_class / deploy_targets from context.yaml ─────────
# Emits exactly one of: deploy | code_explicit | parse_error | "" (empty).
P1P2_VERDICT="$(python3 -c "
import sys, yaml
try:
    d = yaml.safe_load(open(sys.argv[1])) or {}
except Exception:
    print('parse_error')
    sys.exit(0)
if not isinstance(d, dict):
    print('parse_error')
    sys.exit(0)
task_class = str(d.get('task_class', '') or '').strip().lower()
if task_class in ('deploy', 'ops', 'rollout'):
    print('deploy')
    sys.exit(0)
targets = d.get('deploy_targets')
if isinstance(targets, list) and len(targets) > 0:
    print('deploy')
    sys.exit(0)
if isinstance(targets, str) and targets.strip():
    print('deploy')
    sys.exit(0)
if task_class:
    print('code_explicit')
    sys.exit(0)
print('')
" "$CONTEXT_YAML" 2>/dev/null || echo "parse_error")"

if [[ "$P1P2_VERDICT" == "parse_error" ]]; then
  printf -- '[leadv2-deploy-classify] P-err: context.yaml malformed/unparseable (%s) -- failing CLOSED to deploy (no trustworthy signal, must not let a real deploy task through ungated)\n' "$CONTEXT_YAML" >&2
  echo "deploy"
  exit 0
fi

if [[ "$P1P2_VERDICT" == "deploy" ]]; then
  printf -- '[leadv2-deploy-classify] P1/P2: context.yaml task_class/deploy_targets -> deploy\n' >&2
  echo "deploy"
  exit 0
fi

if [[ "$P1P2_VERDICT" == "code_explicit" ]]; then
  printf -- '[leadv2-deploy-classify] P1.5: context.yaml task_class explicitly set and not deploy-class -> code (explicit signal beats keyword guessing, skips P3)\n' >&2
  echo "code"
  exit 0
fi

# ── P3: keyword regex over mission+task_id, AND-gated by VERIFIED-empty diff ─
MISSION="$(python3 -c "
import sys, yaml
try:
    d = yaml.safe_load(open(sys.argv[1])) or {}
except Exception:
    d = {}
if not isinstance(d, dict):
    d = {}
print(str(d.get('mission', '') or ''))
" "$CONTEXT_YAML" 2>/dev/null || echo "")"

KEYWORD_HIT=0
if printf -- '%s %s' "$MISSION" "$TASK_ID" | grep -qiE '(deploy|rollout|restart|systemd|vps|promote|cutover|rollback)'; then
  KEYWORD_HIT=1
fi

if [[ "$KEYWORD_HIT" -eq 1 ]]; then
  NO_CODE_CHANGE=0
  BRANCH=""
  for _b in "task/$TASK_ID" "worktree-$TASK_ID"; do
    if git -C "$LEADV2_PROJECT_ROOT" show-ref --verify --quiet "refs/heads/$_b" 2>/dev/null; then
      BRANCH="$_b"
      break
    fi
  done
  if [[ -n "$BRANCH" ]]; then
    # Only a git diff that actually succeeded (rc=0) AND printed nothing
    # counts as verified-empty. A failed git command is captured by the
    # `if` condition (set -e safe) and NEVER treated as positive evidence.
    if DIFF="$(git -C "$LEADV2_PROJECT_ROOT" diff --name-only "origin/main...${BRANCH}" 2>/dev/null)"; then
      [[ -z "$DIFF" ]] && NO_CODE_CHANGE=1
    fi
  fi
  # No branch found -> NO_CODE_CHANGE stays 0. Branch-absence (e.g. already
  # ff-merged and deleted by Phase 6, which is true at both real call sites)
  # is NOT trustworthy positive evidence of "no code change" -- it reads
  # identically to a task that never had a branch at all.
  if [[ "$NO_CODE_CHANGE" -eq 1 ]]; then
    printf -- '[leadv2-deploy-classify] P3: keyword match + verified-empty tracked diff -> deploy\n' >&2
    echo "deploy"
    exit 0
  fi
fi

echo "code"
exit 0
