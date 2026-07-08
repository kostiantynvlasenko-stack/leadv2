export const meta = { // MUST be first statement — runtime rejects file otherwise
  name: 'leadv2-causal-critique',
  description: "GEPA-style causal critique of one closed task's run trace (root-cause drivers + REQUIRED evidence pointers), plus a free-text escape hatch (freeform_insight) for lessons that don't fit the 6-enum reflect signature. Reads only verbatim trace-digest slices already on disk (context.yaml/scorecard/review-signature/ledger/git-diff/neg-mem) -- captures nothing new. One schema'd agent() call; evidence-free drivers AND evidence-free freeform_insight are post-filtered/dropped. Never writes reflect-history.yaml itself -- returns causal_critique for the caller (lead-reflect §5a) to fold in. Fail-open: the ENTIRE Digest/Critique/Persist body is wrapped in try/catch -- any bash()/agent() failure or exception returns a skip object, never throws past this file. All shell interpolation of external/LLM-derived values (TASK_ID, freeform-insight record JSON) goes through shq() single-quote shell-escaping -- REFLECT-CAUSAL-CRITIQUE-01 fix-round-2 (C1 sibling finding).",
  whenToUse: 'Called from lead-reflect §4.5, gated LEADV2_CAUSAL_CRITIQUE=1, task_class >= Standard (Trivial/Light excluded here too, defense-in-depth). Targets brief #7 (no escape from the 9-value failure_class enum) + #8 (unaudited self-report).',
  phases: [
    { title: 'Digest', detail: 'assemble <=2KB verbatim trace-digest: context.yaml decisions/off_limits/plan/verification, scorecard last row, review-signature.md, ledger.jsonl phase spans, git diff --stat, neg-mem line count (all read-only)' },
    { title: 'Critique', detail: "one schema'd agent() call (model=sonnet, opus if Heavy) -> root_drivers[] with required evidence; drivers AND freeform_insight with empty/unresolvable evidence are dropped post-hoc" },
    { title: 'Persist', detail: 'append optional freeform_insight to docs/leadv2/freeform-insights.jsonl (atomic line-append, status=candidate); return causal_critique + freeform record for the caller' },
  ],
}

let a
if (typeof args === 'string') { try { a = JSON.parse(args) } catch { a = { task_id: args } } }
else { a = args }
a = a || {}
const TASK_ID = a.task_id || ''
const TASK_CLASS = a.task_class || 'Standard'

// shq: POSIX single-quote shell-escaping for ANY value that ends up interpolated into a
// bash() command-string template. REFLECT-CAUSAL-CRITIQUE-01 fix-round-2 (C1 sibling finding,
// leadv2-causal-critique.js:73 originally): TASK_ID is external input (from context.yaml /
// workflow args) and must NEVER be spliced unescaped into shell or inline-Python source --
// same idiom already used correctly for the freeform-insight recordJson below.
function shq(s) {
  return "'" + String(s == null ? '' : s).replace(/'/g, "'\\''") + "'"
}

// Defense-in-depth: the real gate (LEADV2_CAUSAL_CRITIQUE + task_class check) lives in the
// lead-reflect §4.5 caller, but a directly-invoked/misrouted call must also fail open here.
if (TASK_CLASS === 'Trivial' || TASK_CLASS === 'Light') {
  log(`leadv2-causal-critique: skipping for task_class=${TASK_CLASS} (Trivial/Light excluded by design)`)
  return { task_id: TASK_ID, causal_critique: null, freeform_insight: null, skipped_reason: `task_class=${TASK_CLASS}` }
}

// REFLECT-CAUSAL-CRITIQUE-01 fix-round-2 (HIGH finding, fail-open gap): the ENTIRE body below
// (DURABLE_ROOT resolution, Digest, Critique, Persist) is wrapped in one try/catch. Previously
// a thrown bash()/agent() exception (as opposed to a bash command that merely exits non-zero,
// which `|| true` already tolerates) would abort the async IIFE before any skip object could be
// returned -- violating "never blocks close". Now ANY exception anywhere in this body degrades
// to the same fail-open skip shape used for the agent()-unavailable case.
try {
  // MEM-WRITE-PATH-FIX-01 pattern (see leadv2-learn.js): this workflow can run during an
  // in-flight task -- cwd is the task worktree, not the main checkout. freeform-insights.jsonl
  // (like solutions-archive.yaml / ledger.jsonl) only ever lives at the shared main-repo root.
  // Anchored via --git-common-dir, NEVER --show-toplevel (worktree toplevel != main repo root).
  var DURABLE_ROOT = (await bash(
    `_r="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null | xargs dirname 2>/dev/null)"; [ -n "$_r" ] && [ -d "$_r/docs/leadv2" ] && printf '%s' "$_r" || pwd`
  )).trim() || '.'

  // Fire-and-forget ledger emit — never throws, never blocks the workflow on failure.
  var emitLedger = async function (event, extra) {
    const ev = Object.assign({ event, task_id: TASK_ID || 'unknown' }, extra || {})
    try {
      await bash(
        `_EMIT="${DURABLE_ROOT}/.claude/scripts/lv2-ledger-emit.py"; [ -f "$_EMIT" ] || _EMIT="$HOME/.claude/scripts/lv2-ledger-emit.py"; python3 "$_EMIT" ${shq(JSON.stringify(ev))} 2>/dev/null || true`
      )
    } catch (_) { /* fire-and-forget */ }
  }

  // additionalProperties:false everywhere — schema drift protection (design §self-check).
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

  // ── Digest phase — verbatim slices only, no new capture, capped at 2KB total ────────────────
  phase('Digest')
  await emitLedger('phase_enter', { phase: 'Digest', task_id: TASK_ID })

  // fix-round-2 C1-sibling: TASK_ID is passed via argv (sys.argv[1]), never spliced into the
  // python -c source string, and never spliced into the surrounding bash double-quoted string
  // either -- shq() keeps it as a single, safely-quoted shell token outside both layers.
  const ctxDigest = (await bash(
    `python3 -c "
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
  )).trim()

  const startShaMatch = ctxDigest.match(/start_sha:\s*['"]?([0-9a-f]{7,40})['"]?/)
  const startSha = startShaMatch ? startShaMatch[1] : ''

  const scorecardTail = (await bash(
    `tail -n 1 docs/leadv2/scorecard.jsonl 2>/dev/null | cut -c1-400 || true`
  )).trim()

  // fix-round-2: TASK_ID is now a shq()-quoted token concatenated into the path, not spliced
  // raw -- safe regardless of quotes/backticks/$()/spaces inside TASK_ID.
  const reviewSig = (await bash(
    `head -c 500 docs/handoff/${shq(TASK_ID)}/review-signature.md 2>/dev/null || true`
  )).trim()

  // fix-round-2: the ENTIRE grep pattern is built as one shq()-escaped argument, not spliced
  // raw inside a hand-written single-quoted literal (which TASK_ID could break out of).
  const ledgerSlice = (await bash(
    `grep ${shq('"task_id":"' + TASK_ID + '"')} docs/leadv2/ledger.jsonl 2>/dev/null | grep -E '"event":"phase_(enter|exit)"' | tail -n 15 | cut -c1-500 || true`
  )).trim()

  const diffStat = startSha ? (await bash(
    `git diff --stat ${startSha} 2>/dev/null | tail -n 6 || true`
  )).trim() : ''

  const negMemLines = (await bash(
    `wc -l < docs/leadv2-negative-memory.yaml 2>/dev/null | tr -d ' ' || printf '0'`
  )).trim() || '0'

  const digest = [
    '--- context.yaml (decisions/off_limits/plan/verification/start_sha) ---', ctxDigest || '(none)',
    '--- scorecard.jsonl (last row) ---', scorecardTail || '(none)',
    '--- review-signature.md ---', reviewSig || '(none)',
    '--- ledger.jsonl (phase_enter/exit for this task) ---', ledgerSlice || '(none)',
    '--- git diff --stat vs start_sha ---', diffStat || '(none / no start_sha)',
    `--- negative-memory.yaml line count: ${negMemLines} (read-only, never modified here) ---`,
  ].join('\n').slice(0, 2000)

  log(`Digest: assembled ${digest.length} chars (cap 2000)`)
  await emitLedger('phase_exit', { phase: 'Digest', digest_chars: digest.length })

  // ── Critique phase — one schema'd agent() call, fallback chain, evidence post-filter ────────
  phase('Critique')
  const MODEL = TASK_CLASS === 'Heavy' ? 'opus' : 'sonnet'
  await emitLedger('phase_enter', { phase: 'Critique', model: MODEL })

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

  await emitLedger('phase_exit', { phase: 'Critique', got_result: raw !== null })

  if (!raw) {
    log('Critique: agent() returned null (unavailable/error) -- fail-open, returning no critique')
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

  // ── Persist phase — optional freeform_insight -> atomic JSONL append (candidate, never active) ──
  phase('Persist')
  await emitLedger('phase_enter', { phase: 'Persist' })

  let freeformRecord = null
  const fi = raw.freeform_insight
  // fix-round-2 H1: mirror the root_drivers evidence filter -- an insight with no (or too-short)
  // trace_evidence is dropped here, exactly like an evidence-free root_driver is dropped above.
  // Previously only `insight` non-empty was checked, letting an ungrounded "lesson" become a
  // durable status:"candidate" record with zero traceable evidence (the "unaudited self-report"
  // risk, design's own target #8, defeated on its own free-text escape hatch).
  const hasInsight = !!(fi && (fi.insight || '').trim().length > 0)
  const hasEvidence = !!(fi && (fi.trace_evidence || '').trim().length >= 3)
  if (fi && hasInsight && !hasEvidence) {
    log('Persist: freeform_insight dropped -- trace_evidence missing/too short (<3 chars), mirrors root_drivers evidence filter')
  }
  if (fi && hasInsight && hasEvidence) {
    const record = {
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
    const appendOut = (await bash(
      `mkdir -p "${DURABLE_ROOT}/docs/leadv2" && python3 -c "
import json, sys, uuid, datetime
rec = json.loads(sys.argv[1])
rec['id'] = str(uuid.uuid4())
rec['ts'] = datetime.datetime.now(datetime.timezone(datetime.timedelta(hours=2))).isoformat(timespec='minutes')
path = sys.argv[2]
with open(path, 'a', encoding='utf-8') as fh:
    fh.write(json.dumps(rec) + chr(10))
print('appended:' + rec['id'])
" ${shq(recordJson)} "${DURABLE_ROOT}/docs/leadv2/freeform-insights.jsonl" 2>/dev/null || true`
    )).trim()

    if (appendOut.startsWith('appended:')) {
      freeformRecord = Object.assign({}, record, { id: appendOut.slice('appended:'.length) })
      log(`Persist: freeform_insight appended id=${freeformRecord.id}`)
    } else {
      log('Persist: freeform-insights.jsonl append failed -- fail-open, dropping freeform_insight')
    }
  }

  await emitLedger('task_close', {
    phase: 'Persist',
    drivers_kept: causalCritique.root_drivers.length,
    drivers_dropped: droppedCount,
    freeform_written: !!freeformRecord,
  })

  return {
    task_id: TASK_ID,
    causal_critique: causalCritique,
    freeform_insight: freeformRecord,
    summary_for_lead: raw.summary_for_lead || '',
  }
} catch (e) {
  // fix-round-2 HIGH fail-open fix: ANY exception anywhere above (bash() throwing, not just
  // exiting non-zero; agent() throwing outside synthAgent's own try/catch; a JS error in the
  // digest/filter logic) lands here instead of propagating out of the workflow.
  log(`leadv2-causal-critique: exception caught, fail-open skip -- ${e && e.message ? e.message : String(e)}`)
  return { task_id: TASK_ID, causal_critique: null, freeform_insight: null, skipped_reason: 'exception' }
}
