#!/usr/bin/env bash
# leadv2-deploy-merge.sh — Phase 6 fast-forward merge + migration apply + deploy override dispatch.
# Extracted verbatim from commands/leadv2.md Phase 6 bash block (src lines 270-296).
# Run from main repo dir (after ExitWorktree). Requires LEADV2_TASK_ID env var.
# Circuit-breakers: ff-only fail, migration fail, deploy-rc fail — all exit 1.
#
# RISK-7-PERSIST-MERGE-RACE-01: this script runs inside a per-task
# Agent(devops-engineer) tool call — an `exit 1` here only kills that
# subprocess, it does NOT halt the calling lead session before Phase 8. Two
# things close that gap:
#   1. Merge serialization: the FIFO leadv2-merge-queue.sh lock is acquired
#      before the divergence/rebase/push section and released right after
#      COMMIT is captured (NOT held through the slow migration/deploy calls
#      below) — so two concurrent children never both fast-forward main.
#   2. Durable blocker: on any of the 7 ff-only-MERGE-path failure sites
#      (divergence preflight, rebase, ff-only pull/merge — NOT migration-apply
#      or deploy-override failures below, which remain a separate follow-up),
#      merge-blocker.flag is written under docs/handoff/<task>/ before
#      exiting, so Phase 8's A6 check (leadv2-phase8-assert.sh) and every
#      status=done writer (leadv2-tasks-lib.sh::leadv2_tasks_release, reached
#      by render-close.sh AND the daemon/lane-queue release path) see it even
#      in a fresh process/session — a failed ff-only merge can no longer be
#      lying-green closed.
#
# DEPLOY-CLASS-VERIFY-GATE-01 (D4): after a successful deploy_rc==0, ALWAYS
# writes a machine-checkable deploy-verify artifact (schema_version:1 YAML)
# to the control plane (worktree-independent) + a docs/handoff/<id>/ mirror.
# Calls the optional per-repo .claude/leadv2-overrides/deploy-verify.sh hook
# (stdout line protocol); hook absent -> artifact still written with
# targets: [] + producer_gap so leadv2-deploy-verify-check.sh fails-closed
# with an actionable message instead of silently skipping verification. No
# VPS host/service-name/path ever enters this shared script — those live
# only inside the per-repo hook.
set -euo pipefail

: "${LEADV2_TASK_ID:?LEADV2_TASK_ID must be set}"
CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-}"

# ── path resolution (same as the rest of the plugin — leadv2-helpers.sh) ────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=leadv2-helpers.sh
source "${SCRIPT_DIR}/leadv2-helpers.sh"
_lv2_load_paths

# ── merge-blocker.flag helper ────────────────────────────────────────────────
BLOCKER="${LEADV2_HANDOFF_DIR}/${LEADV2_TASK_ID}/merge-blocker.flag"
write_blocker() {
  local reason="$1"
  mkdir -p "$(dirname "$BLOCKER")"
  printf -- 'merge_blocked: true\nreason: %s\nfailed_at: %s\ntask_id: %s\n' \
    "$reason" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$LEADV2_TASK_ID" > "$BLOCKER"
}

# ── merge-queue lock: serialize concurrent Phase-6 children ─────────────────
# leadv2-merge-queue.sh already exists (FIFO, python fcntl, dead-holder
# reclaim, 1800s acquire timeout -> exit 2). Not flock(1) — absent on macOS.
MQ="${CLAUDE_PLUGIN_ROOT}/scripts/leadv2-merge-queue.sh"
"$MQ" acquire "$LEADV2_TASK_ID" || exit 2
trap '"$MQ" release "$LEADV2_TASK_ID" 2>/dev/null||true' EXIT

git fetch origin main

# --- Step 0: divergence preflight (FIX #7) ---
BEHIND=$(git rev-list --count HEAD..origin/main 2>/dev/null || echo "0")
if [[ "$BEHIND" -gt 5 ]]; then
  printf '[DIVERGENCE_BLOCK] task branch is %s commits behind origin/main — manual rebase required before deploy\n' "$BEHIND" >&2
  write_blocker "task branch is ${BEHIND} commits behind origin/main — manual rebase required before deploy"
  exit 1
elif [[ "$BEHIND" -gt 0 ]]; then
  printf '[DIVERGENCE] task branch is %s commit(s) behind origin/main — attempting auto-rebase\n' "$BEHIND" >&2
  git rebase origin/main || {
    printf '[DIVERGENCE] rebase conflict — resolve manually then re-run deploy\n' >&2
    write_blocker "rebase conflict — resolve manually then re-run deploy"
    exit 1
  }
  printf '[DIVERGENCE] rebase succeeded — proceeding\n' >&2
fi

# Resolve the actual task branch (EnterWorktree makes worktree-<id>; legacy task/<id>)
TASK_BRANCH=""
for _b in "task/$LEADV2_TASK_ID" "worktree-$LEADV2_TASK_ID"; do
  git show-ref --verify --quiet "refs/heads/$_b" && { TASK_BRANCH="$_b"; break; }
done
if [[ -z "$TASK_BRANCH" ]]; then
  echo "no task branch (task/ or worktree-) for $LEADV2_TASK_ID" >&2
  write_blocker "no task branch (task/ or worktree-) for ${LEADV2_TASK_ID}"
  exit 1
fi
# Rebase the task branch onto origin/main if it is not already a fast-forward (handles stale local main)
if ! git merge-base --is-ancestor origin/main "$TASK_BRANCH"; then
  # Phase 6 ExitWorktree keeps the task branch checked out in a worktree ->
  # `git rebase origin/main "$TASK_BRANCH"` from this (main) checkout fails with
  # "already checked out". Detect that worktree and rebase in-place instead.
  WT_PATH=""
  while IFS= read -r _line; do
    case "$_line" in
      "worktree "*) _cur="${_line#worktree }" ;;
      "branch refs/heads/$TASK_BRANCH") WT_PATH="$_cur" ;;
    esac
  done < <(git worktree list --porcelain)
  if [[ -n "$WT_PATH" ]]; then
    git -C "$WT_PATH" rebase origin/main || {
      echo "rebase onto origin/main conflict — resolve manually" >&2
      write_blocker "rebase onto origin/main conflict — resolve manually"
      exit 1
    }
  else
    git rebase origin/main "$TASK_BRANCH" || {
      echo "rebase onto origin/main conflict — resolve manually" >&2
      write_blocker "rebase onto origin/main conflict — resolve manually"
      exit 1
    }
  fi
fi
git checkout main 2>/dev/null || true
git pull --ff-only origin main || {
  echo "main moved during task — manual rebase needed"
  write_blocker "main moved during task — manual rebase needed"
  exit 1
}
git merge --ff-only "$TASK_BRANCH" || {
  echo "ff-only merge failed — rebase task branch first"
  write_blocker "ff-only merge failed — rebase task branch first"
  exit 1
}
git push origin main
COMMIT=$(git rev-parse HEAD)

# Merge succeeded — clear any stale blocker from a prior failed attempt, and
# release the lock now (NOT held through the slow migration/deploy section
# below).
rm -f "$BLOCKER"
"$MQ" release "$LEADV2_TASK_ID" || {
  write_blocker "post-merge release failed — main advanced but deploy did not run"
  exit 1
}
trap - EXIT

# Apply + register any new migrations introduced by this commit.
bash "${CLAUDE_PLUGIN_ROOT}/scripts/leadv2-migration-apply.sh" --commit "$COMMIT" || {
  echo "BLOCK: migration apply/register failed — manual /migrate repair before deploy" >&2
  exit 1
}

# Deploy via project override (required — configure in .claude/leadv2-overrides/deploy.sh)
OVERRIDE="${CLAUDE_PROJECT_ROOT:-$PWD}/.claude/leadv2-overrides/deploy.sh"
if [[ -f "$OVERRIDE" ]]; then
  deploy_rc=0
  LEAD_V2_TASK_ID="$LEADV2_TASK_ID" LEAD_V2_COMMIT="$COMMIT" bash "$OVERRIDE" || deploy_rc=$?
else
  echo "BLOCK: .claude/leadv2-overrides/deploy.sh not found — run leadv2-init or create it" >&2
  exit 1
fi
[[ $deploy_rc -eq 0 ]] || { echo "Deploy failed (exit $deploy_rc)" >&2; exit 1; }

# ── D4: deploy-verify artifact producer (DEPLOY-CLASS-VERIFY-GATE-01) ───────
# Always runs after a successful deploy — this is the fix for the hollow
# close: a deploy that never produced this artifact now fails-closed at
# leadv2-phase8-assert.sh's A8 / leadv2-phase8-e2e-gate.sh's D6 block.
DEPLOY_VERIFY_HOOK="${CLAUDE_PROJECT_ROOT:-$PWD}/.claude/leadv2-overrides/deploy-verify.sh"
HOOK_STDOUT_FILE="$(mktemp)"
trap 'rm -f "$HOOK_STDOUT_FILE"' EXIT
PRODUCER_GAP=""
if [[ -x "$DEPLOY_VERIFY_HOOK" ]]; then
  # critic2 #5: repo-agnostic backstop timeout -- the per-repo hook (SSH +
  # prod host roster) should time out its own ssh calls, but a hung remote
  # or an override that forgets its own timeout must not stall Phase 6 (and
  # every close behind it) indefinitely.
  LEAD_V2_TASK_ID="$LEADV2_TASK_ID" LEAD_V2_COMMIT="$COMMIT" timeout 90 bash "$DEPLOY_VERIFY_HOOK" > "$HOOK_STDOUT_FILE" 2>&1 || true
else
  PRODUCER_GAP="no .claude/leadv2-overrides/deploy-verify.sh hook found -- add one to enable real deploy verification"
  echo "leadv2-deploy-merge: WARN: ${PRODUCER_GAP}" >&2
  : > "$HOOK_STDOUT_FILE"
fi

# critic1 H1: this command substitution and the python3 write below run
# after deploy_rc==0 (a SUCCESSFUL deploy) under inherited set -euo
# pipefail. Any failure here (state-path mkdir/permission issue, missing
# PyYAML) must never be reported as a generic "deploy failed" -- it is a
# distinct, less severe outcome (the deploy landed; only the verification
# receipt did not).
ARTIFACT_WRITE_OK=1
CONTROL_PLANE_ARTIFACT="$(
  PROJECT_ROOT="$LEADV2_PROJECT_ROOT" \
    "${SCRIPT_DIR}/leadv2-state-path.sh" --no-link "deploy-verify/${LEADV2_TASK_ID}.yaml"
)" || ARTIFACT_WRITE_OK=0
HANDOFF_ARTIFACT="${LEADV2_HANDOFF_DIR}/${LEADV2_TASK_ID}/deploy-verify.yaml"

if [[ "$ARTIFACT_WRITE_OK" -eq 1 ]]; then
if ! python3 - "$CONTROL_PLANE_ARTIFACT" "$HANDOFF_ARTIFACT" "$LEADV2_TASK_ID" "$COMMIT" "$PRODUCER_GAP" "$HOOK_STDOUT_FILE" <<'PYEOF'
import os, sys, tempfile
from datetime import datetime, timezone

control_path, handoff_path, task_id, target_commit, producer_gap, hook_out_file = sys.argv[1:7]
producer_gap = producer_gap or None

# ── parse the hook's dumb stdout line protocol ───────────────────────────
# TARGET name=<label> / DEPLOYED_SHA=<40hex> / PREVIOUS_SHA=<40hex|-> /
# PROBE_CMD=<str> / PROBE_EXIT=<int> -- one block per target.
targets = []
cur = {}

def flush():
    global cur
    if cur:
        targets.append(cur)
    cur = {}

with open(hook_out_file, encoding="utf-8", errors="replace") as fh:
    for line in fh:
        line = line.rstrip("\n")
        if line.startswith("TARGET "):
            flush()
            _, _, kv = line.partition(" ")
            k, _, v = kv.partition("=")
            cur = {"name": v}
        elif line.startswith("DEPLOYED_SHA="):
            cur["deployed_sha"] = line.split("=", 1)[1]
        elif line.startswith("PREVIOUS_SHA="):
            v = line.split("=", 1)[1]
            cur["previous_sha"] = None if v == "-" else v
        elif line.startswith("PROBE_CMD="):
            cur.setdefault("probe", {})["cmd"] = line.split("=", 1)[1]
        elif line.startswith("PROBE_EXIT="):
            try:
                exit_code = int(line.split("=", 1)[1])
            except ValueError:
                exit_code = 1
            cur.setdefault("probe", {})["exit_code"] = exit_code
    flush()

now_iso = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
final_targets = []
for t in targets:
    if "name" not in t:
        continue
    probe = t.get("probe", {})
    exit_code = probe.get("exit_code", 1)
    final_targets.append({
        "name": t["name"],
        # critic2 #6: never drop a target whose probe failed to observe a
        # sha (unreachable/deleted host) -- keep it with deployed_sha: None,
        # which can never match target_commit, so the gate fails it instead
        # of silently shrinking "PASS: N target(s)" below the real roster.
        "deployed_sha": t.get("deployed_sha"),
        "previous_sha": t.get("previous_sha"),
        "sha_advanced": t.get("previous_sha") != t.get("deployed_sha"),
        "probe": {
            "cmd": probe.get("cmd", ""),
            "exit_code": exit_code,
            "observed_at": now_iso,
            "result": "pass" if exit_code == 0 else "fail",
        },
    })

if not final_targets and not producer_gap:
    producer_gap = "hook produced no parseable TARGET lines"

_skip_flag = os.environ.get("LEADV2_SKIP_DEPLOY_VERIFY", "")
_skip_reason = os.environ.get("LEADV2_SKIP_DEPLOY_VERIFY_REASON", "").strip()
_bypassed = _skip_flag == "1"
_bypass_reason = _skip_reason if (_bypassed and _skip_reason) else None

payload = {
    "schema_version": 1,
    "task_id": task_id,
    "verified_at": now_iso,
    "target_commit": target_commit,
    "producer": "leadv2-deploy-merge.sh",
    "producer_gap": producer_gap,
    "targets": final_targets,
    "bypassed": _bypassed,
    "bypass_reason": _bypass_reason,
}

def atomic_write(path, data):
    import yaml
    directory = os.path.dirname(path)
    os.makedirs(directory, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".deploy-verify.", suffix=".tmp", dir=directory)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            yaml.safe_dump(data, fh, sort_keys=False)
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass
        raise

atomic_write(control_path, payload)
atomic_write(handoff_path, payload)
print(f"[leadv2-deploy-merge] deploy-verify artifact written: {control_path} (+ mirror {handoff_path})")
PYEOF
then
  ARTIFACT_WRITE_OK=0
fi
fi

rm -f "$HOOK_STDOUT_FILE"
trap - EXIT

if [[ "$ARTIFACT_WRITE_OK" -eq 0 ]]; then
  echo "ARTIFACT_WRITE_FAILED: deploy succeeded (commit $COMMIT) but the deploy-verify artifact could not be written -- re-run leadv2-deploy-verify-check.sh manually once the underlying issue (state-path/permissions/PyYAML) is fixed" >&2
  exit 3
fi

echo "Deploy complete (commit $COMMIT)"
