// Test harness for leadv2-plan.js CODEMAP-CONTEXT-01 additions (+ fix-round-1).
// Same execution methodology as fixtures/causal-critique-harness.mjs: read the real,
// unmodified workflow .js file verbatim, strip the `export` keyword, wrap in an async IIFE,
// and run it via `new Function(...)` injecting mock agent/bash/phase/log/parallel — the same
// primitive surface the real Workflow runtime provides.
//
// bash() shells out for real (child_process.execSync) against a fixture git repo, so the
// _ARCHIVE_ROOT git rev-parse call, the TASK-CLASS-PERSIST flock+python3 block, AND (as of
// fix-round-1) the deterministic persistCodeMap() flock+python3 block all run for REAL. The
// mocked 'synthesize'/'synthesize-retry' agent labels only write a base context.yaml WITHOUT
// a code_map key — any code_map found in the final on-disk context.yaml therefore proves the
// real, unmocked persistCodeMap() code path did the work (not a harness simulation).
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
  return wrapped(args, agentImpl, bashImpl, phaseImpl, logImpl, parallelImpl)
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

// validateInvalidOnce: when true, the FIRST validate-ctx call returns {valid:false} to force
// the workflow's one-shot retry path (exercises the synthesize-retry + second persistCodeMap()
// call for fix-round-1 #2's "lost on retry" regression test).
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
      // Deliberately does NOT write code_map — proves the real persistCodeMap() JS/bash code
      // path (unmocked) is what puts it on disk, not this mock.
      writeBaseCtx(taskId)
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
