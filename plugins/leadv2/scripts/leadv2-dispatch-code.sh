#!/usr/bin/env bash
# leadv2-dispatch-code.sh — the single funnel for out-of-pipeline code-writing dispatch.
# ROUTING-ENFORCEMENT-01 / R1 (founder P1, 2026-07-25). Authoritative spec:
#   docs/handoff/ROUTING-ENFORCEMENT-01/design.md
#
# PROBLEM THIS SOLVES
#   Out-of-pipeline dev has no router: the lead calls Agent(...) or glm-coder.sh directly
#   and is itself the router, so it picks a model on every dispatch and forgets. The in-
#   pipeline resolver (leadv2-router.sh) only governs /leadv2 phases. This script gives
#   out-of-pipeline dev the same shape: ONE dispatch door that reads the SAME routing
#   policy and RESOLVES the model, so the lead never names a model for code work.
#
# WHAT IT DOES (P1 scope)
#   1. ROUTER: reads `glm_policy` from .claude/ref/leadv2-routing.yaml (single source of
#      truth — same block leadv2-router.sh:197-252 reads), applies the same precedence of
#      sonnet_exceptions / opus_only_mission_kinds predicates, and resolves arm=glm|sonnet
#      (opus arms are reported but NOT auto-dispatched — those stay lead judgment). Emits
#      and journals `route_resolved by=router model=<arm> task=<sig8> rule=<id>`.
#   2. ANTI-DOUBLE-SPEND: a task-signature ledger refuses a SECOND dispatch of the same
#      normalized mission (one task = one model), and a review ledger refuses a SECOND
#      review of the same diff-hash (one review). Refusals are journaled.
#
# KILL SWITCH / NO-OP
#   LEADV2_DISPATCH_ENFORCE=0 -> dedup checks are skipped (resolve+journal still run, no
#   refuse), so existing dispatch is unaffected when the router is "off". Default 1.
#   LEADV2_DISPATCH_SPAWN=0 (or --no-spawn) -> resolve+journal only, no worker launched
#   (e.g. for dedup-only tests). Default 1 (spawn IS the default — see WHAT IT DOES §3).
#   Ledger dirs honor LEADV2_DISPATCH_CACHE_DIR (default ~/.claude/cache) so tests are
#   hermetic and never touch the real cache. LEADV2_DISPATCH_GLM_BIN / _SUBSESSION_BIN
#   override the launchers (test seams; each launcher owns its own stub hooks —
#   GLM_CLAUDE_BIN/GLM_RUNS_DIR/GLM_SECRETS_FILE for glm-coder.sh, LEADV2_DRY_RUN for
#   claude-subsession.sh — this script does not duplicate their stubbing logic).
#
# WHAT IT DOES (R1 FIX, 2026-07-25 — adversarial-review Critical #2)
#   3. SPAWN: resolve+record is not enough on its own -- a routed dispatch that only
#      journals and exits deadlocks (the fence denied the original Agent() call; nothing
#      ever relaunches the work). By DEFAULT (kill switch LEADV2_DISPATCH_SPAWN=0 / flag
#      --no-spawn) this script now actually LAUNCHES the resolved worker and returns
#      immediately with its handle: arm=glm -> `glm-coder.sh bg` (detaches via its own
#      setsid+disown, prints a run-id); arm=sonnet -> `claude-subsession.sh` without
#      --wait (forks `run_subsession &`, prints PID+SESSION_ID, exits immediately). Both
#      launchers already own "detach, never block the caller" -- this script does not
#      duplicate that logic, only calls it. arm=opus is never spawned (lead judgment,
#      unchanged). A `worker_spawned by=router model=<arm> task=<sig8> handle=<h>` line is
#      journaled/emitted so a spawn is never silent.
#
# SCOPE NOTES (what this P1 deliberately does NOT do — later design phases)
#   - Does NOT auto-fallback GLM->Sonnet (design §3(c), Phase 4).
#   - Does NOT add the Bash/code-review PreToolUse fences (design Phase 2/4).
#   The resolver predicates mirror leadv2-router.sh:225-252; if that copy changes, update
#   both (Phase 3 extracts a shared `--resolve-glm` sub-mode — until then THIS is the
#   out-of-pipeline copy and the yaml is the single source of the active exception LIST).
#
# WHAT IT DOES (R1 FIX PASS 2, 2026-07-25 — 4 operational bugs from adversarial review)
#   4. The dispatch-ledger reservation (item 2 above) used to be PERMANENT the instant it
#      was written, before the worker was ever confirmed alive. Three bugs fell out of that:
#      (a) a launch failure left the reservation standing -> the identical retry was refused
#          as a duplicate forever (dead task, no path back to GLM/Sonnet).
#      (b) a no-op launcher (exits 0, spawns nothing -- e.g. LEADV2_DISPATCH_GLM_BIN=/bin/true)
#          emitted `worker_spawned` with an EMPTY handle and consumed the reservation: a
#          silent no-op that looked like a successful dispatch.
#      (c) --no-spawn (dry-run/resolve-only) still wrote the SAME permanent reservation, so a
#          preview call poisoned the ledger for the real dispatch that followed it.
#      FIX: the reservation is now provisional. spawn_worker() requires a non-empty handle
#      AND verifies liveness before reporting success (glm: the launcher's own `status`
#      subcommand resolves a live run-dir without this script duplicating its path logic;
#      sonnet: `kill -0` on the PID parsed from claude-subsession.sh's handle line). Any
#      spawn failure (rc!=0, empty handle, or dead liveness check) OR a --no-spawn dry-run
#      rolls the reservation back (originally via a separately-locked atomic_dispatch_
#      rollback() -- FIX PASS 3 below replaced that with a rollback done INSIDE the SAME
#      held lock as the reservation write, closing a race the separate-lock shape left
#      open; see item 5) -- the identical mission is retryable on the next call in every
#      one of those three cases. A caller-supplied
#      `--glm-failures` count is also no longer trusted to flip glm->sonnet on its own
#      (F1 spoof: no real GLM-failure ledger backs it yet) -- a value that would trip the
#      glm_failed_twice rule is capped to 0 and the ignore is journaled.
#
# WHAT IT DOES (R1 FIX PASS 3, 2026-07-25 — race + 4 High from re-review of fix-pass-2)
#   5. CORE FIX: fix-pass-2's reservation was written under flock, the lock was RELEASED,
#      then spawn ran OUTSIDE the lock, then rollback re-acquired the lock. That opened an
#      UNBOUNDED visibility window: caller A reserves+releases, spawn is pending; caller B
#      checks under lock, SEES A's live-looking reservation, is REFUSED; A's spawn then
#      fails and rolls back -- B was wrongly refused for a task that never dispatched.
#      FIX: atomic_dispatch_reserve_spawn_confirm() now holds ONE `flock -w 10 -x 9` across
#      the ENTIRE check -> reserve -> spawn -> confirm/rollback sequence for the glm/sonnet
#      arms. Both launchers' LAUNCH step is non-blocking (verified against source: glm-
#      coder.sh cmd_bg's acquire_lock is a non-blocking mkdir-try that fails fast (exit 75)
#      rather than waiting, then setsid_wrapper+disown backgrounds the real work and prints
#      the run-id; claude-subsession.sh without --wait forks `run_subsession &`, echoes
#      PID+SESSION_ID, exits) -- so the lock is held only for the reservation write plus a
#      sub-second launch, never for the worker's lifetime. A concurrent caller blocking on
#      `flock -w 10` sees, on entry, the FINAL committed state only: a confirmed row ->
#      refuse; no row (rolled back) -> proceed. No visibility window, no reservation-id
#      needed. (arm=opus never spawns, so it keeps using the simpler reserve-only
#      atomic_dispatch_check_and_record -- no race is possible with nothing to roll back.)
#   6. Four High findings fixed alongside the core fix:
#      a. rollback now removes only the EXACT row this call wrote (full-line match via
#         `grep -vxF`), not a blanket task_sig filter -- see _dispatch_append_line /
#         _dispatch_rollback_row_locked.
#      b. cmd_resolve now checks the rollback outcome; a rollback that fails to write
#         (mktemp/mv) is reported as a hard ERROR (`dispatch_rollback_failed`, non-zero
#         exit) -- it never journals a false `dispatch_rolled_back` success.
#      c. the rollback write itself checks its `mv` return code and propagates failure
#         instead of unconditionally succeeding.
#      d. spawn_worker(sonnet) now requires a parseable `PID=` token in the launcher's
#         handle before treating it as live; a handle with no PID is a launch failure
#         (previously: no-PID handles fell through the `kill -0` check untested and were
#         accepted as live).
#
# WHAT IT DOES (FIX PASS 4, 2026-07-25 — REDESIGN: never hold the lock across spawn)
#   7. Fix-pass-3's "one held flock across reserve->spawn->confirm/rollback" was itself
#      BLOCKED on re-review for two fundamental reasons, so this is a structural redesign,
#      not a patch:
#        (A) the flock FD (9) opened by `) 9>"${lockf}"` is inherited by every descendant
#            process forked while it's open -- including a DETACHED worker a launcher
#            backgrounds (glm-coder.sh's setsid_wrapper+disown, claude-subsession.sh's
#            `run_subsession &`). flock's lock is tied to the OPEN FILE DESCRIPTION, not
#            the locking process: even after fix-pass-3's own subshell exited, a detached
#            worker that inherited a copy of fd 9 kept the lock held for the WORKER'S ENTIRE
#            LIFETIME (minutes-to-hours), so the very next dispatch of ANY task_sig in the
#            repo (the lock is per-repo, not per-sig) timed out on `flock -w 10`.
#        (B) the launch step is not sub-second in practice -- GLM's own quota-read can block
#            up to ~15s -- which exceeds `flock -w 10` on its own even without the FD leak,
#            so a concurrent caller could be wrongly refused by a timeout that has nothing to
#            do with an actual duplicate.
#      FIX: the flock critical section NEVER wraps spawn again. Ledger state moves through
#      pending -> confirmed with a per-reservation UNIQUE token (pid + epoch + random/uuid --
#      not a 1-second timestamp, so two same-second callers still get DISTINCT rows) and two
#      TTLs: PENDING_TTL (>=30s, safely above the ~15s max launch -- LEADV2_DISPATCH_PENDING_TTL_S,
#      default 30) and CONFIRMED_TTL (>= a worker's max realistic lifetime -- a live task should
#      never look "free" while it's still legitimately running -- LEADV2_DISPATCH_CONFIRMED_TTL_S,
#      default 7200/2h) so a worker that dies without ever reaching confirm/abort doesn't block
#      re-dispatch of the same task_sig forever.
#        - dispatch_reserve() (short flock, ledger read+append only -- milliseconds): refuses
#          (rc=2) if a CONFIRMED row for the sig is younger than CONFIRMED_TTL, or a PENDING
#          row for the sig is younger than PENDING_TTL (still legitimately in flight). Else
#          appends a PENDING row carrying our unique token and returns it. A ledger WRITE
#          failure (read-only/full fs) is rc=1 -- hard fail, no spawn attempted (mission
#          Finding: "append-fail-then-false-success").
#        - spawn_worker() runs OUTSIDE any held lock, with the lock fd explicitly closed
#          (`9>&-`) on every launcher invocation as defense-in-depth (belt-and-suspenders:
#          the redesign already means no fd 9 is open in this process by the time spawn_worker
#          runs, since dispatch_reserve's flock subshell has already exited by then -- the
#          explicit close guards against a FUTURE regression, or against this script itself
#          being invoked from inside another caller's own fd-9 flock scope).
#        - dispatch_confirm() (short flock): flips OUR row (matched by the EXACT unique token,
#          never a blanket sig filter) from pending to confirmed. Only called after
#          spawn_worker has POSITIVELY verified liveness (glm: run-dir status check; sonnet:
#          `kill -0` on a parsed PID) -- spawn_worker's own binary success/failure return IS
#          the "real liveness or drop the claim" gate: a return of 0 only ever happens after a
#          positive liveness check, so confirming right after never confirms a merely-not-yet-
#          disproven worker.
#        - dispatch_abort() (short flock): removes OUR row (matched by the EXACT unique token)
#          -- never a blanket sig filter, so a concurrent caller's own in-flight row for the
#          SAME sig (legal once ENFORCE=0, or once ours is confirmed and theirs is a distinct
#          later attempt) is never collaterally deleted. Called when spawn_worker fails, or for
#          --no-spawn (dry-run never confirms).
#      Net effect on races: caller B blocking on dispatch_reserve's short flock sees, on entry,
#      only the LATEST committed row for the sig (pending-and-fresh -> refused; pending-and-
#      stale -> reclaimed, B proceeds; confirmed-and-fresh -> refused; none/removed -> B
#      proceeds) -- B is never blocked for the WORKER'S lifetime, only for the sub-millisecond
#      reserve step, so B typically resolves in well under a second even while A's own launch
#      is still mid-flight (refused fast) or has already failed and rolled back (accepted fast).
#      Stale PENDING/expired CONFIRMED rows are never proactively deleted (only exact-token
#      confirm/abort ever rewrites a row) -- they're simply ignored by dispatch_reserve's
#      blocking check once past their TTL; the ledger accumulates orphaned rows from dead
#      launchers over time, an accepted tradeoff (no GC required for correctness).

set -uo pipefail   # -u safe (quote everything, no unbound vars); NO -e (refusals must journal)

SCRIPT_NAME="leadv2-dispatch-code"
PROJECT_ROOT="${CLAUDE_PROJECT_ROOT:-${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-"$0"}")" 2>/dev/null && pwd)"
ROUTING_YAML="${PROJECT_ROOT}/.claude/ref/leadv2-routing.yaml"
# Overridable so tests can point at /bin/true and avoid writing to the real per-task journal.
JOURNAL_BIN="${LEADV2_JOURNAL_BIN:-${SCRIPT_DIR}/leadv2-journal.sh}"

CACHE_BASE="${LEADV2_DISPATCH_CACHE_DIR:-${HOME}/.claude/cache}"
DISPATCH_LEDGER_DIR="${CACHE_BASE}/dispatch-ledger"
REVIEW_LEDGER_DIR="${CACHE_BASE}/code-review-ledger"
# shellcheck disable=SC2034  # documented config surface (see usage()); the fence hook
# itself, not this script, is the consumer -- Bash-fence wiring is out of scope here.
FENCE_LOG="${LEADV2_DISPATCH_FENCE_LOG:-${CACHE_BASE}/dispatch-fence/denies.jsonl}"
ENFORCE="${LEADV2_DISPATCH_ENFORCE:-1}"
ACTIVE_DISPATCH_TOKEN=""
# FIX PASS 4: pending/confirmed TTLs (see the FIX PASS 4 doc block above). PENDING_TTL must
# stay safely above the launch step's worst-case duration (GLM quota-read ~15s); CONFIRMED_TTL
# must stay above a worker's realistic max lifetime so a still-running task never looks free.
PENDING_TTL="${LEADV2_DISPATCH_PENDING_TTL_S:-30}"
CONFIRMED_TTL="${LEADV2_DISPATCH_CONFIRMED_TTL_S:-7200}"

log()        { printf '[%s] %s\n' "$SCRIPT_NAME" "$*" >&2; }
log_err()    { printf '[%s] ERROR: %s\n' "$SCRIPT_NAME" "$*" >&2; }

# repo slug (ledger file naming; sanitized to filesystem-safe).
repo_slug() {
  local base
  base="$(basename "${PROJECT_ROOT}")"
  printf '%s' "${base}" | tr -cd 'A-Za-z0-9._-'
}

dispatch_ledger_file() { printf '%s/%s.jsonl' "${DISPATCH_LEDGER_DIR}" "$(repo_slug)"; }
review_ledger_file()   { printf '%s/%s.jsonl' "${REVIEW_LEDGER_DIR}"   "$(repo_slug)"; }

# Journal + stderr-emit one structured line. $1=journal-type, $2..=text (one logical line).
# Invoked via `bash <path>` (not direct exec): leadv2-journal.sh ships non-executable, and
# leadv2-state-atomic-write.sh:260 sets this idiom. LEADV2_JOURNAL_BIN override (e.g.
# /bin/true) makes tests hermetic without touching the real per-task journal.
emit() {
  local jtype="$1"; shift
  local line="$*"
  if [[ -n "${JOURNAL_TASK:-}" && -f "${JOURNAL_BIN}" ]]; then
    bash "${JOURNAL_BIN}" append "${JOURNAL_TASK}" "${jtype}" "${line}" >/dev/null 2>&1 || true
  fi
  log "${line}"
}

# ── task signature: normalize mission text, sha256 ────────────────────────────────
# Collapse all whitespace to single spaces, strip CR, trim. Two missions that differ only
# in indentation/case-folded-by-whitespace collapse to the same sig (one task = one model).
compute_sig() {
  tr -d '\r' | tr -s '[:space:]' ' ' | sed -e 's/^ //' -e 's/ $//' | shasum -a 256 | awk '{print $1}'
}

sig_is_hex() { printf '%s' "$1" | grep -qxE '[0-9a-f]{64}'; }

# ── GLM-FIRST-01 policy resolver ──────────────────────────────────────────────────
# Reads glm_policy from routing.yaml (ids + opus_kinds) via regex — no pyyaml dependency,
# same grep-the-yaml idiom leadv2-journal.sh / leadv2-quota-status.sh use. Predicates mirror
# leadv2-router.sh:225-252 (first-match-wins; a sonnet rule fires ONLY if its id is listed).
# Signals arrive via DC_* env vars set from the caller's flags. Prints three lines:
#   arm=<glm|sonnet|opus>   rule=<id|none|opus_only_kind>   reason=<glm_default|...>
# (line-per-field, NOT tab-delimited — BSD sed treats \t as literal 't', which corrupts values.)
# Fail-safe: any error -> arm=glm (the cheap default), reason=resolver_error (observable).
resolve_arm() {
  DC_PROTECTED="${DC_PROTECTED:-0}" \
  DC_SAFETY="${DC_SAFETY:-0}" \
  DC_SUBSYSTEM_COUNT="${DC_SUBSYSTEM_COUNT:-0}" \
  DC_INTERACTIVE="${DC_INTERACTIVE:-0}" \
  DC_UI_JUDGMENT="${DC_UI_JUDGMENT:-0}" \
  DC_KIND="${DC_KIND:-}" \
  DC_GLM_FAILURES="${DC_GLM_FAILURES:-0}" \
  DC_GLM_LOCK_BUSY="${DC_GLM_LOCK_BUSY:-0}" \
  ROUTING_YAML="${ROUTING_YAML}" \
  python3 - <<'PY' || printf 'arm=glm\nrule=none\nreason=resolver_error\ntier=\n'
import os, re, sys
try:
    text = open(os.environ["ROUTING_YAML"], "r").read()
except Exception:
    print("arm=glm"); print("rule=none"); print("reason=no_routing_yaml"); sys.exit(0)

exc_ids, opus_kinds, codex_kinds = [], [], []
codex_default_tier = "standard"
m = re.search(r'(?m)^  glm_policy:\s*\n((?:^[ \t]{4,}.*\n|^[ \t]*\n)+)', text)
if m:
    block = m.group(1)
    for idm in re.finditer(r'(?m)^[ \t]*-[ \t]*id:[ \t]*([A-Za-z0-9_-]+)', block):
        exc_ids.append(idm.group(1))
    okm = re.search(r'(?m)^[ \t]*opus_only_mission_kinds:[ \t]*\[([^\]]*)\]', block)
    if okm:
        opus_kinds = [s.strip() for s in okm.group(1).split(',') if s.strip()]
    cxkm = re.search(r'(?m)^[ \t]*codex_fitting_mission_kinds:[ \t]*\[([^\]]*)\]', block)
    if cxkm:
        codex_kinds = [s.strip() for s in cxkm.group(1).split(',') if s.strip()]
    cxtm = re.search(r'(?m)^[ \t]*codex_default_tier:[ \t]*([A-Za-z0-9_-]+)', block)
    if cxtm:
        codex_default_tier = cxtm.group(1)

def _ge(v, n):
    try: return float(v or 0) >= n
    except (TypeError, ValueError): return False

e = os.environ
sig = {
    "mission_kind":            e.get("DC_KIND", ""),
    "protected_path":          bool(int(e.get("DC_PROTECTED", "0") or 0)),
    "safety_touched":          bool(int(e.get("DC_SAFETY", "0") or 0)),
    "subsystem_count":         float(e.get("DC_SUBSYSTEM_COUNT", "0") or 0),
    "needs_midflight_interaction": bool(int(e.get("DC_INTERACTIVE", "0") or 0)),
    "ui_design_judgment":      bool(int(e.get("DC_UI_JUDGMENT", "0") or 0)),
    "glm_failure_count":       float(e.get("DC_GLM_FAILURES", "0") or 0),
    "glm_lock_busy":           bool(int(e.get("DC_GLM_LOCK_BUSY", "0") or 0)),
}
rules = [
    (bool(sig["mission_kind"]) and sig["mission_kind"] in opus_kinds,
        None, "opus", "opus_mission_kind"),
    (sig["protected_path"] or sig["safety_touched"],
        "safety_gate_publish_payments", "sonnet", "sonnet_exception"),
    (_ge(sig["subsystem_count"], 4) or sig["needs_midflight_interaction"],
        "integration_critical_4subsystems", "sonnet", "sonnet_exception"),
    (sig["ui_design_judgment"],
        "ui_design_judgment", "sonnet", "sonnet_exception"),
    (_ge(sig["glm_failure_count"], 2),
        "glm_failed_twice", "sonnet", "sonnet_exception"),
    (sig["glm_lock_busy"],
        "glm_lock_busy_no_second_channel", "sonnet", "sonnet_exception"),
    # CODEX arm (ROUTING-ENFORCEMENT-01): checked AFTER every sonnet_exceptions rule so a
    # sonnet-exception mission never falls through to codex (mission requirement: "the
    # sonnet exception list still wins over a codex-fitting mission").
    (bool(sig["mission_kind"]) and sig["mission_kind"] in codex_kinds,
        None, "codex", "codex_fitting_mission_kind"),
]
arm, rule, reason, tier = "glm", "none", "glm_default", ""
for pred, rid, base, rsn in rules:
    if not pred:
        continue
    if rid is not None and rid not in exc_ids:
        continue  # id absent from yaml -> rule cannot fire (single source of truth)
    arm, rule, reason = base, (rid or ("codex_fitting_kind" if base == "codex" else "opus_only_kind")), rsn
    break
if arm == "codex":
    tier = codex_default_tier
print("arm=%s" % arm); print("rule=%s" % rule); print("reason=%s" % reason); print("tier=%s" % tier)
PY
}

# ── dispatch-ledger dedup (FIX PASS 4: pending/confirmed + TTL, see doc block above) ──
dispatch_lock_file() { printf '%s/.%s.dispatch.lock' "${DISPATCH_LEDGER_DIR}" "$(repo_slug)"; }
_now_epoch() { date +%s 2>/dev/null || printf '0'; }

# Unique per-reservation token: pid + epoch + uuid/urandom -- NOT a bare 1-second timestamp,
# so two callers that reserve in the SAME UTC second still get DISTINCT, individually
# addressable tokens (mission: "SAME-SECOND UNIQUE"). uuidgen ships on macOS + most Linux
# (util-linux); /dev/urandom is the fallback, $RANDOM x3 the last-resort fallback.
_dispatch_new_token() {
  local pid rnd
  pid="${BASHPID:-$$}"
  if command -v uuidgen >/dev/null 2>&1; then
    rnd="$(uuidgen 2>/dev/null)"   # opaque token -- case doesn't matter, no need to fold
  fi
  if [[ -z "${rnd:-}" ]]; then
    rnd="$(od -An -N8 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"
  fi
  [[ -n "${rnd:-}" ]] || rnd="${RANDOM}${RANDOM}${RANDOM}"
  printf '%s-%s-%s' "${pid}" "$(_now_epoch)" "${rnd}"
}

# Scans every row for <sig>; blocked (rc0) if ANY row is state=confirmed younger than
# CONFIRMED_TTL, or state=pending younger than PENDING_TTL -- both mean a live-or-plausibly-
# live claim on the sig exists right now. A stale pending (dead launcher, never
# confirmed/aborted) or an expired confirmed row is silently ignored (reclaimable) -- rows
# are never proactively deleted for this, only exact-token confirm/abort ever rewrites one.
_dispatch_sig_blocked() {  # <ledger_file> <sig> <now_epoch> -> rc0 blocked; rc1 free/reclaimable
  local f="$1" sig="$2" now="$3"
  [[ -f "${f}" ]] || return 1
  awk -v needle="\"task_sig\":\"${sig}\"" -v now="${now}" -v ptt="${PENDING_TTL}" -v ctt="${CONFIRMED_TTL}" '
    index($0, needle) == 0 { next }
    {
      state = ""; created = 0
      if (match($0, /"state":"[a-z]+"/)) {
        s = substr($0, RSTART, RLENGTH); gsub(/"state":"|"/, "", s); state = s
      }
      if (match($0, /"created_epoch":[0-9]+/)) {
        c = substr($0, RSTART, RLENGTH); sub(/"created_epoch":/, "", c); created = c + 0
      }
      age = now - created
      if (state == "confirmed" && age < ctt) { print "blocked"; exit }
      if (state == "pending"   && age < ptt) { print "blocked"; exit }
    }
  ' "${f}" | grep -q '^blocked$'
}

_dispatch_append_pending_locked() {  # <file> <sig> <arm> <rule> <token> <created_epoch>
  local f="$1" sig="$2" arm="$3" rule="$4" token="$5" created="$6" ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%s)"
  printf '{"task_sig":"%s","arm":"%s","rule":"%s","repo":"%s","ts":"%s","token":"%s","state":"pending","created_epoch":%s}\n' \
    "${sig}" "${arm}" "${rule}" "$(repo_slug)" "${ts}" "${token}" "${created}" >> "${f}"
}

# reserve (SHORT lock: ledger read-check + append ONLY -- milliseconds, never across spawn).
# Returns via exit code + stdout: 0 = reserved, stdout is our unique token; 2 = duplicate
# (a confirmed-and-fresh or pending-and-fresh row already claims this sig -- refuse); 3 =
# lock-wait timeout (hard error, nothing written); 1 = the ledger WRITE itself failed
# (read-only/full fs) -- hard error, caller must NOT proceed to spawn (mission: APPEND-FAIL).
dispatch_reserve() {  # <sig> <arm> <rule> -> stdout: token (rc0 only)
  local sig="$1" arm="$2" rule="$3" lockf f
  f="$(dispatch_ledger_file)"; lockf="$(dispatch_lock_file)"
  mkdir -p "${DISPATCH_LEDGER_DIR}"
  (
    flock -w 10 -x 9 || exit 3
    local now token
    now="$(_now_epoch)"
    if [[ "${ENFORCE}" == "1" ]] && _dispatch_sig_blocked "${f}" "${sig}" "${now}"; then
      exit 2
    fi
    token="$(_dispatch_new_token)"
    if ! _dispatch_append_pending_locked "${f}" "${sig}" "${arm}" "${rule}" "${token}" "${now}"; then
      exit 1
    fi
    printf '%s' "${token}"
    exit 0
  ) 9>"${lockf}"
}

# confirm/abort (SHORT lock each, re-acquired AFTER spawn has already run outside any lock).
# Both match by the EXACT unique token -- never a blanket task_sig filter -- so a concurrent
# caller's own in-flight or already-confirmed row for the SAME sig is never collaterally
# touched (mission: "SAME-SECOND UNIQUE ... each rollback removes only its own row").
_dispatch_confirm_locked() {  # <file> <token> -> rc0 confirmed; rc1 write failed; rc2 row not found
  local f="$1" token="$2" tmp found=0 ln
  [[ -f "${f}" ]] || return 2
  tmp="$(mktemp "${f}.confirm.XXXXXX")" || return 1
  while IFS= read -r ln || [[ -n "${ln}" ]]; do
    if [[ "${ln}" == *"\"token\":\"${token}\""* && "${ln}" == *'"state":"pending"'* ]]; then
      printf '%s\n' "${ln/\"state\":\"pending\"/\"state\":\"confirmed\"}" >> "${tmp}"
      found=1
    else
      printf '%s\n' "${ln}" >> "${tmp}"
    fi
  done < "${f}"
  if ! mv "${tmp}" "${f}"; then
    rm -f "${tmp}" 2>/dev/null
    return 1
  fi
  [[ ${found} -eq 1 ]] && return 0 || return 2
}
_dispatch_abort_locked() {  # <file> <token> -> rc0 removed (or already absent); rc1 write failed
  local f="$1" token="$2" tmp
  [[ -f "${f}" ]] || return 0
  tmp="$(mktemp "${f}.abort.XXXXXX")" || return 1
  # grep -v on a file whose only row matches yields empty output + rc=1 -- not checked, the
  # empty tmp file is still the correct result; only the mv rc below determines success.
  grep -vF "\"token\":\"${token}\"" "${f}" > "${tmp}" 2>/dev/null
  if ! mv "${tmp}" "${f}"; then
    rm -f "${tmp}" 2>/dev/null
    return 1
  fi
  return 0
}
dispatch_confirm() {  # <token> -> rc0 confirmed; rc1 write-fail(hard); rc2 not-found; rc3 lock-timeout
  local token="$1" f lockf
  f="$(dispatch_ledger_file)"; lockf="$(dispatch_lock_file)"
  ( flock -w 10 -x 9 || exit 3
    _dispatch_confirm_locked "${f}" "${token}"
  ) 9>"${lockf}"
}
dispatch_abort() {  # <token> -> rc0 removed/absent; rc1 write-fail(hard); rc3 lock-timeout
  local token="$1" f lockf
  f="$(dispatch_ledger_file)"; lockf="$(dispatch_lock_file)"
  ( flock -w 10 -x 9 || exit 3
    _dispatch_abort_locked "${f}" "${token}"
  ) 9>"${lockf}"
}

# An interruption after reserve but before confirm used to leave a PENDING claim until
# its TTL elapsed.  Normal failure paths still finalize explicitly; this is only the
# process-lifetime safety net for signals/unexpected exits in that small window.
cleanup_pending_dispatch() {
  local token="${ACTIVE_DISPATCH_TOKEN:-}"
  [[ -n "${token}" ]] || return 0
  ACTIVE_DISPATCH_TOKEN=""
  dispatch_abort "${token}" >/dev/null 2>&1 || true
}
trap cleanup_pending_dispatch EXIT
trap 'exit 130' INT TERM

# ── review-ledger dedup ───────────────────────────────────────────────────────────
diff_seen() {  # <hash> -> 0 if already reviewed
  local f; f="$(review_ledger_file)"
  [[ -f "$f" ]] || return 1
  grep -qF "\"diff_hash\":\"$1\"" "$f"
}
record_review() {  # <diff_hash> <verdict> <reviewer> <run_id>
  local f ts
  f="$(review_ledger_file)"; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%s)"
  mkdir -p "${REVIEW_LEDGER_DIR}"
  printf '{"diff_hash":"%s","verdict":"%s","reviewer":"%s","run_id":"%s","repo":"%s","ts":"%s"}\n' \
    "$1" "$2" "$3" "$4" "$(repo_slug)" "$ts" >> "$f"
}
review_lock_file() { printf '%s/.%s.review.lock' "${REVIEW_LEDGER_DIR}" "$(repo_slug)"; }

# Same atomicity fix as atomic_dispatch_check_and_record, for the review ledger's
# diff_hash race (Finding 3/4 both name diff_hash alongside task_sig).
atomic_review_check_and_record() {  # <diff_hash> <verdict> <reviewer> <run_id>
  local hash="$1" verdict="$2" reviewer="$3" run_id="$4" lockf
  mkdir -p "${REVIEW_LEDGER_DIR}"
  lockf="$(review_lock_file)"
  (
    flock -w 10 -x 9 || exit 3
    if [[ "${ENFORCE}" == "1" ]] && diff_seen "${hash}"; then
      exit 2
    fi
    record_review "${hash}" "${verdict}" "${reviewer}" "${run_id}"
    exit 0
  ) 9>"${lockf}"
}

# json-safe: strip quotes/backslashes/newlines from a free-form field (reviewer/run-id).
# shellcheck disable=SC1003  # tr -d '"\\' is correct as-is (literal quote+backslash set)
sanitize_field() { printf '%s' "$1" | tr -d '"\\' | tr '\n' ' ' | tr -cd 'A-Za-z0-9._:/-'; }

# ── spawn: actually launch the resolved worker (Finding 2) ────────────────────────
# GLM_BIN/SUBSESSION_BIN are sibling scripts, overridable so tests stub the underlying
# `claude` call via EACH launcher's OWN seam (glm-coder.sh: GLM_CLAUDE_BIN/GLM_RUNS_DIR/
# GLM_SECRETS_FILE; claude-subsession.sh: LEADV2_DRY_RUN=1) -- this script never
# duplicates that stubbing, it only calls the launcher and reports its handle.
GLM_BIN="${LEADV2_DISPATCH_GLM_BIN:-${SCRIPT_DIR}/glm-coder.sh}"
SUBSESSION_BIN="${LEADV2_DISPATCH_SUBSESSION_BIN:-${SCRIPT_DIR}/claude-subsession.sh}"
# codex-task.sh is the sanctioned Codex channel -- it already owns tier resolution
# (--tier top|standard|volume), detach (task --background), and its own job registry;
# this script never reimplements any of that, only calls it and reads its handle/status.
CODEX_BIN="${LEADV2_DISPATCH_CODEX_BIN:-${SCRIPT_DIR}/codex-task.sh}"

# <arm> <mission> <sig8> -> prints `worker_spawned ...`, journals it, returns 0/1.
# Both launchers detach on their own (glm-coder.sh: setsid_wrapper + disown;
# claude-subsession.sh without --wait: forks `run_subsession &`, prints PID, exits) --
# this function never blocks on the worker finishing, so it cannot deadlock the caller.
# FIX PASS 5 (2026-07-25, live spawn failure): the launchers print their HANDLE on stdout
# but diagnostics on stderr (claude-subsession.sh:458 `cost recorded:` -> stderr, :861
# `PID=... SESSION_ID=...` -> stdout). Capturing `2>&1` merged them, so `tail -1` grabbed
# whichever line flushed last -- in practice the stderr cost line -- and the PID-required
# guard then rejected a worker that had actually launched. Streams are kept SEPARATE now:
# stdout carries the handle, stderr is retained only for the failure message. This is
# launcher-format-agnostic (no PID-pattern grep needed). The wrapper owns the stderr
# tempfile so every early `return` in the body still cleans it up.
spawn_worker() {
  local errf rc
  LAST_ARM_OUTCOME="$1_failed_launcher"
  errf="$(mktemp "${TMPDIR:-/tmp}/leadv2-dispatch-err.XXXXXX")" || {
    log_err "spawn($1): could not create stderr tempfile"; return 1
  }
  _spawn_worker_body "$1" "$2" "$3" "${errf}"; rc=$?
  # REVIEW FIX (critic High, 2026-07-25): the inline log message is capped, so on FAILURE
  # keep the launcher's FULL stderr on disk instead of discarding everything past the tail.
  # The old `2>&1` bug at least preserved all of it in ${out}; this fix pass exists because a
  # launch failure was hard to diagnose, so truncating the next one's evidence would be a
  # regression in exactly the failure mode it targets.
  if [[ ${rc} -ne 0 && -s "${errf}" ]]; then
    local keep="${TMPDIR:-/tmp}/leadv2-dispatch-spawn-$3.stderr.log"
    if cp "${errf}" "${keep}" 2>/dev/null; then
      log_err "spawn($1) full launcher stderr preserved at ${keep}"
    fi
  fi
  rm -f "${errf}"
  return ${rc}
}

# A launcher can decline an arm without being broken.  The GLM quota gate's
# documented REROUTE message is such an admission decision; test launchers and
# future gates may use the explicit LEADV2_DISPATCH_REFUSED marker.  Keep this
# narrow: an arbitrary non-zero exit remains a genuine launcher failure.
refusal_reason() { # <arm> <exit-code> <stdout> <stderr> -> reason, or rc 1
  local arm="$1" rc="$2" out="$3" err="$4" combined
  combined="${out}"$'\n'"${err}"
  local marker
  marker="$(printf '%s\n' "${combined}" | sed -n 's/.*LEADV2_DISPATCH_REFUSED:[[:space:]]*\([A-Za-z0-9._-][A-Za-z0-9._-]*\).*/\1/p' | head -1)"
  # Every arm shares this contract.  Non-zero alone is still a launcher failure;
  # only the documented admission exit codes plus an explicit marker are refusals.
  if [[ -n "${marker}" && ( "${rc}" == "1" || "${rc}" == "2" ) ]]; then
    printf '%s' "${marker}"
    return 0
  fi
  # Compatibility only for older GLM quota gates.  Source gates now emit the marker.
  if [[ "${arm}" == "glm" && "${rc}" == "1" && "${combined}" == *"[glm-quota-gate] REROUTE"* ]]; then
    printf '%s' quota_gate
    return 0
  fi
  return 1
}

_spawn_worker_body() {
  local arm="$1" mission="$2" sig8="$3" errf="$4"
  local out rc handle err
  case "${arm}" in
    glm)
      # FIX PASS 4: `9>&-` closes the lock fd for this call as defense-in-depth -- the
      # redesign already never holds the dispatch lock across spawn (spawn_worker runs
      # outside any lock this script itself opens), but a launcher spawns a DETACHED
      # background worker (setsid_wrapper+disown) that would otherwise inherit ANY fd 9
      # left open by an outer caller (e.g. this script invoked from inside another
      # script's own fd-9 flock scope) and keep that lock held for the worker's lifetime
      # -- exactly the bug this redesign fixes (see FIX PASS 4 doc block).
      out="$(bash "${GLM_BIN}" bg "${mission}" --cwd "${PROJECT_ROOT}" 2>"${errf}" 9>&-)"; rc=$?
      err="$(tail -20 "${errf}" 2>/dev/null)"
      if [[ ${rc} -ne 0 ]]; then
        local refusal
        refusal="$(refusal_reason "${arm}" "${rc}" "${out}" "${err}" || true)"
        if [[ -n "${refusal}" ]]; then
          LAST_ARM_OUTCOME="glm_refused_${refusal}"
          emit decision "arm_refused by=router model=glm task=${sig8} reason=glm_refused_${refusal}"
          log "spawn(glm) refused: ${refusal}"
          return 2
        fi
        emit decision "spawn_failed by=router model=glm task=${sig8} rc=${rc} reason=launcher_nonzero_exit"
        log_err "spawn(glm) failed rc=${rc}: ${out} ${err}"
        return 1
      fi
      handle="$(printf '%s\n' "${out}" | tail -1)"
      # FIX PASS 2 (Finding 2, fake-launcher/empty-handle no-op): a launcher that exits
      # 0 without spawning anything (e.g. LEADV2_DISPATCH_GLM_BIN=/bin/true) must not be
      # treated as a live worker.
      if [[ -z "${handle}" ]]; then
        emit decision "spawn_failed by=router model=glm task=${sig8} reason=empty_handle"
        log_err "spawn(glm) returned an empty handle -- treating as launch failure (no-op launcher?)"
        return 1
      fi
      # Liveness: glm-coder.sh's own `status` subcommand resolves the SAME run-dir this
      # `bg` call used (its RUNS_DIR logic, not duplicated here); no live run record for
      # the handle means no live worker -- the run-id itself isn't a PID, so this is the
      # glm-arm equivalent of the kill -0 check below.
      if ! bash "${GLM_BIN}" status "${handle}" >/dev/null 2>&1 9>&-; then
        emit decision "spawn_failed by=router model=glm task=${sig8} handle=${handle} reason=not_live"
        log_err "spawn(glm) handle=${handle} has no live run record -- treating as launch failure"
        return 1
      fi
      ;;
    sonnet)
      local mfile
      mfile="$(mktemp "${TMPDIR:-/tmp}/leadv2-dispatch-mission.XXXXXX")" || {
        log_err "spawn(sonnet): could not create mission tempfile"; return 1
      }
      printf '%s' "${mission}" > "${mfile}"
      # FIX PASS 4: same `9>&-` defense-in-depth as the glm arm above -- claude-subsession.sh
      # without --wait forks `run_subsession &`, a DETACHED worker that would otherwise
      # inherit any inherited fd 9.
      out="$(PROJECT_ROOT="${PROJECT_ROOT}" bash "${SUBSESSION_BIN}" \
             --role developer --model sonnet \
             --task-id "dispatch-${sig8}" --mission-file "${mfile}" 2>"${errf}" 9>&-)"; rc=$?
      rm -f "${mfile}"
      err="$(tail -20 "${errf}" 2>/dev/null)"
      if [[ ${rc} -ne 0 ]]; then
        local refusal
        refusal="$(refusal_reason "${arm}" "${rc}" "${out}" "${err}" || true)"
        if [[ -n "${refusal}" ]]; then
          LAST_ARM_OUTCOME="sonnet_refused_${refusal}"
          emit decision "arm_refused by=router model=sonnet task=${sig8} reason=sonnet_refused_${refusal}"
          log "spawn(sonnet) refused: ${refusal}"
          return 2
        fi
        emit decision "spawn_failed by=router model=sonnet task=${sig8} rc=${rc} reason=launcher_nonzero_exit"
        log_err "spawn(sonnet) failed rc=${rc}: ${out} ${err}"
        return 1
      fi
      handle="$(printf '%s\n' "${out}" | tail -1)"
      if [[ -z "${handle}" ]]; then
        emit decision "spawn_failed by=router model=sonnet task=${sig8} reason=empty_handle"
        log_err "spawn(sonnet) returned an empty handle -- treating as launch failure (dry-run launcher?)"
        return 1
      fi
      # Liveness: claude-subsession.sh's handle line is `PID=<pid> LABEL=... SESSION_ID=...`
      # (no --wait path); kill -0 the forked PID -- a printed line alone is not proof the
      # process is actually alive.
      # FIX PASS 3 (High finding d): a handle with NO parseable `PID=` token used to fall
      # through this check untested and was accepted as live -- a launcher that prints any
      # non-empty, non-PID text (e.g. only `SESSION_ID=...`) passed the empty-handle guard
      # above and was then wrongly treated as a confirmed spawn. A PID is REQUIRED now; its
      # absence is itself a launch failure, not a skip.
      local pid
      pid="$(printf '%s\n' "${handle}" | sed -n 's/^PID=\([0-9][0-9]*\).*/\1/p')"
      if [[ -z "${pid}" ]]; then
        emit decision "spawn_failed by=router model=sonnet task=${sig8} handle=${handle} reason=no_pid_in_handle"
        log_err "spawn(sonnet) handle='${handle}' has no parseable PID= token -- treating as launch failure"
        return 1
      fi
      if ! kill -0 "${pid}" 2>/dev/null; then
        emit decision "spawn_failed by=router model=sonnet task=${sig8} handle=${handle} reason=not_live"
        log_err "spawn(sonnet) pid=${pid} is not alive -- treating as launch failure"
        return 1
      fi
      ;;
    codex)
      # CODEX arm (ROUTING-ENFORCEMENT-01): launch through the sanctioned codex-task.sh
      # channel only -- `task ... --background` detaches its own job (codex-companion's
      # enqueueBackgroundTask, not something this script spawns/detaches itself) and prints
      # "<title> started in the background as <jobId>." on stdout; codex-task.sh's own
      # CODEX-NEVER-LOSE-01 guard already arms a watcher for that job, this script only
      # needs the jobId back. RESOLVED_CODEX_TIER is set by cmd_resolve from the yaml's
      # glm_policy.codex_default_tier (or defaults to "standard" if unset/empty).
      local tier="${RESOLVED_CODEX_TIER:-standard}"
      local tier_args=(--tier "${tier}")
      # --tier top is gated on --reason by codex-task.sh itself; this router only ever
      # resolves "standard" from the yaml today, but honor a manually-forced top without
      # hard-failing the spawn.
      [[ "${tier}" == "top" ]] && tier_args+=(--reason "leadv2-dispatch-code: codex-fitting mission")
      # `9>&-` closes the lock fd for this call as defense-in-depth -- same rationale as
      # the glm/sonnet arms above: codex-task.sh's --background path detaches a job worker
      # that must never inherit an open fd 9.
      out="$(bash "${CODEX_BIN}" task "${mission}" --background --cwd "${PROJECT_ROOT}"              "${tier_args[@]}" 2>"${errf}" 9>&-)"; rc=$?
      err="$(tail -20 "${errf}" 2>/dev/null)"
      if [[ ${rc} -ne 0 ]]; then
        local refusal
        refusal="$(refusal_reason "${arm}" "${rc}" "${out}" "${err}" || true)"
        if [[ -n "${refusal}" ]]; then
          LAST_ARM_OUTCOME="codex_refused_${refusal}"
          emit decision "arm_refused by=router model=codex task=${sig8} reason=codex_refused_${refusal}"
          log "spawn(codex) refused: ${refusal}"
          return 2
        fi
        emit decision "spawn_failed by=router model=codex task=${sig8} rc=${rc} reason=launcher_nonzero_exit"
        log_err "spawn(codex) failed rc=${rc}: ${out} ${err}"
        return 1
      fi
      # jobId format: <task|review>-<base36-timestamp>-<random6> -- same regex
      # codex-task.sh's own CODEX-NEVER-LOSE-01 guard uses to parse its background output.
      handle="$(printf '%s
' "${out}" | grep -oE '(task|review)-[a-z0-9]+-[a-z0-9]+' | head -1)"
      if [[ -z "${handle}" ]]; then
        emit decision "spawn_failed by=router model=codex task=${sig8} reason=empty_handle"
        log_err "spawn(codex) returned no parseable jobId -- treating as launch failure (no-op launcher?)"
        return 1
      fi
      # Liveness: codex-task.sh's own `status <jobId>` resolves the SAME job registry
      # `task --background` just wrote to (codex-companion's buildSingleJobSnapshot) --
      # it exits non-zero ("No job found for ...") when the id is unknown, so this is the
      # codex-arm equivalent of the glm arm's `status` check / the sonnet arm's `kill -0`.
      if ! bash "${CODEX_BIN}" status "${handle}" >/dev/null 2>&1 9>&-; then
        emit decision "spawn_failed by=router model=codex task=${sig8} handle=${handle} reason=not_live"
        log_err "spawn(codex) handle=${handle} has no live job record -- treating as launch failure"
        return 1
      fi
      ;;
    *)
      log_err "spawn_worker: unsupported arm for spawn: ${arm}"
      return 1
      ;;
  esac
  emit decision "worker_spawned by=router model=${arm} task=${sig8} handle=${handle}"
  printf 'worker_spawned model=%s task=%s handle=%s\n' "${arm}" "${sig8}" "${handle}"
  return 0
}

# ── CORE FIX (fix-pass-4 REDESIGN): reserve (short lock) -> spawn (NO lock) -> confirm/
# abort (short lock) -- see the FIX PASS 4 doc block at the top of this file for why
# fix-pass-3's "one held flock across the whole sequence" was itself blocked (FD-inheritance
# into a detached worker + a launch step that isn't sub-second). Only used for arm in
# {glm, sonnet} (the arms that spawn); arm=opus never spawns and uses
# atomic_dispatch_reserve_confirm_opus below (reserve, then immediately confirm -- nothing
# to ever roll back).
# <sig> <arm> <rule> <mission> <sig8> <do_spawn 0|1> -> stdout: any worker_spawned /
# spawn_failed lines spawn_worker itself prints+journals (unchanged behavior). Returns:
#   0 = confirmed (row kept, live worker spawned; only reachable when do_spawn=1)
#   2 = duplicate/blocked task_sig (a confirmed-and-fresh or pending-and-fresh row already
#       claims it) -- refused before any write, nothing to roll back
#   3 = lock-wait timeout on the reserve step -- hard error, ledger state untouched
#   4 = not confirmed (spawn failed, or do_spawn=0 dry-run) -- abort SUCCEEDED, row removed,
#       an identical retry will be accepted
#   5 = not confirmed AND the abort/confirm WRITE itself failed (mktemp/mv) -- the row may
#       still be present; caller MUST treat this as a hard error, never report a rollback
#       success
#   6 = the RESERVATION write itself failed (read-only/full fs) -- hard error, nothing was
#       ever written, no spawn was attempted (mission: APPEND-FAIL)
#   7 = arm refused admission (for example, the GLM quota gate) -- abort SUCCEEDED
atomic_dispatch_reserve_spawn_confirm() {  # <sig> <arm> <rule> <mission> <sig8> <do_spawn>
  local sig="$1" arm="$2" rule="$3" mission="$4" sig8="$5" do_spawn="$6"
  local token trc
  token="$(dispatch_reserve "${sig}" "${arm}" "${rule}")"; trc=$?
  case "${trc}" in
    0) : ;;                 # reserved -- proceed to spawn, outside any lock
    2) return 2 ;;
    3) return 3 ;;
    *) return 6 ;;          # ledger write failed -- nothing to spawn, nothing to roll back
  esac
  ACTIVE_DISPATCH_TOKEN="${token}"

  local src=1
  if [[ "${do_spawn}" == "1" ]]; then
    spawn_worker "${arm}" "${mission}" "${sig8}"; src=$?
  fi
  if [[ "${do_spawn}" == "1" && ${src} -eq 0 ]]; then
    # spawn_worker only ever returns 0 after POSITIVELY verifying liveness (glm: run-dir
    # status check; sonnet: kill -0 on a parsed PID) -- "real liveness or drop the claim"
    # is already enforced by spawn_worker's own return contract, so confirming right after
    # a 0 return never confirms a merely-unproven worker.
    local crc
    dispatch_confirm "${token}"; crc=$?
    ACTIVE_DISPATCH_TOKEN=""
    [[ ${crc} -eq 0 ]] && return 0
    return 5   # worker IS live but the ledger write to record it failed -- hard error
  fi

  # Not confirmed -- either do_spawn=0 (dry-run, never confirms) or spawn_worker failed
  # (which itself already covers "empty/absent handle = launch failure -> delete pending").
  local arc
  dispatch_abort "${token}"; arc=$?
  ACTIVE_DISPATCH_TOKEN=""
  if [[ ${arc} -eq 0 ]]; then
    [[ ${src} -eq 2 ]] && return 7
    return 4
  fi
  return 5
}

# opus arm never spawns, so there is nothing to roll back -- reserve, then immediately
# confirm (both short locks; the token is never exposed outside this function). Preserves
# the exact external rc contract the old atomic_dispatch_check_and_record had: 0 = recorded,
# 2 = duplicate/blocked, 3 = lock timeout; any other failure (reservation OR confirm write
# failing) collapses to 1 (hard error) -- the caller's existing `-ne 0` catch-all already
# treats that as an error, so no call-site change was needed beyond the function name.
atomic_dispatch_reserve_confirm_opus() {  # <sig> <arm> <rule>
  local sig="$1" arm="$2" rule="$3" token trc crc
  token="$(dispatch_reserve "${sig}" "${arm}" "${rule}")"; trc=$?
  case "${trc}" in
    0) : ;;
    2) return 2 ;;
    3) return 3 ;;
    *) return 1 ;;
  esac
  dispatch_confirm "${token}"; crc=$?
  [[ ${crc} -eq 0 ]] && return 0
  return 1
}

usage() {
  cat >&2 <<EOF
Usage:
  $SCRIPT_NAME <mission|@file|-> [--protected] [--safety] [--subsystems N]
                [--ui-judgment] [--interactive] [--kind <k>] [--glm-failures N]
                [--glm-lock-busy] [--force] [--no-spawn]
                Resolve the code-writing model (glm|sonnet|codex) via routing.yaml glm_policy,
                journal route_resolved, refuse a duplicate task-signature (ATOMIC; --force
                never bypasses it), then LAUNCH the resolved worker and print its handle
                (--no-spawn / LEADV2_DISPATCH_SPAWN=0 for resolve-only). Default arm=glm.
                Exit codes: 0 spawned/resolved, 2 duplicate task-sig, 3 arm=opus (lead
                judgment, not auto-dispatched), 4 spawn failed (retryable -- a failed
                spawn or --no-spawn never leaves a blocking ledger row behind).
  $SCRIPT_NAME record-review --diff-hash <h> --verdict <PASS|FAIL|PASS_WITH_NITS>
                [--reviewer <s>] [--run-id <s>]
                Record a Codex review verdict; refuse a duplicate diff-hash (ATOMIC).
  $SCRIPT_NAME status          Print both ledgers for this repo.
Env: LEADV2_DISPATCH_ENFORCE=0 disables dedup (no-op/pass-through). LEADV2_DISPATCH_SPAWN=0
     disables worker launch (resolve-only). LEADV2_DISPATCH_CACHE_DIR relocates the ledgers
     (tests). LEADV2_DISPATCH_FENCE_LOG sets the fence deny-log path. LEADV2_DISPATCH_GLM_BIN
     / LEADV2_DISPATCH_SUBSESSION_BIN / LEADV2_DISPATCH_CODEX_BIN override the launchers
     (tests).
EOF
  exit 1
}

# ── record-review subcommand ──────────────────────────────────────────────────────
cmd_record_review() {
  local diff_hash="" verdict="" reviewer="codex:standard" run_id="manual"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      # R1 FIX (Finding 5): guard every valued flag's arg-count BEFORE shift 2 --
      # `shift 2` with only 1 positional left fails (bash leaves $# unchanged, no -e
      # to stop it) -> the case falls through to the same flag again -> infinite loop.
      --diff-hash) [[ $# -ge 2 ]] || { log_err "record-review: --diff-hash requires a value"; usage; }
                   diff_hash="$2"; shift 2 ;;
      --verdict)   [[ $# -ge 2 ]] || { log_err "record-review: --verdict requires a value"; usage; }
                   verdict="$2";   shift 2 ;;
      --reviewer)  [[ $# -ge 2 ]] || { log_err "record-review: --reviewer requires a value"; usage; }
                   reviewer="$2";  shift 2 ;;
      --run-id)    [[ $# -ge 2 ]] || { log_err "record-review: --run-id requires a value"; usage; }
                   run_id="$2";    shift 2 ;;
      -h|--help)   usage ;;
      *) log_err "record-review: unknown arg: $1"; usage ;;
    esac
  done
  if ! sig_is_hex "${diff_hash}"; then
    log_err "record-review: --diff-hash must be a 64-char hex sha256"; exit 1
  fi
  case "${verdict}" in
    PASS|FAIL|PASS_WITH_NITS) ;;
    *) log_err "record-review: --verdict must be PASS|FAIL|PASS_WITH_NITS (got: ${verdict:-<empty>})"; exit 1 ;;
  esac
  reviewer="$(sanitize_field "${reviewer}")"; run_id="$(sanitize_field "${run_id}")"
  JOURNAL_TASK="review-${diff_hash:0:8}"
  local rrc
  atomic_review_check_and_record "${diff_hash}" "${verdict}" "${reviewer}" "${run_id}"
  rrc=$?
  if [[ ${rrc} -eq 2 ]]; then
    emit decision "review_refused reason=duplicate_diff_hash diff=${diff_hash:0:8} ledger=$(review_ledger_file)"
    printf 'review_refused reason=duplicate_diff_hash diff=%s\n' "${diff_hash:0:8}"
    exit 2
  elif [[ ${rrc} -ne 0 ]]; then
    log_err "review ledger record failed (rc=${rrc}) for diff=${diff_hash:0:8}"
    exit 1
  fi
  emit decision "review_recorded verdict=${verdict} diff=${diff_hash:0:8} reviewer=${reviewer}"
  printf 'review_recorded verdict=%s diff=%s\n' "${verdict}" "${diff_hash:0:8}"
  exit 0
}

cmd_status() {
  local df rf
  df="$(dispatch_ledger_file)"; rf="$(review_ledger_file)"
  printf 'dispatch-ledger: %s (%s rows)\n' "$df" "$([[ -f "$df" ]] && wc -l < "$df" | tr -d ' ' || echo 0)"
  [[ -f "$df" ]] && cat "$df"
  printf 'review-ledger:   %s (%s rows)\n' "$rf" "$([[ -f "$rf" ]] && wc -l < "$rf" | tr -d ' ' || echo 0)"
  [[ -f "$rf" ]] && cat "$rf"
  exit 0
}

# ── resolve (default) path ────────────────────────────────────────────────────────
cmd_resolve() {
  local mission="" protected=0 safety=0 subsystems=0 ui=0 interactive=0 kind="" glmfails=0 lockbusy=0 force=0
  local spawn="${LEADV2_DISPATCH_SPAWN:-1}"
  local raw
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --protected)    protected=1;   shift ;;
      --safety)       safety=1;      shift ;;
      # R1 FIX (Finding 5): guard arg-count BEFORE shift 2 -- a valued flag with no
      # value left `shift 2` failing silently (no -e) and the SAME flag re-matching
      # next iteration = infinite loop (verified: timeout exit 124 on the old stub).
      --subsystems)   [[ $# -ge 2 ]] || { log_err "--subsystems requires a value"; usage; }
                      subsystems="$2"; shift 2 ;;
      --ui-judgment)  ui=1;          shift ;;
      --interactive)  interactive=1; shift ;;
      --kind)         [[ $# -ge 2 ]] || { log_err "--kind requires a value"; usage; }
                      kind="$2"; shift 2 ;;
      --glm-failures) [[ $# -ge 2 ]] || { log_err "--glm-failures requires a value"; usage; }
                      glmfails="$2"; shift 2 ;;
      --glm-lock-busy) lockbusy=1;   shift ;;
      --force)        force=1;       shift ;;
      --spawn)        spawn=1;       shift ;;  # default; kept explicit for callers/back-compat
      --no-spawn)     spawn=0;       shift ;;  # resolve+journal only, no worker launched (tests)
      -h|--help)      usage ;;
      --*)            log_err "unknown arg: $1"; usage ;;
      *)              mission="${mission}${mission:+ }$1"; shift ;;  # collect positional mission
    esac
  done

  # Resolve the mission text: @file -> read file; "-" -> stdin; else inline.
  raw="${mission}"
  if [[ -z "${raw}" ]]; then
    log_err "missing mission (positional arg, @file, or -)"; usage
  fi
  if [[ "${raw}" == @* ]]; then
    local p="${raw#@}"
    [[ -r "$p" ]] || { log_err "cannot read mission file: $p"; exit 1; }
    mission="$(cat "$p")"
  elif [[ "${raw}" == "-" ]]; then
    mission="$(cat)"
  fi
  [[ -n "${mission//[[:space:]]/}" ]] || { log_err "mission is empty after whitespace strip"; exit 1; }

  local sig sig8
  sig="$(printf '%s' "${mission}" | compute_sig)"
  sig8="${sig:0:8}"
  JOURNAL_TASK="dispatch-${sig8}"
  if [[ -z "${sig}" ]] || ! sig_is_hex "${sig}"; then
    log_err "signature computation failed"; exit 1
  fi

  # FIX PASS 2 (Finding 3 / F1 spoof): a caller-supplied --glm-failures count is
  # UNVERIFIED -- no real GLM-failure ledger backs it yet -- so trusting it directly lets
  # a caller flip glm->sonnet on request alone (`--glm-failures 2`), defeating GLM-FIRST.
  # Cap: any value that would trip the glm_failed_twice rule (>=2) is IGNORED (forced to
  # 0) and the ignore is journaled so a caller relying on it notices; values below the
  # trip threshold are already no-ops, so nothing to cap there. Applies to a raw env
  # override too -- the export below always uses this capped local, never a passed-through
  # value, so DC_GLM_FAILURES can't be smuggled in from the caller's environment either.
  local glmfails_num=0
  [[ "${glmfails}" =~ ^[0-9]+$ ]] && glmfails_num="${glmfails}"
  if (( glmfails_num >= 2 )); then
    emit decision "glm_failures_flag_ignored value=${glmfails} reason=unverified_caller_input_not_ledger_backed task=${sig8}"
    glmfails=0
  fi

  # ROUTER: resolve the model from routing.yaml glm_policy (NOT from a lead choice).
  # Resolution is pure (no side effects, deterministic from the SAME sig/flags every
  # call) so computing it before the atomic ledger section below is safe even for the
  # losing side of a race — only the ledger read+write needs to be atomic.
  export DC_PROTECTED="${protected}" DC_SAFETY="${safety}" DC_SUBSYSTEM_COUNT="${subsystems}" \
         DC_INTERACTIVE="${interactive}" DC_UI_JUDGMENT="${ui}" DC_KIND="${kind}" \
         DC_GLM_FAILURES="${glmfails}" DC_GLM_LOCK_BUSY="${lockbusy}"
  local resolved arm rule reason tier
  resolved="$(resolve_arm)"
  arm="$(printf '%s\n' "${resolved}" | sed -n 's/^arm=//p')"
  rule="$(printf '%s\n' "${resolved}" | sed -n 's/^rule=//p')"
  reason="$(printf '%s\n' "${resolved}" | sed -n 's/^reason=//p')"
  tier="$(printf '%s\n' "${resolved}" | sed -n 's/^tier=//p')"
  [[ -n "${arm}" ]] || { log_err "resolver returned no arm: ${resolved}"; exit 1; }
  # RESOLVED_CODEX_TIER is read by _spawn_worker_body's codex case (global, not passed as
  # a positional -- spawn_worker's signature is shared across all three spawning arms).
  [[ "${arm}" == "codex" ]] && export RESOLVED_CODEX_TIER="${tier:-standard}"

  # ANTI-DOUBLE-SPEND: one task = one model.
  # R1 FIX (Finding 3): --force NEVER bypasses the duplicate-task_sig refusal in the
  # automated path. The router itself never sets an override; --force is still accepted
  # so callers don't hard-fail on an unknown arg, but it is a documented no-op for dedup
  # purposes (logged as such below).

  # opus arms are lead judgment (design/safety/arch) — resolved but NOT auto-dispatched,
  # so there is nothing to spawn or roll back. Keep the simpler reserve-only atomic (no
  # race is possible here: nothing ever needs to be undone for this arm).
  if [[ "${arm}" == "opus" ]]; then
    local orc
    atomic_dispatch_reserve_confirm_opus "${sig}" "${arm}" "${rule}"
    orc=$?
    if [[ ${orc} -eq 2 ]]; then
      if [[ "${force}" == "1" ]]; then
        emit decision "dispatch_override_rejected reason=force_not_permitted task=${sig8} ledger=$(dispatch_ledger_file)"
      fi
      emit decision "dispatch_refused reason=duplicate_task_signature task=${sig8} ledger=$(dispatch_ledger_file)"
      printf 'dispatch_refused reason=duplicate_task_signature task=%s\n' "${sig8}"
      exit 2
    elif [[ ${orc} -ne 0 ]]; then
      log_err "dispatch ledger record failed (rc=${orc}) for task=${sig8}"
      exit 1
    fi
    emit decision "route_resolved by=router model=opus task=${sig8} rule=${rule} reason=${reason}"
    printf 'route_resolved by=router model=opus task=%s rule=%s reason=%s\n' "${sig8}" "${rule}" "${reason}"
    log "route_note model=opus requires_lead_judgment (GLM banned for kind=${kind:-<none>}); not auto-dispatched"
    exit 3
  fi

  # A refusal is an admission signal, not a broken launcher.  Preserve the existing
  # fixed order while Part 0 is in force: the resolved arm is first, followed by
  # the remaining eligible arms in glm -> codex -> sonnet order.  A hard class
  # exception resolving directly to sonnet therefore cannot escape back to GLM.
  local -a candidate_arms attempted
  case "${arm}" in
    glm)   candidate_arms=(glm codex sonnet) ;;
    codex) candidate_arms=(codex sonnet) ;;
    sonnet) candidate_arms=(sonnet) ;;
    *) log_err "unsupported resolved dispatch arm: ${arm}"; exit 1 ;;
  esac

  # ROUTER-QUOTA-DRIVEN-01 (T6): filter candidate_arms by LIVE quota truth
  # BEFORE the operator-override block below. An arm with zero usable headroom
  # (leadv2-quota-read.py T1 usable_now = remaining_pct / max(hours_to_reset,1))
  # is skipped AUTOMATICALLY and returns to rotation on its own the instant its
  # window resets -- no file to edit, nothing to remember. This is what
  # replaced the 2026-07-28 incident: Codex at 0 credits still answers
  # status=completed, so only the quota READER -- never a spawn outcome --
  # can see it is dry; a hand-maintained exclusion list was the stopgap until
  # this shipped and is founder-rejected as the permanent answer.
  # Kill switch: LEADV2_ROUTER_V2_QUOTA_FILTER=0 restores the exact pre-T6
  # behavior (chain order only; exhaustion undetected until a spawn refusal).
  if [[ "${LEADV2_ROUTER_V2_QUOTA_FILTER:-1}" != "0" ]]; then
    local _rv2_bin="${LEADV2_ROUTER_V2_BIN:-${SCRIPT_DIR}/leadv2-router-v2.sh}"
    if [[ -f "${_rv2_bin}" ]]; then
      local _rv2_chain _rv2_out _rv2_rc _rv2_eligible
      _rv2_chain="$(IFS=,; printf '%s' "${candidate_arms[*]}")"
      _rv2_out="$(bash "${_rv2_bin}" resolve --chain "${_rv2_chain}" --task-id "${sig8}" 2>/dev/null)"
      _rv2_rc=$?
      _rv2_eligible="$(printf '%s\n' "${_rv2_out}" | sed -n 's/^eligible=//p')"
      if [[ ${_rv2_rc} -eq 3 || -z "${_rv2_eligible}" ]]; then
        emit decision "dispatch_rolled_back reason=all_arms_exhausted task=${sig8} by=router_v2 chain=${_rv2_chain}"
        log_err "every candidate arm is quota-exhausted (chain='${_rv2_chain}'); refusing to dispatch"
        exit 4
      fi
      local -a _rv2_kept=()
      IFS=',' read -r -a _rv2_kept <<< "${_rv2_eligible}"
      candidate_arms=("${_rv2_kept[@]}")
    fi
  fi

  # ARM-EXCLUSION-01: take an arm out of service without editing the chain.
  # Source: $LEADV2_EXCLUDED_ARMS, else ~/.claude/leadv2-excluded-arms (one arm
  # per line, '#' comments ignored).  This is now an explicit OPERATOR OVERRIDE
  # applied after the automatic quota filter above -- kept for the "take this
  # arm out no matter what its quota says" emergency case, not as the primary
  # exhaustion-detection path.  Revert = delete the file / unset the env var.
  local _ex_src="${LEADV2_EXCLUDED_ARMS:-}"
  if [[ -z "${_ex_src}" && -r "${HOME}/.claude/leadv2-excluded-arms" ]]; then
    _ex_src=$(grep -vE '^\s*(#|$)' "${HOME}/.claude/leadv2-excluded-arms" 2>/dev/null | tr '\n' ' ')
  fi
  if [[ -n "${_ex_src//[[:space:],]/}" ]]; then
    local -a _kept=()
    local _ex_arm
    for _ex_arm in "${candidate_arms[@]}"; do
      if [[ " ${_ex_src//,/ } " == *" ${_ex_arm} "* ]]; then
        emit decision "arm_excluded by=router model=${_ex_arm} task=${sig8} reason=operator_excluded"
        continue
      fi
      _kept+=("${_ex_arm}")
    done
    if [[ ${#_kept[@]} -eq 0 ]]; then
      log_err "every candidate arm is excluded (excluded='${_ex_src}'); refusing to dispatch"
      exit 4
    fi
    candidate_arms=("${_kept[@]}")
  fi

  local candidate arc
  for candidate in "${candidate_arms[@]}"; do
    [[ "${candidate}" == "codex" ]] && export RESOLVED_CODEX_TIER="${tier:-standard}"
    atomic_dispatch_reserve_spawn_confirm "${sig}" "${candidate}" "${rule}" "${mission}" "${sig8}" "${spawn}"
    arc=$?
    case "${arc}" in
    2)
      if [[ "${force}" == "1" ]]; then
        emit decision "dispatch_override_rejected reason=force_not_permitted task=${sig8} ledger=$(dispatch_ledger_file)"
      fi
      emit decision "dispatch_refused reason=duplicate_task_signature task=${sig8} ledger=$(dispatch_ledger_file)"
      printf 'dispatch_refused reason=duplicate_task_signature task=%s\n' "${sig8}"
      exit 2
      ;;
    0)
      emit decision "route_resolved by=router model=${candidate} task=${sig8} rule=${rule} reason=${reason}"
      printf 'route_resolved by=router model=%s task=%s rule=%s reason=%s\n' "${candidate}" "${sig8}" "${rule}" "${reason}"
      exit 0
      ;;
    7)
      attempted+=("${LAST_ARM_OUTCOME:-${candidate}_refused}")
      continue
      ;;
    4)
      if [[ "${spawn}" != "1" ]]; then
        emit decision "route_resolved by=router model=${candidate} task=${sig8} rule=${rule} reason=${reason}"
        printf 'route_resolved by=router model=%s task=%s rule=%s reason=%s\n' "${candidate}" "${sig8}" "${rule}" "${reason}"
        emit decision "dispatch_rolled_back reason=no_spawn_dry_run task=${sig8}"
        exit 0
      fi
      attempted+=("${LAST_ARM_OUTCOME:-${candidate}_failed_launcher}")
      continue
      ;;
    5)
      # High finding b/c (fix-pass-4: now also covers a confirm-write failure AFTER a
      # successful spawn, not just an abort/rollback-write failure): the row may still be
      # sitting in the ledger in the wrong state, or the worker may be live but unrecorded.
      # NEVER report dispatch_rolled_back here; this is a hard error, distinct from the
      # retryable rc=4 case above.
      log_err "dispatch reservation could not be finalized for task=${sig8} model=${candidate} -- ledger write (confirm or abort) FAILED; a spawned worker may be live but NOT recorded -- check manually"
      emit decision "dispatch_rollback_failed task=${sig8} model=${candidate} rule=${rule} reason=$([[ "${spawn}" == "1" ]] && printf spawn_failed_or_confirm_write_failed || printf no_spawn_dry_run)"
      exit 1
      ;;
    6)
      # FIX PASS 4: the RESERVATION write itself failed (read-only/full fs) -- nothing was
      # ever written, no spawn was ever attempted. Distinct from rc=5 (a write failure AFTER
      # a reservation already existed) so the log/journal reason is unambiguous.
      log_err "dispatch reservation FAILED for task=${sig8} model=${candidate} -- ledger write did not land (read-only/full fs?); refusing to spawn"
      emit decision "dispatch_reservation_failed task=${sig8} model=${candidate} rule=${rule}"
      exit 1
      ;;
    3)
      log_err "dispatch lock-wait timeout for task=${sig8}"
      exit 1
      ;;
    *)
      log_err "atomic_dispatch_reserve_spawn_confirm: unexpected rc=${arc} for task=${sig8}"
      exit 1
      ;;
    esac
  done

  local attempted_csv
  attempted_csv="$(IFS=,; printf '%s' "${attempted[*]}")"
  emit decision "dispatch_rolled_back reason=all_arms_unavailable task=${sig8} attempts=${attempted_csv}"
  log_err "all eligible dispatch arms declined or failed for task=${sig8}: ${attempted_csv}"
  exit 4
}

# ── dispatch ──────────────────────────────────────────────────────────────────────
[[ $# -eq 0 ]] && usage
case "${1:-}" in
  record-review) shift; cmd_record_review "$@" ;;
  status)        cmd_status ;;
  -h|--help)     usage ;;
  *)             cmd_resolve "$@" ;;
esac
