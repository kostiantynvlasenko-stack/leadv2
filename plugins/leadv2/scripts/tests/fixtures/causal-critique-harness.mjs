// Test harness for leadv2-causal-critique.js — REFLECT-CAUSAL-CRITIQUE-01 (+ fix-round-2 +
// WORKFLOW-BASH-FIX-01).
//
// The real Workflow runtime is a proprietary interpreter (not plain Node ESM import —
// the source file uses top-level `await`/`return` outside a function, which only a
// custom Function-body wrapper or bespoke interpreter permits). To exercise the REAL,
// unmodified engine source end-to-end, this harness:
//   1. reads the workflow .js file verbatim
//   2. strips only the `export` keyword (Function-body context has no module goal)
//   3. wraps the body in an async IIFE and runs it via `new Function(...)`, injecting mock
//      `agent`/`phase`/`log`/`parallel`/`pipeline`/`budget`/`args` — the REAL runtime surface
//      (agent()/parallel()/pipeline()/log()/phase()/args/budget — NO bash() global).
//
// WORKFLOW-BASH-FIX-01: this harness previously mocked a fictional `bash`/`bashImpl` global
// that does not exist at runtime — the exact blind spot that let 9 real `bash()` call-sites in
// leadv2-causal-critique.js ship broken (undefined at runtime). It now mocks only agent() (+
// pipeline/budget as harmless no-ops), matching learn-freeform-flag-harness.mjs's realignment.
//
// The workflow now asks its 'gather-digest' and 'persist' agent() calls to run shell commands
// (embedded verbatim in the prompt between <<<CMD:name>>> ... <<<END>>> markers) via a Bash
// tool. To keep this a GENUINE end-to-end test (not a hollow mock that would let the
// malicious-taskid injection test trivially "pass" without proving anything), the mock
// agentImpl for these two labels extracts each command from the prompt and shells it out for
// real via execSync against the fixture git repo — so the Digest phase's context.yaml/
// scorecard/review-signature/ledger/git-diff reads, the Persist phase's freeform-insights.jsonl
// append, AND the shq()-escaping of TASK_ID, are all genuinely executed, not mocked.
import { execSync } from 'node:child_process'
import fs from 'node:fs'
import path from 'node:path'

const [, , fixtureDir, workflowPath, scenario] = process.argv

const calls = { agent: 0, realExec: 0 }

function runCmd(cmd) {
  calls.realExec++
  try {
    return execSync(cmd, { shell: '/bin/bash', cwd: fixtureDir, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] })
  } catch (e) {
    return (e.stdout || '').toString()
  }
}

function extractCmd(prompt, name) {
  const re = new RegExp(`<<<CMD:${name}[^>]*>>>\\n([\\s\\S]*?)\\n<<<END>>>`)
  const m = prompt.match(re)
  return m ? m[1] : ''
}

// Genuinely executes the 'gather-digest' agent() call's embedded commands, mirroring exactly
// what a real Bash-tool-using agent would do with this prompt (including the conditional
// start_sha -> diff_stat substitution, restricted to the same hex-only charset the workflow's
// own regex enforces).
function runGatherDigest(prompt) {
  const durable_root = runCmd(extractCmd(prompt, 'durable_root')).trim()
  const ctx_digest = runCmd(extractCmd(prompt, 'ctx_digest')).trim()
  const scorecard_tail = runCmd(extractCmd(prompt, 'scorecard_tail')).trim()
  const review_sig = runCmd(extractCmd(prompt, 'review_sig')).trim()
  const ledger_slice = runCmd(extractCmd(prompt, 'ledger_slice')).trim()
  const neg_mem_lines = runCmd(extractCmd(prompt, 'neg_mem_lines')).trim()
  let diff_stat = ''
  const shaMatch = ctx_digest.match(/start_sha:\s*['"]?([0-9a-f]{7,40})['"]?/)
  if (shaMatch) {
    const template = extractCmd(prompt, 'diff_stat')
    diff_stat = runCmd(template.replace('<START_SHA>', shaMatch[1])).trim()
  }
  return { durable_root, ctx_digest, scorecard_tail, review_sig, ledger_slice, diff_stat, neg_mem_lines }
}

// Genuinely executes the 'persist' agent() call's freeform-insight append command (when
// present) — proves the jsonl append + shq()-escaped record JSON round-trip for real. Ledger
// events are not asserted on by any test today, so they are counted but not actually shelled
// out (kept minimal/honest per the harness's own stated scope).
function runPersist(prompt) {
  const appendMatch = prompt.match(/<<<CMD:append>>>\n([\s\S]*?)\n<<<END>>>/)
  let append_out = ''
  if (appendMatch) {
    append_out = runCmd(appendMatch[1]).trim()
  }
  return { append_out, ledger_flushed: 0 }
}

function makeAgentImpl(critiqueHandler) {
  return async (prompt, opts) => {
    calls.agent++
    if (opts.label === 'gather-digest') return runGatherDigest(prompt)
    if (opts.label === 'persist') return runPersist(prompt)
    if (opts.label === 'causal-critique') return critiqueHandler(prompt, opts)
    return null
  }
}

function runWorkflow(taskId, taskClass, agentImpl) {
  const src = fs.readFileSync(workflowPath, 'utf8')
  const body = src.replace(/^export const meta/, 'const meta')
  const wrapped = new Function(
    'args', 'agent', 'phase', 'log', 'parallel', 'pipeline', 'budget',
    `return (async () => {\n${body}\n})();`
  )
  const phaseImpl = () => {}
  const logImpl = (...a) => { if (process.env.HARNESS_VERBOSE) console.error('[wf-log]', ...a) }
  const parallelImpl = (fns) => Promise.all(fns.map((fn) => fn()))
  const pipelineImpl = (fns) => Promise.all((fns || []).map((fn) => (typeof fn === 'function' ? fn() : fn)))
  const budgetImpl = {}
  return wrapped({ task_id: taskId, task_class: taskClass }, agentImpl, phaseImpl, logImpl, parallelImpl, pipelineImpl, budgetImpl)
}

const GOOD_CRITIQUE = {
  outcome_summary: 'Fixture run hit a partial-index upsert failure caught late.',
  root_drivers: [
    {
      driver: 'Partial unique index rejected batch upsert',
      locus: { phase: 'build', llm_step: 'insert', prompt_or_input: 'batch-upsert' },
      evidence: 'ledger.jsonl phase_exit build error=PGRST102',
      counterfactual: 'use rpc() fallback instead of upsert() on the partial index',
      confidence: 0.9,
    },
    {
      // deliberately EMPTY evidence -> MUST be dropped by the anti-hallucination post-filter
      driver: 'Reviewer flagged tone drift',
      locus: { phase: 'review' },
      evidence: '',
      counterfactual: 'n/a',
      confidence: 0.2,
    },
  ],
  cheap_win: 'switch snapshots upsert to rpc()',
  freeform_insight: {
    insight: "PostgREST upsert on a partial unique index needs rpc(), not upsert() -- doesn't fit the 6-enum signature.",
    trace_evidence: 'ledger.jsonl phase_exit build error=PGRST102',
    recall_tags: ['postgrest', 'partial-index', 'upsert'],
  },
  summary_for_lead: 'One evidenced driver kept, one dropped for missing evidence; freeform escape emitted.',
}

// fix-round-2 H1 regression fixture: real insight text but NO trace_evidence -> must be dropped,
// mirroring the root_drivers evidence filter.
const NO_EVIDENCE_CRITIQUE = {
  outcome_summary: 'Clean run, no root causes.',
  root_drivers: [],
  cheap_win: null,
  freeform_insight: {
    insight: 'An ungrounded plausible-sounding lesson with no pointer back into the digest.',
    trace_evidence: '',
    recall_tags: ['ungrounded'],
  },
  summary_for_lead: 'freeform_insight present but evidence-free -- must be dropped, not persisted.',
}

async function main() {
  if (scenario === 'good') {
    let critiquePrompt = ''
    const agentImpl = makeAgentImpl((prompt) => { critiquePrompt = prompt; return GOOD_CRITIQUE })
    const result = await runWorkflow('FIXTURE-TASK-01', 'Standard', agentImpl)
    // WORKFLOW-BASH-FIX-01 replacement for the old "BASH_CALLS>3" check: proves the Digest
    // phase's gather-digest agent() call genuinely read real fixture file content (not canned
    // values) by checking the downstream causal-critique prompt for fixture-specific substrings
    // from ledger.jsonl and context.yaml.
    const digestReflectsFixture = critiquePrompt.includes('PGRST102') && critiquePrompt.includes('rpc() for partial-index upserts')
    console.log(JSON.stringify({ scenario, result, calls, digestReflectsFixture }))
  } else if (scenario === 'unavailable') {
    const agentImpl = async () => { calls.agent++; return null }
    const result = await runWorkflow('FIXTURE-TASK-01', 'Standard', agentImpl)
    console.log(JSON.stringify({ scenario, result, calls }))
  } else if (scenario === 'trivial-skip') {
    const agentImpl = async () => { calls.agent++; throw new Error('agent() must NOT be called for Trivial task_class') }
    const result = await runWorkflow('FIXTURE-TASK-01', 'Trivial', agentImpl)
    console.log(JSON.stringify({ scenario, result, calls }))
  } else if (scenario === 'freeform-no-evidence') {
    const agentImpl = makeAgentImpl(() => NO_EVIDENCE_CRITIQUE)
    const result = await runWorkflow('FIXTURE-TASK-02', 'Standard', agentImpl)
    const jsonlPath = path.join(fixtureDir, 'docs', 'leadv2', 'freeform-insights.jsonl')
    const jsonlExists = fs.existsSync(jsonlPath)
    const jsonlContainsUngrounded = jsonlExists && fs.readFileSync(jsonlPath, 'utf8').includes('ungrounded plausible-sounding')
    console.log(JSON.stringify({ scenario, result, calls, jsonlExists, jsonlContainsUngrounded }))
  } else if (scenario === 'malicious-taskid') {
    // fix-round-2 C1-sibling re-attack: TASK_ID crafted to break out of shell quoting if
    // interpolated unescaped anywhere in the Digest phase's commands. Uses the REAL gather-digest
    // executor (runGatherDigest) so this genuinely proves the shq()-escaping survives being
    // routed through an agent() call instead of a direct bash() call.
    const markerPath = path.join(fixtureDir, 'PWNED_TASKID_MARKER')
    try { fs.unlinkSync(markerPath) } catch (_) { /* ok if absent */ }
    const maliciousTaskId = `x'; touch ${markerPath}; echo '`
    const agentImpl = makeAgentImpl(() => GOOD_CRITIQUE)
    const result = await runWorkflow(maliciousTaskId, 'Standard', agentImpl)
    const markerCreated = fs.existsSync(markerPath)
    console.log(JSON.stringify({ scenario, result, calls, markerCreated }))
  } else {
    throw new Error(`unknown scenario: ${scenario}`)
  }
}

main().catch((e) => { console.error('HARNESS_ERROR', e.stack || e); process.exit(1) })
