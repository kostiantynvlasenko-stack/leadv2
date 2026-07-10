// Test harness for leadv2-learn.js -- REFLECT-CAUSAL-CRITIQUE-01 fix-round-2 (H2).
//
// Verifies the flag-gated freeform-recall Gather leg does NOT change the workflow's return
// object shape when LEADV2_CAUSAL_CRITIQUE is off (H2 fix: `freeform_recalled` key must be
// OMITTED entirely, not present-as-[]). Same Function-wrap execution methodology as
// causal-critique-harness.mjs -- runs the REAL, unmodified leadv2-learn.js source.
//
// WORKFLOW-BASH-FIX-01: the real Workflow runtime provides ONLY agent()/parallel()/pipeline()/
// log()/phase()/args/budget -- there is NO bash() global. This harness previously mocked a
// fictional `bashImpl`, which is exactly the blind spot that let 4 real `bash()` call-sites in
// leadv2-learn.js ship broken (undefined at runtime). It now mocks only agent() (+ pipeline/
// budget as harmless no-ops) to match the real runtime contract -- every shell command the
// workflow needs now runs *inside* an agent() call, never via a JS-level bash() global.
//
// Mock surface: every agent() label the workflow can reach on this minimal path is stubbed
// with a schema-shaped response. SYNTH_THRESHOLD is set to 1 and 'gather-signals' returns one
// recurring signal at count=1 so the workflow proceeds past the early-exit into Propose ->
// Shadow-Emit -> the final return statement (the exact line H2 fixed), with proposals=[] so
// the episodic-write / shared-mem-update / shadow-emit-batch side branches (which need TASK_ID +
// non-empty proposals) are inert no-ops -- keeping the mock surface minimal and honest.
import fs from 'node:fs'

const [, , fixtureDir, workflowPath, flagState] = process.argv

process.env.LEADV2_SKILL_SYNTH_THRESHOLD = '1'
process.env.LEADV2_CAUSAL_CRITIQUE = flagState === 'on' ? '1' : '0'

function runWorkflow(args) {
  const src = fs.readFileSync(workflowPath, 'utf8')
  const body = src.replace(/^export const meta/, 'const meta')
  const wrapped = new Function(
    'args', 'agent', 'phase', 'log', 'parallel', 'pipeline', 'budget',
    `return (async () => {\n${body}\n})();`
  )
  const agentImpl = async (prompt, opts) => {
    switch (opts.label) {
      case 'gather-init':
        return { ts: '2026-01-01T00:00:00Z', durable_root: fixtureDir }
      case 'gather-signals':
        return { recurring: [{ signal: 'test-signal', count: 1, where: 'fixture', class_key: 'test:key:role:mode' }], revise_rate: '0%', summary_for_lead: 'one test signal' }
      case 'gather-rejected':
        return { rejected_keys: [], rejected_count: 0, summary_for_lead: 'none rejected' }
      case 'gather-exemplars':
        return { exemplars: [], summary_for_lead: 'no exemplars' }
      case 'gather-freeform-recall':
        return { freeform_recalled: [], summary_for_lead: 'no freeform candidates' }
      case 'propose':
        return { proposals: [], summary_for_lead: 'no proposals for this minimal fixture' }
      case 'ledger-flush':
        return 'flushed:mock'
      default:
        return null
    }
  }
  const phaseImpl = () => {}
  const logImpl = (...a) => { if (process.env.HARNESS_VERBOSE) console.error('[wf-log]', ...a) }
  const parallelImpl = (fns) => Promise.all(fns.map((fn) => fn()))
  const pipelineImpl = (fns) => Promise.all((fns || []).map((fn) => (typeof fn === 'function' ? fn() : fn)))
  const budgetImpl = {}
  return wrapped(args, agentImpl, phaseImpl, logImpl, parallelImpl, pipelineImpl, budgetImpl)
}

async function main() {
  const result = await runWorkflow({ label: 'fixture-run', task_class: 'general', ts: '2026-01-01T00:00:00Z' })
  console.log(JSON.stringify({ flagState, result, hasKey: Object.prototype.hasOwnProperty.call(result, 'freeform_recalled') }))
}

main().catch((e) => { console.error('HARNESS_ERROR', e.stack || e); process.exit(1) })
