// Test harness for leadv2-plan.js CODEMAP-CONTEXT-01 additions (+ fix-round-1) and
// WORKFLOW-BASH-FIX-01 (bash-call migration).
// Same execution methodology as fixtures/causal-critique-harness.mjs: read the real,
// unmodified workflow .js file verbatim, strip the `export` keyword, wrap in an async IIFE,
// and run it via `new Function(...)` injecting mock agent/phase/log/parallel/pipeline/budget —
// the same primitive surface the real Workflow runtime provides.
//
// WORKFLOW-BASH-FIX-01: the real runtime has NO bash() global. This harness previously
// injected a real execSync-backed `bash` and asserted it was "the same surface the real
// runtime provides" — that assertion was false, and is exactly the blind spot that let 4 real
// `bash()` call-sites in leadv2-plan.js ship broken (undefined at runtime). The harness now
// mocks only agent() (+ pipeline/budget as harmless no-ops) to match the real runtime
// contract — every shell command the CURRENT workflow needs now runs *inside* an agent() call
// via the agent's own Bash tool, never via a JS-level bash() global. calls.bash is asserted to
// stay 0 for every scenario run against the current workflow file (see the test script) — this
// is the actual regression guard proving the migration removed all real bash() call-sites.
//
// Note: this harness signature is NOT compatible with the pre-WORKFLOW-BASH-FIX-01 source
// (which calls a bare `bash(...)` that is undefined here by design) — the old
// "PRE-DIFF GOLDEN" byte-identical comparison against `git show HEAD:...` is retired for this
// reason (see test-leadv2-codemap.sh); running old source through this harness is EXPECTED to
// throw, not silently pass.
// The workflow source itself never references a `bash` identifier (confirmed: zero real
// `await bash(...)` call-sites post-migration). execSync below is used ONLY inside this
// harness's synthesize/synthesize-retry mock to simulate what a REAL subagent would do when
// its prompt says "run this exact command via your Bash tool" — i.e. it is a harness-side
// stand-in for the agent's own Bash tool, not a global injected into the workflow's scope.
import { execSync } from 'node:child_process'
import fs from 'node:fs'
import path from 'node:path'

const [, , fixtureDir, workflowPath, scenario] = process.argv

const calls = { agent: 0, bash: 0 }
const prompts = {}

function runWorkflow(args, agentImpl) {
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
  return wrapped(args, agentImpl, phaseImpl, logImpl, parallelImpl, pipelineImpl, budgetImpl)
}

function ctxPathFor(taskId) {
  return path.join(fixtureDir, 'docs', 'handoff', taskId, 'context.yaml')
}

function writeBaseCtx(taskId) {
  const ctxPath = ctxPathFor(taskId)
  fs.mkdirSync(path.dirname(ctxPath), { recursive: true })
  const lines = [
    `id: ${taskId}`, 'mission: fixture', 'reads: []', 'writes: []', 'acceptance: []',
    'decisions:', '  - "D1: fixture decision"', 'off_limits: []',
    'plan:', '  steps:', '    - id: 1', '      mission: step one', '      agent_hint: developer',
  ]
  fs.writeFileSync(ctxPath, lines.join('\n') + '\n')
}

// WORKFLOW-BASH-FIX-01: the source no longer calls persistCodeMap()/bash() directly — the
// deterministic persist script (task_class + optional code_map) is now folded as VERBATIM
// Bash-tool instructions inside the SAME 'synthesize'/'synthesize-retry' agent prompt. To
// genuinely exercise that fold-in (not just assert the prompt CONTAINS the script text), this
// harness extracts the embedded script from the prompt and actually runs it via execSync —
// exactly what a real subagent would do when told "run this exact command via your Bash tool".
function extractPersistScript(prompt) {
  const marker = 'run it verbatim):\n'
  const idx = prompt.indexOf(marker)
  if (idx === -1) return null
  let rest = prompt.slice(idx + marker.length)
  const cuts = ['\n\nALSO append', ' Return "ok"']
  let cutAt = rest.length
  for (const c of cuts) {
    const i = rest.indexOf(c)
    if (i !== -1 && i < cutAt) cutAt = i
  }
  return rest.slice(0, cutAt)
}

// validateInvalidOnce: when true, the FIRST validate-ctx call returns {valid:false} to force
// the workflow's one-shot retry path (exercises the synthesize-retry + second persist-script
// run for fix-round-1 #2's "lost on retry" regression test).
function makeAgentImpl(taskId, { validateInvalidOnce = false } = {}) {
  let validateCalls = 0
  return async (prompt, opts) => {
    calls.agent++
    prompts[opts.label] = prompt
    if (opts.label === 'capability-classifier') {
      return { recommended_roles: ['architect'], task_class: 'general', rationale: 'fixture' }
    }
    if (opts.label === 'shared-mem-read') return 'EMPTY'
    if (opts.label === 'archive-read') return '[]'
    if (opts.label === 'architect') {
      return { decisions: ['D1: fixture decision'], plan_steps: ['step one'], off_limits: [], risks: [], summary_for_lead: 'fixture' }
    }
    if (opts.label === 'critic') return null
    if (opts.label === 'codex-planner') return { concerns: [], summary_for_lead: 'codex unavailable' }
    if (opts.label === 'synthesize' || opts.label === 'synthesize-retry') {
      // Deliberately does NOT itself write code_map/task_class — proves the embedded,
      // agent-executed persist script (extracted + run below via execSync, simulating the
      // agent's own Bash tool) is what puts it on disk, not this mock's writeBaseCtx.
      writeBaseCtx(taskId)
      const script = extractPersistScript(prompt)
      if (script) {
        try {
          execSync(script, { shell: '/bin/bash', cwd: fixtureDir, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] })
        } catch (e) { /* best-effort, same fail-open contract as the real agent call */ }
      }
      return 'ok'
    }
    if (opts.label === 'validate-ctx') {
      validateCalls++
      if (validateInvalidOnce && validateCalls === 1) {
        return { valid: false, error: 'Missing: code_map' }
      }
      return { valid: true }
    }
    return null
  }
}

function readCtx(taskId) {
  const p = ctxPathFor(taskId)
  return fs.existsSync(p) ? fs.readFileSync(p, 'utf8') : null
}

async function main() {
  const TASK_ID = 'FIXTURE-TASK-CM'
  const baseArgs = { taskId: TASK_ID, taskBrief: 'fixture task', heavy: false, codexEnabled: false }

  if (scenario === 'flag-off-absent') {
    const result = await runWorkflow({ ...baseArgs }, makeAgentImpl(TASK_ID))
    console.log(JSON.stringify({ scenario, result, calls, prompts, ctx: readCtx(TASK_ID) }))
  } else if (scenario === 'flag-off-explicit') {
    const result = await runWorkflow({ ...baseArgs, codemapEnabled: false, codeMap: 'should never appear' }, makeAgentImpl(TASK_ID))
    console.log(JSON.stringify({ scenario, result, calls, prompts, ctx: readCtx(TASK_ID) }))
  } else if (scenario === 'flag-on-mcp-empty') {
    const result = await runWorkflow({ ...baseArgs, codemapEnabled: true }, makeAgentImpl(TASK_ID))
    console.log(JSON.stringify({ scenario, result, calls, prompts, ctx: readCtx(TASK_ID) }))
  } else if (scenario === 'flag-on-normal') {
    const codeMap = 'services: platform,agent\nkey_modules: platform/pipeline.py -> agent/runner.py\nedges: pipeline->runner'
    const result = await runWorkflow({ ...baseArgs, codemapEnabled: true, codeMap }, makeAgentImpl(TASK_ID))
    console.log(JSON.stringify({ scenario, result, calls, prompts, ctx: readCtx(TASK_ID), inputCodeMap: codeMap }))
  } else if (scenario === 'flag-on-oversized') {
    const codeMap = 'X'.repeat(5000)
    const result = await runWorkflow({ ...baseArgs, codemapEnabled: true, codeMap }, makeAgentImpl(TASK_ID))
    console.log(JSON.stringify({ scenario, result, calls, prompts, ctx: readCtx(TASK_ID) }))
  } else if (scenario === 'flag-on-retry') {
    // Forces the validate-ctx -> invalid -> synthesize-retry path once; asserts code_map
    // survives the retry (fix-round-1 #2 regression test).
    const codeMap = 'services: platform,agent\nedges: pipeline->runner'
    const result = await runWorkflow(
      { ...baseArgs, codemapEnabled: true, codeMap },
      makeAgentImpl(TASK_ID, { validateInvalidOnce: true })
    )
    console.log(JSON.stringify({ scenario, result, calls, prompts, ctx: readCtx(TASK_ID), inputCodeMap: codeMap }))
  } else if (scenario === 'golden-baseline') {
    // Runs whatever workflowPath was passed (the harness caller may point this at a pristine
    // pre-CODEMAP-CONTEXT-01 snapshot via `git show HEAD:...`) with NO codemap args at all —
    // used by the test script to diff byte-for-byte against a pinned pre-diff golden.
    const result = await runWorkflow({ ...baseArgs }, makeAgentImpl(TASK_ID))
    console.log(JSON.stringify({ scenario, result, calls, prompts, ctx: readCtx(TASK_ID) }))
  } else {
    throw new Error(`unknown scenario: ${scenario}`)
  }
}

main().catch((e) => { console.error('HARNESS_ERROR', e.stack || e); process.exit(1) })
