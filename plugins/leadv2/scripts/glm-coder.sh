#!/usr/bin/env bash
# glm-coder.sh v2 — headless GLM-5.2 code-worker wrapper + background workbench
# (Z.AI Coding Plan, Anthropic-compatible endpoint).
#
# v1 surface (unchanged): `run` blocks until GLM finishes (v1 exit code, out-file
# path); `test` self-test. New v2 workbench: `bg` detaches immediately and runs
# under ~/.claude/cache/glm-runs/<run-id>/ with a single-flight per-repo lock,
# stream-json journal, best-effort progress parser, and a process-group timeout
# watchdog. `status`/`tail`/`watch`/`list` mirror codex-task.sh UX.
#
# GLM-ROUTING-V2-01 (design.md Part 2 + Codex review resolutions R1-R5).
set -euo pipefail
umask 077

readonly SECRETS_FILE="${HOME}/.claude/secrets/zai.env"
readonly ZAI_BASE_URL="https://api.z.ai/api/anthropic"
readonly RUNS_DIR="${HOME}/.claude/cache/glm-runs"
readonly GLM_TIMEOUT="${GLM_TIMEOUT:-3600}"
readonly GLM_MAX_TURNS="${GLM_MAX_TURNS:-40}"
readonly SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

# FINISH GUARD (2026-07-03): appended to every real mission prompt (cmd_bg and
# cmd_run — never cmd_test) so the model is told, at the prompt level, not to
# end a run with work parked only in a stash or with no final report. The
# shell-level git-delta audit (git_snapshot_pre/git_finish_guard below) is the
# enforcement layer this trailer cannot replace — a prompt is a request, not a
# guarantee.
readonly FINISH_CONTRACT_TRAILER='

---
FINISH CONTRACT: before ending — pop any stash you created; either commit your work with a descriptive message OR state NOT-COMMITTED with reasons; your final message MUST be a report: files changed, test results (honest), commit hash or NOT-COMMITTED. Never end with work only in a stash.'

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2; }
log_error() { log "ERROR: $*"; }
log_info() { log "INFO: $*"; }

usage() {
  cat >&2 <<'EOF'
Usage:
  glm-coder.sh run "<prompt|@file>" [--out <file>] [--cwd <dir>]
  glm-coder.sh bg  "<prompt|@file>" [--cwd <dir>] [--max-turns N] [--timeout S]
  glm-coder.sh status [run-id]
  glm-coder.sh tail <run-id>
  glm-coder.sh watch <run-id>
  glm-coder.sh list [N]
  glm-coder.sh test

  run     v1-compat: blocks until GLM finishes. Prints only the out-file path
          and the v1 exit code.
  bg      Detaches immediately, prints a run-id. Work continues under
          ~/.claude/cache/glm-runs/<run-id>/ (journal.jsonl, progress.log,
          result.md, meta.yaml). One run per repo (cwd) at a time — a second
          concurrent `bg` for the same repo exits 75 (lock busy).
  status  Prints meta.yaml for <run-id> (latest run if omitted).
  tail    Last 20 progress.log lines + result.md head.
  watch   `tail -f` on progress.log (live).
  list    Last N runs: id, status, repo, started_at. Default N=10.
  test    Self-test: sends a short prompt and prints the tail of the response.

Env knobs: GLM_TIMEOUT (default 3600s), GLM_MAX_TURNS (default 40).
EOF
}

# Loads ZAI_AUTH_TOKEN from the secrets file into the current shell.
# Never echoes the token value anywhere.
load_secret() {
  if [[ ! -f "${SECRETS_FILE}" ]]; then
    log_error "secrets file not found: ${SECRETS_FILE}"
    exit 1
  fi
  local perms
  perms=$(stat -f "%Lp" "${SECRETS_FILE}" 2>/dev/null || stat -c "%a" "${SECRETS_FILE}" 2>/dev/null || echo "")
  if [[ "${perms}" != "600" ]]; then
    log_error "refusing to use secrets file with unsafe perms (${perms:-unknown}), expected 600: ${SECRETS_FILE}"
    exit 1
  fi
  # shellcheck disable=SC1090
  source "${SECRETS_FILE}"
  if [[ -z "${ZAI_AUTH_TOKEN:-}" ]]; then
    log_error "ZAI_AUTH_TOKEN is empty in ${SECRETS_FILE}"
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# v1 blocking path (`run`, `test`) — unchanged behavior, kept intact (R2).
# ---------------------------------------------------------------------------

run_claude() {
  local prompt="$1"
  local out_file="$2"
  local cwd_dir="$3"
  local add_finish_contract="${4:-1}"

  load_secret

  local resolved_prompt="${prompt}"
  if [[ "${prompt}" == @* ]]; then
    local prompt_file="${prompt#@}"
    if [[ ! -f "${prompt_file}" ]]; then
      log_error "prompt file not found: ${prompt_file}"
      exit 1
    fi
    resolved_prompt="$(cat "${prompt_file}")"
  fi
  if [[ "${add_finish_contract}" == "1" ]]; then
    resolved_prompt="${resolved_prompt}${FINISH_CONTRACT_TRAILER}"
  fi

  local exit_code=0
  (
    cd "${cwd_dir}"
    export ANTHROPIC_BASE_URL="${ZAI_BASE_URL}"
    export ANTHROPIC_AUTH_TOKEN="${ZAI_AUTH_TOKEN}"
    export ANTHROPIC_DEFAULT_OPUS_MODEL="glm-5.2"
    export ANTHROPIC_DEFAULT_SONNET_MODEL="glm-5.2"
    export ANTHROPIC_DEFAULT_HAIKU_MODEL="glm-4.5-air"
    export DISABLE_MODEL_AVAILABILITY_CHECK=1
    export API_TIMEOUT_MS=3000000
    command claude -p "${resolved_prompt}" \
      --dangerously-skip-permissions \
      --model sonnet
  ) >"${out_file}" 2>&1 || exit_code=$?

  echo "${out_file}"
  return "${exit_code}"
}

cmd_run() {
  if [[ $# -lt 1 ]]; then
    log_error "run requires a prompt argument"
    usage
    exit 1
  fi
  local prompt="$1"
  shift

  local out_file
  out_file="/tmp/glm-coder-$(date '+%Y%m%d%H%M%S').out"
  local cwd_dir="${PWD}"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --out)
        out_file="$2"
        shift 2
        ;;
      --cwd)
        cwd_dir="$2"
        shift 2
        ;;
      *)
        log_error "unknown argument: $1"
        usage
        exit 1
        ;;
    esac
  done

  if [[ ! -d "${cwd_dir}" ]]; then
    log_error "cwd does not exist: ${cwd_dir}"
    exit 1
  fi

  local exit_code=0
  run_claude "${prompt}" "${out_file}" "${cwd_dir}" || exit_code=$?
  exit "${exit_code}"
}

cmd_test() {
  local out_file
  out_file="/tmp/glm-coder-test-$(date '+%Y%m%d%H%M%S').out"
  local exit_code=0
  # add_finish_contract=0: self-test expects an exact-string reply; the
  # trailer is a real-mission-only instruction (see cmd_run/cmd_bg).
  run_claude "Reply with exactly: GLM-ALIVE <your model id>" "${out_file}" "${PWD}" 0 || exit_code=$?
  log_info "self-test exit code: ${exit_code}"
  tail -n 20 "${out_file}"
  exit "${exit_code}"
}

# ---------------------------------------------------------------------------
# v2 workbench (`bg`, `status`, `tail`, `watch`, `list`) + internal helpers.
# ---------------------------------------------------------------------------

lock_dir_for() { echo "${RUNS_DIR}/.lock-$1"; }

acquire_lock() {
  local repo_hash="$1" timeout_s="$2"
  local lock_dir
  lock_dir="$(lock_dir_for "${repo_hash}")"
  mkdir -p "${RUNS_DIR}"
  if mkdir "${lock_dir}" 2>/dev/null; then
    _write_lock_markers "${lock_dir}"
    return 0
  fi

  local lock_pid lock_started now age
  lock_pid="$(cat "${lock_dir}/pid" 2>/dev/null || echo "")"
  lock_started="$(cat "${lock_dir}/started" 2>/dev/null || echo "")"
  if [[ -z "${lock_started}" ]]; then
    # No `started` marker yet means the owner is still inside its own
    # mkdir-critical-section (or crashed before writing it) — NEVER treat
    # this as age=now-0 (which reclaims a lock microseconds old). Refuse.
    log_error "another GLM run is active for this repo (lock initializing, no started marker yet): ${lock_dir}"
    exit 75
  fi
  now="$(date +%s)"
  age=$(( now - lock_started ))
  if [[ -n "${lock_pid}" ]] && ! kill -0 "${lock_pid}" 2>/dev/null; then
    log_info "reclaiming stale lock (dead pid ${lock_pid}): ${lock_dir}"
  elif [[ "${age}" -gt $((timeout_s + 600)) ]]; then
    log_info "reclaiming stale lock (age ${age}s > timeout+10m): ${lock_dir}"
  else
    log_error "another GLM run is active for this repo (lock: ${lock_dir}, pid: ${lock_pid:-unknown}). Use 'glm-coder.sh list' to inspect."
    exit 75
  fi

  local lock_pgid
  lock_pgid="$(cat "${lock_dir}/pgid" 2>/dev/null || echo "")"
  if [[ -n "${lock_pgid}" ]] && kill -0 -"${lock_pgid}" 2>/dev/null; then
    log_info "terminating orphaned process group ${lock_pgid} before reclaiming lock: ${lock_dir}"
    kill -TERM -"${lock_pgid}" 2>/dev/null || true
    sleep 5
    kill -KILL -"${lock_pgid}" 2>/dev/null || true
  fi
  rm -rf "${lock_dir}"
  if mkdir "${lock_dir}" 2>/dev/null; then
    _write_lock_markers "${lock_dir}"
    return 0
  fi
  log_error "failed to acquire lock after reclaim: ${lock_dir}"
  exit 75
}

# Writes pid+started into an already-mkdir'd lock dir atomically (tmp+mv per
# file) so a concurrent reader never observes a partially-written marker.
_write_lock_markers() {
  local lock_dir="$1"
  local pid_tmp started_tmp
  pid_tmp="$(mktemp "${lock_dir}/.pid.XXXXXX")"
  echo "$$" > "${pid_tmp}"
  mv "${pid_tmp}" "${lock_dir}/pid"
  started_tmp="$(mktemp "${lock_dir}/.started.XXXXXX")"
  date +%s > "${started_tmp}"
  mv "${started_tmp}" "${lock_dir}/started"
}

release_lock() {
  local repo_hash="$1"
  rm -rf "$(lock_dir_for "${repo_hash}")"
}

meta_get() {
  local run_dir="$1" key="$2"
  { grep "^${key}:" "${run_dir}/meta.yaml" 2>/dev/null | head -1 | cut -d: -f2- | sed 's/^ //'; } || true
}

write_meta_initial() {
  local run_dir="$1" run_id="$2" repo="$3" cwd_dir="$4" max_turns="$5" timeout_s="$6" pid="$7"
  local tmp
  tmp="$(mktemp "${run_dir}/.meta.XXXXXX")"
  cat > "${tmp}" <<EOF
run_id: ${run_id}
repo: ${repo}
cwd: ${cwd_dir}
prompt_file: ${run_dir}/prompt.txt
endpoint: ${ZAI_BASE_URL}
model: glm-5.2
max_turns: ${max_turns}
timeout: ${timeout_s}
pid: ${pid}
status: running
exit_code:
turns:
duration_s:
tokens_in: 0
tokens_out: 0
started_at: $(date -u '+%Y-%m-%dT%H:%M:%SZ')
finished_at:
EOF
  mv "${tmp}" "${run_dir}/meta.yaml"
}

finalize_meta() {
  local run_dir="$1" status="$2" exit_code="$3" duration="$4" tokens_in="$5" tokens_out="$6" turns="$7"
  local run_id repo cwd_dir prompt_file endpoint model max_turns timeout_s pid started_at
  run_id="$(meta_get "${run_dir}" run_id)"
  repo="$(meta_get "${run_dir}" repo)"
  cwd_dir="$(meta_get "${run_dir}" cwd)"
  prompt_file="$(meta_get "${run_dir}" prompt_file)"
  endpoint="$(meta_get "${run_dir}" endpoint)"
  model="$(meta_get "${run_dir}" model)"
  max_turns="$(meta_get "${run_dir}" max_turns)"
  timeout_s="$(meta_get "${run_dir}" timeout)"
  pid="$(meta_get "${run_dir}" pid)"
  started_at="$(meta_get "${run_dir}" started_at)"
  local tmp
  tmp="$(mktemp "${run_dir}/.meta.XXXXXX")"
  cat > "${tmp}" <<EOF
run_id: ${run_id}
repo: ${repo}
cwd: ${cwd_dir}
prompt_file: ${prompt_file}
endpoint: ${endpoint}
model: ${model}
max_turns: ${max_turns}
timeout: ${timeout_s}
pid: ${pid}
status: ${status}
exit_code: ${exit_code}
turns: ${turns}
duration_s: ${duration}
tokens_in: ${tokens_in}
tokens_out: ${tokens_out}
started_at: ${started_at}
finished_at: $(date -u '+%Y-%m-%dT%H:%M:%SZ')
EOF
  mv "${tmp}" "${run_dir}/meta.yaml"
}

# macOS ships no util-linux setsid; python3 os.setsid()+execvp is the portable
# equivalent, used to give a subtree its own process group (R4).
#
# MUST be `exec`'d as the function's last command: without `exec`, backgrounding
# a call to this function (`setsid_wrapper ... &`) forks a wrapper subshell whose
# pid ($!) is what callers capture, while python3 (and the setsid'd process it
# execs into) is a further child ONE pid deeper with a DIFFERENT pgid. That
# mismatch silently breaks watchdog_loop's `kill -TERM -$child_pid` (targets a
# nonexistent process group, no-ops) — live-verified via the process tree during
# build (2026-07-03). `exec` replaces the wrapper subshell's own image, so the
# pid callers capture via $! IS the pid that later calls os.setsid() and becomes
# its own process-group leader.
setsid_wrapper() {
  exec python3 -c '
import os, sys

os.setsid()
os.execvp(sys.argv[1], sys.argv[1:])
' "$@"
}

# Best-effort observability filter over stream-json (R3): never determines
# run success/failure — only produces MODEL/TOOL/TOKENS lines for progress.log.
parse_stream() {
  python3 -u -c '
import sys, json

for raw in sys.stdin:
    raw = raw.strip()
    if not raw:
        continue
    try:
        ev = json.loads(raw)
    except Exception:
        continue
    etype = ev.get("type")
    try:
        if etype == "system" and ev.get("subtype") == "init":
            print("MODEL " + str(ev.get("model", "unknown")))
        elif etype == "assistant":
            msg = ev.get("message") or {}
            for block in (msg.get("content") or []):
                if isinstance(block, dict) and block.get("type") == "tool_use":
                    name = block.get("name", "?")
                    inp = block.get("input") or {}
                    detail = inp.get("file_path") or inp.get("command") or inp.get("path") or ""
                    print("TOOL " + str(name) + " " + str(detail)[:120])
            usage = msg.get("usage")
            if usage:
                print("TOKENS in=" + str(usage.get("input_tokens", 0)) + " out=" + str(usage.get("output_tokens", 0)))
    except Exception:
        continue
    sys.stdout.flush()
'
}

# Masks the literal Z.AI token substring wherever it appears in a stream.
# lean: literal-token substring redaction only, not a general secret-pattern
# scanner — upgrade if other secret formats need masking in stderr.
redact_stream() {
  python3 -c '
import sys, os

token = os.environ.get("ZAI_AUTH_TOKEN", "")
for line in sys.stdin:
    if token:
        line = line.replace(token, "[REDACTED]")
    sys.stdout.write(line)
    sys.stdout.flush()
'
}

# Fallback result extraction (R3): last `result`-type event from journal.jsonl.
extract_result() {
  local run_dir="$1"
  python3 -c '
import json, sys, os

run_dir = sys.argv[1]
journal_path = os.path.join(run_dir, "journal.jsonl")
last_result = None
try:
    with open(journal_path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                ev = json.loads(line)
            except Exception:
                continue
            if ev.get("type") == "result":
                last_result = ev
except FileNotFoundError:
    pass

text = ""
if last_result is not None:
    text = last_result.get("result") or last_result.get("text") or ""
    if not text:
        text = json.dumps(last_result)

out_path = os.path.join(run_dir, "result.md")
with open(out_path, "w") as out:
    out.write(text if text else "(no result event found)\n")
' "${run_dir}"
}

sum_tokens() {
  local run_dir="$1" field="$2"
  { grep -oE "TOKENS in=[0-9]+ out=[0-9]+" "${run_dir}/progress.log" 2>/dev/null \
    | grep -oE "${field}=[0-9]+" \
    | cut -d= -f2 \
    | awk '{s+=$1} END {print s+0}'; } || true
}

# ---------------------------------------------------------------------------
# FINISH GUARD (2026-07-03) — deterministic, shell-level git-delta audit
# around every run. Root cause: a run ended RUN_COMPLETE with its work parked
# in a git stash it created mid-run (never popped) and result.md contained
# mid-run narration, not a final report. Detect-and-scream ONLY — never
# auto-pops a stash or auto-commits (too dangerous cross-repo, per spec).
# ---------------------------------------------------------------------------

# PRE-RUN snapshot, written by the supervisor BEFORE the child launches.
# Degrades gracefully (is_repo=0) when cwd_dir is not a git repo.
git_snapshot_pre() {
  local cwd_dir="$1" run_dir="$2"
  local snap="${run_dir}/git-pre.txt"
  if ! git -C "${cwd_dir}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    printf 'is_repo=0\n' > "${snap}"
    return 0
  fi
  local stash_count head_sha
  stash_count="$(git -C "${cwd_dir}" stash list 2>/dev/null | wc -l | tr -d ' ')"
  head_sha="$(git -C "${cwd_dir}" rev-parse HEAD 2>/dev/null || echo NONE)"
  {
    printf 'is_repo=1\n'
    printf 'stash_count=%s\n' "${stash_count}"
    printf 'head_sha=%s\n' "${head_sha}"
  } > "${snap}"
  # Tracked-only porcelain status (excludes untracked '??') for post-run diff.
  git -C "${cwd_dir}" status --porcelain 2>/dev/null | grep -v '^??' > "${run_dir}/git-pre-tracked.txt" || true
}

# POST-RUN audit. Appends FINISH-GUARD sections to result.md and prints the
# warning count (0, 1, or 2 — one per category) on stdout for the caller to
# capture. Never modifies git state itself.
git_finish_guard() {
  local cwd_dir="$1" run_dir="$2"
  local snap="${run_dir}/git-pre.txt"
  local warnings=0

  if [[ ! -f "${snap}" ]]; then
    echo 0
    return 0
  fi
  local is_repo
  is_repo="$(grep '^is_repo=' "${snap}" 2>/dev/null | cut -d= -f2)"
  if [[ "${is_repo}" != "1" ]] || ! git -C "${cwd_dir}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo 0
    return 0
  fi

  local stash_before head_before stash_after head_after
  stash_before="$(grep '^stash_count=' "${snap}" 2>/dev/null | cut -d= -f2)"
  head_before="$(grep '^head_sha=' "${snap}" 2>/dev/null | cut -d= -f2)"
  [[ "${stash_before}" =~ ^[0-9]+$ ]] || stash_before=0
  [[ -n "${head_before}" ]] || head_before="NONE"
  stash_after="$(git -C "${cwd_dir}" stash list 2>/dev/null | wc -l | tr -d ' ')"
  head_after="$(git -C "${cwd_dir}" rev-parse HEAD 2>/dev/null || echo NONE)"

  # --- Stash left behind ------------------------------------------------
  local new_stash_count=$(( stash_after - stash_before ))
  if [[ "${new_stash_count}" -gt 0 ]]; then
    local stash_entries
    stash_entries="$(git -C "${cwd_dir}" stash list 2>/dev/null | head -n "${new_stash_count}")"
    {
      echo ""
      echo "## FINISH-GUARD: STASH LEFT BEHIND"
      while IFS= read -r line; do
        [[ -n "${line}" ]] && echo "- ${line}"
      done <<< "${stash_entries}"
    } >> "${run_dir}/result.md"
    warnings=$(( warnings + 1 ))
  fi

  # --- Tracked files changed but not committed --------------------------
  local pre_tracked="${run_dir}/git-pre-tracked.txt"
  local post_tracked="${run_dir}/git-post-tracked.txt"
  [[ -f "${pre_tracked}" ]] || : > "${pre_tracked}"
  git -C "${cwd_dir}" status --porcelain 2>/dev/null | grep -v '^??' > "${post_tracked}" || true
  local new_dirty
  new_dirty="$(comm -13 <(sort "${pre_tracked}") <(sort "${post_tracked}") 2>/dev/null || true)"
  if [[ -n "${new_dirty}" ]]; then
    {
      echo ""
      echo "## FINISH-GUARD: UNCOMMITTED CHANGES"
      while IFS= read -r line; do
        [[ -n "${line}" ]] && echo "- ${line}"
      done <<< "${new_dirty}"
    } >> "${run_dir}/result.md"
    warnings=$(( warnings + 1 ))
  fi

  # --- Commits made during the run (informational) -----------------------
  if [[ "${head_after}" != "${head_before}" ]] && [[ "${head_before}" != "NONE" ]] && [[ "${head_after}" != "NONE" ]]; then
    local commits
    commits="$(git -C "${cwd_dir}" log --oneline "${head_before}..${head_after}" 2>/dev/null || true)"
    if [[ -n "${commits}" ]]; then
      {
        echo ""
        echo "## Commits made"
        while IFS= read -r line; do
          [[ -n "${line}" ]] && echo "- ${line}"
        done <<< "${commits}"
      } >> "${run_dir}/result.md"
    fi
  fi

  echo "${warnings}"
}

# Internal: launches `claude -p` for one run. Invoked via `$SELF __run_child`
# so it re-execs as a standalone process (own process group via setsid_wrapper).
# Determines exit_code from the child's own exit status ONLY (PIPESTATUS[0]) —
# never from the parser (R3).
cmd_run_child() {
  local run_dir="$1"
  local cwd_dir max_turns
  cwd_dir="$(meta_get "${run_dir}" cwd)"
  max_turns="$(meta_get "${run_dir}" max_turns)"

  load_secret
  export ANTHROPIC_BASE_URL="${ZAI_BASE_URL}"
  export ANTHROPIC_AUTH_TOKEN="${ZAI_AUTH_TOKEN}"
  # ZAI_AUTH_TOKEN itself must also be exported (not just as ANTHROPIC_AUTH_TOKEN)
  # so redact_stream()'s os.environ.get("ZAI_AUTH_TOKEN") below actually sees it —
  # otherwise stderr redaction is dead code (R5 finding, GLM-ROUTING-V2-01 review).
  export ZAI_AUTH_TOKEN
  export ANTHROPIC_DEFAULT_OPUS_MODEL="glm-5.2"
  export ANTHROPIC_DEFAULT_SONNET_MODEL="glm-5.2"
  export ANTHROPIC_DEFAULT_HAIKU_MODEL="glm-4.5-air"
  export DISABLE_MODEL_AVAILABILITY_CHECK=1
  export API_TIMEOUT_MS=3000000

  cd "${cwd_dir}"
  local prompt
  prompt="$(cat "${run_dir}/prompt.txt")"
  # lean: prompt passed via argv, matching design/v1 — upgrade to stdin/tempfile
  # passing if a prompt near bash ARG_MAX is observed in practice.

  set +e
  ( command claude -p "${prompt}" \
      --model sonnet \
      --output-format stream-json \
      --verbose \
      --max-turns "${max_turns}" \
      --permission-mode bypassPermissions \
      2> >(redact_stream >> "${run_dir}/stderr.log")
  ) | tee "${run_dir}/journal.jsonl" | ( parse_stream >> "${run_dir}/progress.log" 2>>"${run_dir}/parser-error.log" || true )
  echo "${PIPESTATUS[0]}" > "${run_dir}/exit_code"
  set -e
}

watchdog_loop() {
  local child_pid="$1" timeout_s="$2" run_dir="$3"
  local waited=0 interval=2
  while [[ ! -f "${run_dir}/.done" ]]; do
    if [[ "${waited}" -ge "${timeout_s}" ]]; then
      printf '[%s] TIMEOUT after %ss -- killing process group %s\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" "${timeout_s}" "${child_pid}" >> "${run_dir}/progress.log"
      kill -TERM "-${child_pid}" 2>/dev/null || true
      sleep 5
      kill -KILL "-${child_pid}" 2>/dev/null || true
      touch "${run_dir}/.timed_out"
      return 0
    fi
    sleep "${interval}"
    waited=$((waited + interval))
  done
}

# Internal: supervisor. Launches the child in its own process group, runs a
# timeout watchdog against ONLY that group (never its own), reaps the child,
# and only then finalizes meta.yaml and releases the lock (R4).
cmd_supervise() {
  local run_dir="$1"
  local repo_hash timeout_s
  repo_hash="$(cat "${run_dir}/.lockref" 2>/dev/null || echo "")"
  timeout_s="$(meta_get "${run_dir}" timeout)"
  [[ -n "${timeout_s}" ]] || timeout_s="${GLM_TIMEOUT}"

  local start_ts
  start_ts="$(date +%s)"

  local cwd_dir
  cwd_dir="$(meta_get "${run_dir}" cwd)"
  git_snapshot_pre "${cwd_dir}" "${run_dir}"

  setsid_wrapper "${SELF}" __run_child "${run_dir}" >>"${run_dir}/child.log" 2>&1 &
  local child_pid=$!
  echo "${child_pid}" > "${run_dir}/pgid"
  # Also persist into the lock dir so a future acquire_lock() reclaim (e.g.
  # after this supervisor crashes/OOMs) can TERM->KILL this orphaned process
  # group before rm -rf'ing the lock (R4 finding, GLM-ROUTING-V2-01 review).
  if [[ -n "${repo_hash}" ]]; then
    echo "${child_pid}" > "$(lock_dir_for "${repo_hash}")/pgid" 2>/dev/null || true
  fi

  ( watchdog_loop "${child_pid}" "${timeout_s}" "${run_dir}" ) &
  local watchdog_pid=$!

  wait "${child_pid}" 2>/dev/null || true
  touch "${run_dir}/.done"
  kill "${watchdog_pid}" 2>/dev/null || true
  wait "${watchdog_pid}" 2>/dev/null || true

  local exit_code
  if [[ -f "${run_dir}/exit_code" ]]; then
    exit_code="$(cat "${run_dir}/exit_code")"
  elif [[ -f "${run_dir}/.timed_out" ]]; then
    exit_code=124
  else
    exit_code=1
  fi

  extract_result "${run_dir}"

  # FINISH GUARD: git-delta audit runs regardless of exit_code — a stash-left
  # or uncommitted-work warning is meaningful even on a failed/timed-out run.
  # Appends sections to result.md; never mutates git state itself (R-detect-
  # only per spec).
  local finish_warnings
  finish_warnings="$(git_finish_guard "${cwd_dir}" "${run_dir}")"
  [[ "${finish_warnings}" =~ ^[0-9]+$ ]] || finish_warnings=0

  local duration=$(( $(date +%s) - start_ts ))
  local tokens_in tokens_out turns status
  tokens_in="$(sum_tokens "${run_dir}" in)"
  tokens_out="$(sum_tokens "${run_dir}" out)"
  turns="$(grep -c '^TOKENS ' "${run_dir}/progress.log" 2>/dev/null || echo 0)"

  # Success = child exit code + result presence, never the parser (R3).
  if [[ "${exit_code}" -eq 0 ]] && [[ -s "${run_dir}/result.md" ]] \
     && ! grep -q '^(no result event found)$' "${run_dir}/result.md"; then
    status="complete"
    # Backward-compat: RUN_COMPLETE is always emitted on its own line first —
    # existing Monitor greps for this literal string keep working unchanged.
    # When the finish guard found something, two extra lines follow so a
    # Monitor pattern can additionally catch the warning without losing the
    # original success signal.
    echo "RUN_COMPLETE" >> "${run_dir}/progress.log"
    if [[ "${finish_warnings}" -gt 0 ]]; then
      echo "RUN_COMPLETE_WITH_WARNINGS" >> "${run_dir}/progress.log"
      echo "FINISH_WARNINGS=${finish_warnings}" >> "${run_dir}/progress.log"
    fi
  else
    status="failed"
    [[ "${exit_code}" -eq 0 ]] && exit_code=1
    {
      echo "RUN_FAILED exit=${exit_code}"
      if [[ -f "${run_dir}/stderr.log" ]]; then
        echo "ERROR: $(tail -n 5 "${run_dir}/stderr.log" | tr '\n' ' ')"
      fi
    } >> "${run_dir}/progress.log"
  fi

  finalize_meta "${run_dir}" "${status}" "${exit_code}" "${duration}" "${tokens_in}" "${tokens_out}" "${turns}"

  [[ -n "${repo_hash}" ]] && release_lock "${repo_hash}"
}

cmd_bg() {
  if [[ $# -lt 1 ]]; then
    log_error "bg requires a prompt argument"
    usage
    exit 1
  fi
  local prompt="$1"
  shift

  local cwd_dir="${PWD}"
  local max_turns="${GLM_MAX_TURNS}"
  local timeout_s="${GLM_TIMEOUT}"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --cwd)
        cwd_dir="$2"
        shift 2
        ;;
      --max-turns)
        max_turns="$2"
        shift 2
        ;;
      --timeout)
        timeout_s="$2"
        shift 2
        ;;
      *)
        log_error "unknown argument: $1"
        usage
        exit 1
        ;;
    esac
  done

  [[ -d "${cwd_dir}" ]] || { log_error "cwd does not exist: ${cwd_dir}"; exit 1; }
  cwd_dir="$(cd "${cwd_dir}" && pwd)"
  [[ "${max_turns}" =~ ^[0-9]+$ ]] || { log_error "--max-turns must be a positive integer"; exit 1; }
  [[ "${timeout_s}" =~ ^[0-9]+$ ]] || { log_error "--timeout must be a positive integer"; exit 1; }

  load_secret

  local repo repo_hash
  repo="$(basename "${cwd_dir}")"
  repo_hash="$(printf '%s' "${cwd_dir}" | shasum -a 256 | cut -c1-12)"

  acquire_lock "${repo_hash}" "${timeout_s}"

  local run_id
  run_id="$(date '+%y%m%d-%H%M%S')-${repo}-$(printf '%04x' $((RANDOM % 65536)))"
  local run_dir="${RUNS_DIR}/${run_id}"
  mkdir -p "${run_dir}"
  chmod 700 "${run_dir}"

  local resolved_prompt="${prompt}"
  if [[ "${prompt}" == @* ]]; then
    local prompt_file="${prompt#@}"
    if [[ ! -f "${prompt_file}" ]]; then
      release_lock "${repo_hash}"
      log_error "prompt file not found: ${prompt_file}"
      exit 1
    fi
    resolved_prompt="$(cat "${prompt_file}")"
  fi
  printf '%s%s' "${resolved_prompt}" "${FINISH_CONTRACT_TRAILER}" > "${run_dir}/prompt.txt"

  write_meta_initial "${run_dir}" "${run_id}" "${repo}" "${cwd_dir}" "${max_turns}" "${timeout_s}" "$$"
  printf '%s\n' "${repo_hash}" > "${run_dir}/.lockref"

  # setsid_wrapper() already detaches the process from the controlling
  # terminal's session (os.setsid()), so it is immune to SIGHUP on its own —
  # `nohup` cannot exec a shell function by name and is not needed here.
  setsid_wrapper "${SELF}" __supervise "${run_dir}" >>"${run_dir}/supervisor.log" 2>&1 &
  local supervisor_pid=$!
  disown

  echo "${supervisor_pid}" > "$(lock_dir_for "${repo_hash}")/pid"
  echo "${run_id}"
}

latest_run_id() {
  mkdir -p "${RUNS_DIR}"
  { ls -1 "${RUNS_DIR}" 2>/dev/null | sort -r | head -1; } || true
}

cmd_status() {
  local run_id="${1:-}"
  if [[ -z "${run_id}" ]]; then
    run_id="$(latest_run_id)"
    [[ -n "${run_id}" ]] || { log_error "no runs found"; exit 1; }
  fi
  local run_dir="${RUNS_DIR}/${run_id}"
  [[ -f "${run_dir}/meta.yaml" ]] || { log_error "run not found: ${run_id}"; exit 1; }
  cat "${run_dir}/meta.yaml"
}

cmd_tail() {
  if [[ $# -lt 1 ]]; then
    log_error "tail requires a run-id"
    exit 1
  fi
  local run_id="$1"
  local run_dir="${RUNS_DIR}/${run_id}"
  [[ -d "${run_dir}" ]] || { log_error "run not found: ${run_id}"; exit 1; }
  echo "--- progress (last 20) ---"
  tail -n 20 "${run_dir}/progress.log" 2>/dev/null || echo "(no progress yet)"
  echo "--- result (head) ---"
  head -c 2000 "${run_dir}/result.md" 2>/dev/null || echo "(no result yet)"
  echo
}

cmd_watch() {
  if [[ $# -lt 1 ]]; then
    log_error "watch requires a run-id"
    exit 1
  fi
  local run_id="$1"
  local run_dir="${RUNS_DIR}/${run_id}"
  [[ -d "${run_dir}" ]] || { log_error "run not found: ${run_id}"; exit 1; }
  tail -f "${run_dir}/progress.log"
}

cmd_list() {
  local n="${1:-10}"
  [[ "${n}" =~ ^[0-9]+$ ]] || n=10
  mkdir -p "${RUNS_DIR}"
  printf '%-28s %-10s %-20s %s\n' "RUN_ID" "STATUS" "REPO" "STARTED_AT"
  local d id status repo started
  for d in "${RUNS_DIR}"/*/; do
    [[ -d "${d}" ]] || continue
    [[ -f "${d}meta.yaml" ]] || continue
    id="$(basename "${d}")"
    status="$(meta_get "${d}" status)"
    repo="$(meta_get "${d}" repo)"
    started="$(meta_get "${d}" started_at)"
    printf '%-28s %-10s %-20s %s\n' "${id}" "${status:-unknown}" "${repo:-?}" "${started:-?}"
  done | sort -r -k1,1 | head -n "${n}"
}

main() {
  if [[ $# -lt 1 ]]; then
    usage
    exit 1
  fi
  mkdir -p "${RUNS_DIR}"
  local subcmd="$1"
  shift
  case "${subcmd}" in
    run)
      cmd_run "$@"
      ;;
    bg)
      cmd_bg "$@"
      ;;
    status)
      cmd_status "$@"
      ;;
    tail)
      cmd_tail "$@"
      ;;
    watch)
      cmd_watch "$@"
      ;;
    list)
      cmd_list "$@"
      ;;
    test)
      cmd_test "$@"
      ;;
    __supervise)
      cmd_supervise "$@"
      ;;
    __run_child)
      cmd_run_child "$@"
      ;;
    *)
      log_error "unknown subcommand: ${subcmd}"
      usage
      exit 1
      ;;
  esac
}

main "$@"
