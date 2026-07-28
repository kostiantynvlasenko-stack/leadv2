#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKFLOW_FILE="${SCRIPT_DIR}/../../workflows/leadv2-review.js"

node --input-type=module - "$WORKFLOW_FILE" <<'NODE'
import fs from 'node:fs'

const workflowPath = process.argv[2]
const source = fs.readFileSync(workflowPath, 'utf8')
  .replace(/^export const meta =/m, 'const meta =')
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor
const runWorkflow = new AsyncFunction(
  'args', 'agent', 'parallel', 'pipeline', 'log', 'phase', 'budget', 'process',
  source,
)

function assert(condition, message) {
  if (!condition) throw new Error(`ASSERTION FAILED: ${message}`)
}

async function runScenario(name, args, codexUnavailable = false) {
  const calls = []
  const logs = []
  const agent = async (prompt, opts = {}) => {
    calls.push({ label: opts.label || '(none)', prompt })
    if (opts.label === 'codex-adversarial') {
      return codexUnavailable
        ? { findings: [], summary_for_lead: 'codex unavailable: simulated quota exhausted' }
        : { findings: [], summary_for_lead: 'codex normal: full adversarial review completed' }
    }
    if (opts.label === 'quality-scorer') {
      return {
        diff_coherence: 4,
        test_coverage: 3,
        security_pass: 3,
        novelty_bonus: 0,
        quality_score: 10,
        diff_summary: 'routing harness diff',
      }
    }
    if (opts.schema && opts.schema.properties && opts.schema.properties.findings) {
      return { findings: [], summary_for_lead: `${opts.label}: completed` }
    }
    return 'ok'
  }
  const parallel = async (jobs) => Promise.all(jobs.map(job => job()))
  const result = await runWorkflow(
    args,
    agent,
    parallel,
    async () => null,
    message => logs.push(message),
    () => {},
    {},
    { env: { LEADV2_REVIEW_FAMILY_GATE: '1' } },
  )
  return { name, calls, logs, result }
}

const normal = await runScenario(
  'codex-normal',
  { taskId: 'routing-normal', base: 'main', diffPath: '/tmp/routing.diff', codexEnabled: true },
)
const normalCritic = normal.calls.find(call => call.label === 'critic-structural-cross-check')
assert(normal.calls.some(call => call.label === 'codex-adversarial'), 'normal round must run Codex')
assert(normalCritic, 'normal round must run structural critic cross-check')
assert(normalCritic.prompt.includes('do NOT repeat a full line-by-line review'), 'critic must be explicitly narrow')
assert(normalCritic.prompt.includes('cross-module API/data-contract drift'), 'critic must cover structural blind spots')
assert(!normal.calls.some(call => call.label === 'critic-full-fallback'), 'normal round must not run full critic')

const unavailable = await runScenario(
  'codex-forced-unavailable',
  { taskId: 'routing-unavailable', base: 'main', diffPath: '/tmp/routing.diff', codexEnabled: false },
)
const fallbackCritic = unavailable.calls.find(call => call.label === 'critic-full-fallback')
assert(!unavailable.calls.some(call => call.label === 'codex-adversarial'), 'preflight-unavailable round must not dispatch Codex')
assert(fallbackCritic, 'preflight-unavailable round must run full critic fallback')
assert(fallbackCritic.prompt.includes('FULL adversarial code review'), 'fallback critic must have full breadth')
assert(fallbackCritic.prompt.includes('correctness bugs, type/data/RLS gaps, N+1'), 'fallback critic must inherit general review coverage')

const midrun = await runScenario(
  'codex-midrun-unavailable',
  { taskId: 'routing-midrun', base: 'main', diffPath: '/tmp/routing.diff', codexEnabled: true },
  true,
)
assert(midrun.calls.some(call => call.label === 'critic-structural-cross-check'), 'mid-run failure starts with narrow cross-check')
assert(midrun.calls.some(call => call.label === 'critic-full-fallback'), 'mid-run failure must promote critic to full review')
assert(midrun.logs.some(line => line.includes('Codex unavailable after dispatch; critic=full-fallback')), 'mid-run fallback must be logged')

for (const scenario of [normal, unavailable, midrun]) {
  const reviewCalls = scenario.calls
    .filter(call => call.label.startsWith('codex-') || call.label.startsWith('critic-'))
    .map(call => call.label)
    .join(', ')
  console.log(`${scenario.name}: ${reviewCalls}`)
  for (const line of scenario.logs.filter(line => line.startsWith('Review routing:'))) {
    console.log(`  log: ${line}`)
  }
}
console.log('PASS: review routing gives Codex the general review, critic a structural cross-check, and critic full fallback on unavailability')
NODE
