export const meta = { // MUST be first statement — runtime rejects file otherwise
  name: 'leadv2-causal-critique',
  description: "GEPA-style causal critique of one closed task's run trace (root-cause drivers + REQUIRED evidence pointers), plus a free-text escape hatch (freeform_insight) for lessons that don't fit the 6-enum reflect signature. Reads only verbatim trace-digest slices already on disk (context.yaml/scorecard/review-signature/ledger/git-diff/neg-mem) -- captures nothing new. One schema'd agent() call for the critique itself; evidence-free drivers AND evidence-free freeform_insight are post-filtered/dropped. Never writes reflect-history.yaml itself -- returns causal_critique for the caller (lead-reflect §5a) to fold in. Fail-open: the ENTIRE Digest/Critique/Persist body is wrapped in try/catch -- any agent() failure or exception returns a skip object, never throws past this file. All shell interpolation of external/LLM-derived values (TASK_ID, freeform-insight record JSON) goes through shq() single-quote shell-escaping -- REFLECT-CAUSAL-CRITIQUE-01 fix-round-2 (C1 sibling finding).",
  whenToUse: 'Called from lead-reflect §4.5, gated LEADV2_CAUSAL_CRITIQUE=1, task_class >= Standard (Trivial/Light excluded here too, defense-in-depth). Targets brief #7 (no escape from the 9-value failure_class enum) + #8 (unaudited self-report).',
  phases: [
    { title: 'Digest', detail: 'assemble <=2KB verbatim trace-digest: context.yaml decisions/off_limits/plan/verification, scorecard last row, review-signature.md, ledger.jsonl phase spans, git diff --stat, neg-mem line count (all read-only, gathered via ONE agent() call)' },
    { title: 'Critique', detail: "one schema'd agent() call (model=sonnet, opus if Heavy) -> root_drivers[] with required evidence; drivers AND freeform_insight with empty/unresolvable evidence are dropped post-hoc" },
    { title: 'Persist', detail: 'append optional freeform_insight to docs/leadv2/freeform-insights.jsonl (atomic line-append) + flush ledger telemetry, both via ONE agent() call; return causal_critique + freeform record for the caller' },
  ],
}

// WORKFLOW-BASH-FIX-01: the real Workflow runtime provides ONLY agent()/parallel()/pipeline()/
// log()/phase()/args/budget -- there is NO bash() global. This file previously had 9 real
// `await bash(...)` call-sites (DURABLE_ROOT resolve, 6 read-only digest slices, freeform-insight
// append, and the emitLedger helper) which crashed with "bash is not defined" at runtime.
// Collapsed here into exactly 2 new agent() call-sites: 'gather-digest' (Move 1: DURABLE_ROOT +
// the 6 digest slices) and 'persist' (Move 2: freeform-insight append + ledger flush folded
// together, invoked from both the early Critique-unavailable return and the final return). The
// pre-existing 'causal-critique' agent() call (the actual synthesis work) is untouched -- it was
// never a bash() call. Every command string the agent is asked to execute is built ENTIRELY in
// JS beforehand (identical shq() escaping of TASK_ID, unchanged) and handed to the agent as a
// literal to run VERBATIM via its own Bash tool -- the agent is an executor, never the author of
// shell quoting (R1). See docs/handoff/WORKFLOW-BASH-FIX-01/plan.md.

let a
if (typeof args === 'string') { try { a = JSON.parse(args) } catch { a = { task_id: args } } }
else { a = args }
a = a || {}
const TASK_ID = a.task_id || ''
const TASK_CLASS = a.task_class || 'Standard'

// shq: POSIX single-quote shell-escaping for ANY value that ends up interpolated into a
// command-string template handed to an agent for verbatim execution. REFLECT-CAUSAL-CRITIQUE-01
// fix-round-2 (C1 sibling finding): TASK_ID is external input (from context.yaml / workflow
// args) and must NEVER be spliced unescaped into shell or inline-Python source -- same idiom
// already used correctly for the freeform-insight recordJson below.
function shq(s) {
  return "'" + String(s == null ? '' : s).replace(/'/g, "'\\''") + "'"
}

// Defense-in-depth: the real gate (LEADV2_CAUSAL_CRITIQUE + task_class check) lives in the
// lead-reflect §4.5 caller, but a directly-invoked/misrouted call must also fail open here.
if (TASK_CLASS === 'Trivial' || TASK_CLASS === 'Light') {
  log(`leadv2-causal-critique: skipping for task_class=${TASK_CLASS} (Trivial/Light excluded by design)`)
  return { task_id: TASK_ID, causal_critique: null, freeform_insight: null, skipped_reason: `task_class=${TASK_CLASS}` }
}

// Declared OUTSIDE the try block (function-scoped) so the fail-open catch can still attempt a
// best-effort ledger flush of whatever events were pushed before an exception, without needing
// its own separate agent()-call machinery.
var DURABLE_ROOT = '.'
const ledgerEvents = []
function pushLedger(event, extra) {
  ledgerEvents.push(Object.assign({ event, task_id: TASK_ID || 'unknown' }, extra || {}))
}

const PERSIST_SCHEMA = { type: 'object', additionalProperties: false,
  properties: { append_out: { type: 'string' }, ledger_flushed: { type: 'number' } },
  required: ['append_out', 'ledger_flushed'] }

// Move 2 (Ledger-flush) + write-fold: ONE reusable 'persist' agent() call-site, invoked from
// (a) the early Critique-unavailable return and (b) the final Persist-phase return -- folds the
// freeform-insight append (when a candidate exists) together with the ledger flush into a single
// round-trip each time it runs. Both the append command and every ledger event JSON are built
// ENTIRELY in JS beforehand (unchanged shq()/JSON.stringify escaping) -- the agent only EXECUTES
// the exact strings verbatim via its own Bash tool, never re-derives or re-escapes them (R1).
// Fire-and-forget: any agent() failure here is swallowed, never blocks the workflow return.
async function persistAndFlush(appendCmd) {
  if (!appendCmd && ledgerEvents.length === 0) return { append_out: '' }
  let prompt = 'Run the following via your Bash tool. Do not modify, re-escape, or re-derive any command -- execute each EXACTLY as given between its <<<CMD:name>>> ... <<<END>>> markers.\n\n'
  if (appendCmd) {
    prompt += `First, run this command and capture its trimmed stdout as append_out (empty string if none):\n<<<CMD:append>>>\n${appendCmd}\n<<<END>>>\n\n`
  } else {
    prompt += 'No freeform-insight append is needed this run -- return append_out as an empty string.\n\n'
  }
  if (ledgerEvents.length > 0) {
    prompt += `Then, using this command template, run it once per event below (in order), substituting ` +
      `<event-json> with that event's object, verbatim -- it is already valid JSON, do not reformat or ` +
      `re-derive it:\n<<<CMD:ledger_emit_template>>>\n_EMIT="${DURABLE_ROOT}/.claude/scripts/lv2-ledger-emit.py"; ` +
      `[ -f "$_EMIT" ] || _EMIT="$HOME/.claude/scripts/lv2-ledger-emit.py"; python3 "$_EMIT" '<event-json>' 2>/dev/null || true\n<<<END>>>\n` +
      `Events (in order): ${JSON.stringify(ledgerEvents)}\n\n` +
      'Return ledger_flushed as the number of events processed.'
  } else {
    prompt += 'No ledger events to flush this run -- return ledger_flushed as 0.'
  }
  try {
    const r = await agent(prompt, { label: 'persist', phase: 'Persist', model: 'haiku', effort: 'low', schema: PERSIST_SCHEMA })
    return r || { append_out: '' }
  } catch (_) { return { append_out: '' } }
}

// REFLECT-CAUSAL-CRITIQUE-01 fix-round-2 (HIGH finding, fail-open gap): the ENTIRE body below
// (Digest, Critique, Persist) is wrapped in one try/catch. ANY exception anywhere in this body
// degrades to the same fail-open skip shape used for the agent()-unavailable case.
try {
  // ── Digest phase — Move 1: ONE 'gather-digest' agent() call-site replaces the 7 bash()
  // call-sites (DURABLE_ROOT resolve + 6 read-only trace-digest slices). Every command string
  // is built ENTIRELY in JS below (identical shq() escaping of TASK_ID, unchanged from before
  // this migration); the agent EXECUTES each verbatim via its own Bash tool and returns the 7
  // raw, unformatted fields (R3) -- it never re-derives/re-escapes a command (R1) and never
  // summarizes/reformats digest content. The existing .join('\n').slice(0,2000) formatting
  // below runs unchanged on the returned raw strings.
  phase('Digest')
  pushLedger('phase_enter', { phase: 'Digest', task_id: TASK_ID })

  // MEM-WRITE-PATH-FIX-01 pattern (see leadv2-learn.js): this workflow can run during an
  // in-flight task -- cwd is the task worktree, not the main checkout. freeform-insights.jsonl
  // (like solutions-archive.yaml / ledger.jsonl) only ever lives at the shared main-repo root.
  // Anchored via --git-common-dir, NEVER --show-toplevel (worktree toplevel != main repo root).
  const DURABLE_ROOT_CMD = `_r="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null | xargs dirname 2>/dev/null)"; [ -n "$_r" ] && [ -d "$_r/docs/leadv2" ] && printf '%s' "$_r" || pwd`

  // fix-round-2 C1-sibling: TASK_ID is passed via argv (sys.argv[1]), never spliced into the
  // python -c source string, and never spliced into the surrounding bash double-quoted string
  // either -- shq() keeps it as a single, safely-quoted shell token outside both layers.
  const CTX_DIGEST_CMD = `python3 -c "
import sys, yaml
p = 'docs/handoff/' + sys.argv[1] + '/context.yaml'
try:
    with open(p, encoding='utf-8') as fh: c = yaml.safe_load(fh) or {}
except FileNotFoundError:
    c = {}
out = {
    'decisions': c.get('decisions') or [],
    'off_limits': c.get('off_limits') or [],
    'parallel_groups': (c.get('plan') or {}).get('parallel_groups'),
    'verification': c.get('verification'),
    'start_sha': (c.get('git') or {}).get('start_sha'),
}
print(yaml.dump(out, default_flow_style=False, sort_keys=False)[:900])
" ${shq(TASK_ID)} 2>/dev/null || true`

  const SCORECARD_TAIL_CMD = `tail -n 1 docs/leadv2/scorecard.jsonl 2>/dev/null | cut -c1-400 || true`

  // fix-round-2: TASK_ID is now a shq()-quoted token concatenated into the path, not spliced
  // raw -- safe regardless of quotes/backticks/$()/spaces inside TASK_ID.
  const REVIEW_SIG_CMD = `head -c 500 docs/handoff/${shq(TASK_ID)}/review-signature.md 2>/dev/null || true`

  // fix-round-2: the ENTIRE grep pattern is built as one shq()-escaped argument, not spliced
  // raw inside a hand-written single-quoted literal (which TASK_ID could break out of).
  const LEDGER_SLICE_CMD = `grep ${shq('"task_id":"' + TASK_ID + '"')} docs/leadv2/ledger.jsonl 2>/dev/null | grep -E '"event":"phase_(enter|exit)"' | tail -n 15 | cut -c1-500 || true`

  const NEG_MEM_LINES_CMD = `wc -l < docs/leadv2-negative-memory.yaml 2>/dev/null | tr -d ' ' || printf '0'`

  // diff_stat depends on start_sha, which is only known AFTER ctx_digest's own output is
  // parsed -- start_sha is extracted by a hex-only regex (same charset the original JS regex
  // enforced: [0-9a-f]{7,40}), so substituting the matched value into this templated command is
  // a plain, injection-safe value substitution, never LLM-authored shell quoting (R1 stays
  // intact -- the agent only fills in an already-charset-restricted hex token, it never
  // constructs or re-escapes a shell string from a description).
  const DIFF_STAT_CMD_TEMPLATE = `git diff --stat <START_SHA> 2>/dev/null | tail -n 6 || true`

  const GATHER_DIGEST_SCHEMA = { type: 'object', additionalProperties: false,
    properties: {
      durable_root: { type: 'string' }, ctx_digest: { type: 'string' }, scorecard_tail: { type: 'string' },
      review_sig: { type: 'string' }, ledger_slice: { type: 'string' }, diff_stat: { type: 'string' },
      neg_mem_lines: { type: 'string' },
    },
    required: ['durable_root', 'ctx_digest', 'scorecard_tail', 'review_sig', 'ledger_slice', 'diff_stat', 'neg_mem_lines'] }

  let gatherResult = null
  try {
    gatherResult = await agent(
      'Run each of the labeled shell commands below via your Bash tool EXACTLY as given between ' +
      'its <<<CMD:name>>> ... <<<END>>> markers -- do not modify, re-escape, or re-derive any of ' +
      "them (they are already shell-escaped where needed). Return each command's raw, VERBATIM " +
      "trimmed stdout under the matching schema field. Do not summarize, reformat, or interpret " +
      'any command\'s output.\n\n' +
      `<<<CMD:durable_root>>>\n${DURABLE_ROOT_CMD}\n<<<END>>>\n\n` +
      `<<<CMD:ctx_digest>>>\n${CTX_DIGEST_CMD}\n<<<END>>>\n\n` +
      `<<<CMD:scorecard_tail>>>\n${SCORECARD_TAIL_CMD}\n<<<END>>>\n\n` +
      `<<<CMD:review_sig>>>\n${REVIEW_SIG_CMD}\n<<<END>>>\n\n` +
      `<<<CMD:ledger_slice>>>\n${LEDGER_SLICE_CMD}\n<<<END>>>\n\n` +
      `<<<CMD:neg_mem_lines>>>\n${NEG_MEM_LINES_CMD}\n<<<END>>>\n\n` +
      "For diff_stat: after running the ctx_digest command above, search its raw stdout for a " +
      "line matching the pattern start_sha:\\s*['\"]?([0-9a-f]{7,40})['\"]?. If found, take ONLY " +
      "the matched hex substring (7-40 lowercase hex characters, nothing else -- do not include " +
      "quotes or the 'start_sha:' prefix) and substitute it verbatim for <START_SHA> in the " +
      "command below, then run it. If no such line is found, do NOT run it -- return diff_stat as " +
      `an empty string instead.\n<<<CMD:diff_stat (template, only run if start_sha found)>>>\n${DIFF_STAT_CMD_TEMPLATE}\n<<<END>>>\n\n` +
      'Return the 7 raw fields exactly as specified by the schema -- no additional formatting.',
      { label: 'gather-digest', phase: 'Digest', model: 'haiku', effort: 'low', schema: GATHER_DIGEST_SCHEMA })
  } catch (_) { /* fail-open -- fields default to empty below, Critique still attempted */ }

  DURABLE_ROOT = ((gatherResult && gatherResult.durable_root) || '').trim() || '.'
  const ctxDigest = ((gatherResult && gatherResult.ctx_digest) || '').trim()
  const scorecardTail = ((gatherResult && gatherResult.scorecard_tail) || '').trim()
  const reviewSig = ((gatherResult && gatherResult.review_sig) || '').trim()
  const ledgerSlice = ((gatherResult && gatherResult.ledger_slice) || '').trim()
  const diffStat = ((gatherResult && gatherResult.diff_stat) || '').trim()
  const negMemLines = ((gatherResult && gatherResult.neg_mem_lines) || '').trim() || '0'

  const digest = [
    '--- context.yaml (decisions/off_limits/plan/verification/start_sha) ---', ctxDigest || '(none)',
    '--- scorecard.jsonl (last row) ---', scorecardTail || '(none)',
    '--- review-signature.md ---', reviewSig || '(none)',
    '--- ledger.jsonl (phase_enter/exit for this task) ---', ledgerSlice || '(none)',
    '--- git diff --stat vs start_sha ---', diffStat || '(none / no start_sha)',
    `--- negative-memory.yaml line count: ${negMemLines} (read-only, never modified here) ---`,
  ].join('\n').slice(0, 2000)

  log(`Digest: assembled ${digest.length} chars (cap 2000)`)
  pushLedger('phase_exit', { phase: 'Digest', digest_chars: digest.length })

  // ── Critique phase — one schema'd agent() call, fallback chain, evidence post-filter ────────
  phase('Critique')
  const MODEL = TASK_CLASS === 'Heavy' ? 'opus' : 'sonnet'
  pushLedger('phase_enter', { phase: 'Critique', model: MODEL })

  const CRITIQUE_SCHEMA = {
    type: 'object', additionalProperties: false,
    properties: {
      outcome_summary: { type: 'string' },
      root_drivers: { type: 'array', items: { type: 'object', additionalProperties: false,
        properties: {
          driver: { type: 'string' },
          locus: { type: 'object', additionalProperties: false, properties: {
            phase: { type: 'string' }, llm_step: { type: 'string' }, prompt_or_input: { type: 'string' },
          }, required: ['phase'] },
          evidence: { type: 'string' },       // REQUIRED pointer into the digest; empty/unresolvable -> dropped post-hoc
          counterfactual: { type: 'string' },
          confidence: { type: 'number' },
        }, required: ['driver', 'locus', 'evidence', 'counterfactual', 'confidence'] } },
      cheap_win: { type: ['string', 'null'] },
      // fix-round-2 H1: `required` now forces trace_evidence to be present in the schema
      // response; the JS-side length filter below (Persist phase) is the real enforcement
      // since `required` alone cannot guarantee a NON-EMPTY string.
      freeform_insight: { type: ['object', 'null'], additionalProperties: false, properties: {
        insight: { type: 'string' },          // <=60 words, enforced by prompt + slice() below
        trace_evidence: { type: 'string' },   // REQUIRED pointer into the digest; empty -> dropped post-hoc (mirrors root_drivers)
        recall_tags: { type: 'array', items: { type: 'string' } },
      }, required: ['insight', 'trace_evidence'] },
      summary_for_lead: { type: 'string' },
    }, required: ['outcome_summary', 'root_drivers', 'summary_for_lead'],
  }

  const synthAgent = async function (prompt, opts = {}) {
    const chain = [...new Set([opts.model || 'sonnet', 'sonnet'])]
    for (const m of chain) {
      try {
        const r = await agent(prompt, { ...opts, model: m })
        if (r !== null) return r
      } catch (e) { /* fall through to next model / null */ }
      log(`synthAgent: ${m} unavailable, falling back`)
    }
    return null
  }

  const raw = await synthAgent(
    `You are doing a GEPA-style CAUSAL critique of one closed leadv2 task's run trace -- root causes, ` +
    `not symptoms. Read ONLY the verbatim trace digest below; do not invent facts not present in it. ` +
    `For each root_driver you name, you MUST cite a concrete evidence pointer FROM THE DIGEST ` +
    `(a ledger event, a review-signature line, a scorecard key/value, or a diff-stat line). ` +
    `If you cannot point to evidence in the digest for a claim, DROP the claim -- do not include it. ` +
    `Propose a counterfactual (the smallest change that would have avoided the driver) and a confidence 0..1. ` +
    `If one lesson does not fit any root_driver bucket AND does not fit the existing 6-enum reflect ` +
    `signature, emit it as freeform_insight (<=60 words, 2-5 recall_tags, grounded in a REQUIRED ` +
    `trace_evidence line pointing into the digest -- if you cannot ground it in the digest, do not ` +
    `emit it) -- otherwise return freeform_insight=null. Be factual; "no root causes found" is a ` +
    `valid answer if the digest shows a clean run.\n\n` +
    `Trace digest (task=${TASK_ID}, task_class=${TASK_CLASS}):\n${digest}`,
    { label: 'causal-critique', phase: 'Critique', model: MODEL, effort: 'medium', schema: CRITIQUE_SCHEMA })

  pushLedger('phase_exit', { phase: 'Critique', got_result: raw !== null })

  if (!raw) {
    log('Critique: agent() returned null (unavailable/error) -- fail-open, returning no critique')
    await persistAndFlush(null)
    return { task_id: TASK_ID, causal_critique: null, freeform_insight: null, skipped_reason: 'agent_unavailable' }
  }

  // Anti-hallucination post-filter (mirrors Phase-5 refute discipline): schema `required` alone
  // cannot guarantee a NON-EMPTY evidence string -- enforce a minimum length here.
  const rootDrivers = Array.isArray(raw.root_drivers) ? raw.root_drivers : []
  const keptDrivers = rootDrivers.filter(d => ((d && d.evidence) || '').trim().length >= 3)
  const droppedCount = rootDrivers.length - keptDrivers.length
  if (droppedCount > 0) log(`Critique: dropped ${droppedCount} driver(s) with empty/unresolvable evidence`)

  const causalCritique = {
    outcome_summary: raw.outcome_summary || '',
    root_drivers: keptDrivers,
    cheap_win: raw.cheap_win || null,
  }

  // ── Persist phase — Move 2: optional freeform_insight append + ledger flush, folded into
  // ONE 'persist' agent() call via persistAndFlush (defined above the try block) ────────────────
  phase('Persist')
  pushLedger('phase_enter', { phase: 'Persist' })

  const fi = raw.freeform_insight
  // fix-round-2 H1: mirror the root_drivers evidence filter -- an insight with no (or too-short)
  // trace_evidence is dropped here, exactly like an evidence-free root_driver is dropped above.
  const hasInsight = !!(fi && (fi.insight || '').trim().length > 0)
  const hasEvidence = !!(fi && (fi.trace_evidence || '').trim().length >= 3)
  if (fi && hasInsight && !hasEvidence) {
    log('Persist: freeform_insight dropped -- trace_evidence missing/too short (<3 chars), mirrors root_drivers evidence filter')
  }

  let record = null
  let appendCmd = null
  if (fi && hasInsight && hasEvidence) {
    record = {
      schema_version: 1,
      task_id: TASK_ID,
      task_class: TASK_CLASS,
      author_model: MODEL,
      insight: (fi.insight || '').slice(0, 400),
      trace_evidence: (fi.trace_evidence || '').slice(0, 300),
      signature_escape: true,
      recall_tags: Array.isArray(fi.recall_tags) ? fi.recall_tags.slice(0, 8) : [],
      status: 'candidate', // Tier-B governance (cf. negative-memory) -- never auto-active
    }
    const recordJson = JSON.stringify(record)
    appendCmd = `mkdir -p "${DURABLE_ROOT}/docs/leadv2" && python3 -c "
import json, sys, uuid, datetime
rec = json.loads(sys.argv[1])
rec['id'] = str(uuid.uuid4())
rec['ts'] = datetime.datetime.now(datetime.timezone(datetime.timedelta(hours=2))).isoformat(timespec='minutes')
path = sys.argv[2]
with open(path, 'a', encoding='utf-8') as fh:
    fh.write(json.dumps(rec) + chr(10))
print('appended:' + rec['id'])
" ${shq(recordJson)} "${DURABLE_ROOT}/docs/leadv2/freeform-insights.jsonl" 2>/dev/null || true`
  }

  // Ledger-telemetry note: freeform_written reflects "had a candidate to persist" (known BEFORE
  // the combined call runs), not confirmed append success (only known from this same call's
  // result) -- lets task_close join the ONE persist+flush call below instead of a second
  // round-trip purely to record the true outcome. Ledger is best-effort telemetry, not an
  // authoritative record.
  pushLedger('task_close', {
    phase: 'Persist',
    drivers_kept: causalCritique.root_drivers.length,
    drivers_dropped: droppedCount,
    freeform_written: !!record,
  })

  const persistResult = await persistAndFlush(appendCmd)
  const appendOut = ((persistResult && persistResult.append_out) || '').trim()

  let freeformRecord = null
  if (record && appendOut.startsWith('appended:')) {
    freeformRecord = Object.assign({}, record, { id: appendOut.slice('appended:'.length) })
    log(`Persist: freeform_insight appended id=${freeformRecord.id}`)
  } else if (record) {
    log('Persist: freeform-insights.jsonl append failed -- fail-open, dropping freeform_insight')
  }

  return {
    task_id: TASK_ID,
    causal_critique: causalCritique,
    freeform_insight: freeformRecord,
    summary_for_lead: raw.summary_for_lead || '',
  }
} catch (e) {
  // fix-round-2 HIGH fail-open fix: ANY exception anywhere above (agent() throwing, a JS error
  // in the digest/filter logic) lands here instead of propagating out of the workflow. Best-
  // effort attempt to flush whatever ledger events were pushed before the exception --
  // persistAndFlush already swallows its own agent() failures, so this can never itself break
  // the fail-open contract.
  try { await persistAndFlush(null) } catch (_) { /* never let telemetry break fail-open */ }
  log(`leadv2-causal-critique: exception caught, fail-open skip -- ${e && e.message ? e.message : String(e)}`)
  return { task_id: TASK_ID, causal_critique: null, freeform_insight: null, skipped_reason: 'exception' }
}
