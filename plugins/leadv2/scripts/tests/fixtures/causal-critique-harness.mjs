// Test harness for leadv2-causal-critique.js — REFLECT-CAUSAL-CRITIQUE-01 (+ fix-round-2).
//
// The real Workflow runtime is a proprietary interpreter (not plain Node ESM import —
// the source file uses top-level `await`/`return` outside a function, which only a
// custom Function-body wrapper or bespoke interpreter permits). To exercise the REAL,
// unmodified engine source end-to-end, this harness:
//   1. reads the workflow .js file verbatim
//   2. strips only the `export` keyword (Function-body context has no module goal)
//   3. wraps the body in an async IIFE and runs it via `new Function(...)`, injecting
//      mock `agent`/`bash`/`phase`/`log`/`parallel`/`args` — the same surface the real
//      runtime provides (confirmed against leadv2-learn.js's use of the same primitives).
// `bash()` in this harness shells out for real (child_process.execSync) against a fixture
// git repo — so the Digest phase's context.yaml/scorecard/review-signature/ledger/git-diff
// reads, AND the shq()-escaping of TASK_ID, are genuinely executed, not mocked.
import { execSync } from 'node:child_process'
import fs from 'node:fs'
import path from 'node:path'

const [, , fixtureDir, workflowPath, scenario] = process.argv

const calls = { agent: 0, bash: 0 }

function runWorkflow(taskId, taskClass, agentImpl) {
  const src = fs.readFileSync(workflowPath, 'utf8')
  const body = src.replace(/^export const meta/, 'const meta')
  const wrapped = new Function(
    'args', 'agent', 'bash', 'phase', 'log', 'parallel',
    `return (async () => {\n${body}\n})();`
  )
  const bashImpl = async (cmd) => {
    calls.bash++
    try {
      return execSync(cmd, { shell: '/bin/bash', cwd: fixtureDir, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] })
    } catch (e) {
      return (e.stdout || '').toString()
    }
  }
  const phaseImpl = () => {}
  const logImpl = (...a) => { if (process.env.HARNESS_VERBOSE) console.error('[wf-log]', ...a) }
  const parallelImpl = (fns) => Promise.all(fns.map((fn) => fn()))
  return wrapped({ task_id: taskId, task_class: taskClass }, agentImpl, bashImpl, phaseImpl, logImpl, parallelImpl)
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
    const agentImpl = async (prompt, opts) => {
      calls.agent++
      if (opts.label === 'causal-critique') return GOOD_CRITIQUE
      return null
    }
    const result = await runWorkflow('FIXTURE-TASK-01', 'Standard', agentImpl)
    console.log(JSON.stringify({ scenario, result, calls }))
  } else if (scenario === 'unavailable') {
    const agentImpl = async () => { calls.agent++; return null }
    const result = await runWorkflow('FIXTURE-TASK-01', 'Standard', agentImpl)
    console.log(JSON.stringify({ scenario, result, calls }))
  } else if (scenario === 'trivial-skip') {
    const agentImpl = async () => { calls.agent++; throw new Error('agent() must NOT be called for Trivial task_class') }
    const result = await runWorkflow('FIXTURE-TASK-01', 'Trivial', agentImpl)
    console.log(JSON.stringify({ scenario, result, calls }))
  } else if (scenario === 'freeform-no-evidence') {
    const agentImpl = async (prompt, opts) => {
      calls.agent++
      if (opts.label === 'causal-critique') return NO_EVIDENCE_CRITIQUE
      return null
    }
    const result = await runWorkflow('FIXTURE-TASK-02', 'Standard', agentImpl)
    const jsonlPath = path.join(fixtureDir, 'docs', 'leadv2', 'freeform-insights.jsonl')
    const jsonlExists = fs.existsSync(jsonlPath)
    const jsonlContainsUngrounded = jsonlExists && fs.readFileSync(jsonlPath, 'utf8').includes('ungrounded plausible-sounding')
    console.log(JSON.stringify({ scenario, result, calls, jsonlExists, jsonlContainsUngrounded }))
  } else if (scenario === 'malicious-taskid') {
    // fix-round-2 C1-sibling re-attack: TASK_ID crafted to break out of shell quoting if
    // interpolated unescaped anywhere in the Digest phase's bash() command strings.
    const markerPath = path.join(fixtureDir, 'PWNED_TASKID_MARKER')
    try { fs.unlinkSync(markerPath) } catch (_) { /* ok if absent */ }
    const maliciousTaskId = `x'; touch ${markerPath}; echo '`
    const agentImpl = async (prompt, opts) => {
      calls.agent++
      if (opts.label === 'causal-critique') return GOOD_CRITIQUE
      return null
    }
    const result = await runWorkflow(maliciousTaskId, 'Standard', agentImpl)
    const markerCreated = fs.existsSync(markerPath)
    console.log(JSON.stringify({ scenario, result, calls, markerCreated }))
  } else {
    throw new Error(`unknown scenario: ${scenario}`)
  }
}

main().catch((e) => { console.error('HARNESS_ERROR', e.stack || e); process.exit(1) })
