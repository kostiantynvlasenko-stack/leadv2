export const meta = {
  name: 'leadv2-plan',
  description: 'leadv2 Phase 2 Plan as a workflow: parallel architect + critic + Codex-via-agent, synthesize into context.yaml. Retires the Codex Monitor-polling machinery. Model-pinned (opus only Heavy/arch).',
  whenToUse: 'leadv2 Phase 2 for class >= Standard. Lead invokes instead of hand-rolled triad + Monitor. Returns a compact plan summary; full context.yaml written to disk.',
  phases: [
    { title: 'Plan', detail: 'parallel architect + critic + codex-planner' },
    { title: 'Synthesize', detail: 'merge into context.yaml' },
  ],
}
const a = (typeof args === 'string' ? JSON.parse(args) : args) || {}
const TASK_ID = a.taskId || 'adhoc'
const BRIEF = a.taskBrief || ''
const HEAVY = a.heavy === true || a.archKeyword === true
const MISSION_PATH = a.missionPath || `docs/handoff/${TASK_ID}/plan-mission.md`
const CTX = `docs/handoff/${TASK_ID}/context.yaml`
const CODEX_ON = a.codexEnabled !== false

const ARCH_SCHEMA = {
  type: 'object', additionalProperties: false,
  properties: {
    decisions: { type: 'array', items: { type: 'string' } },
    plan_steps: { type: 'array', items: { type: 'string' } },
    off_limits: { type: 'array', items: { type: 'string' } },
    risks: { type: 'array', items: { type: 'string' } },
    summary_for_lead: { type: 'string' },
  }, required: ['decisions', 'plan_steps', 'summary_for_lead'],
}
const CRITIC_SCHEMA = {
  type: 'object', additionalProperties: false,
  properties: {
    concerns: { type: 'array', items: { type: 'object', additionalProperties: false,
      properties: { severity: { type: 'string', enum: ['critical','high','medium','low'] }, concern: { type: 'string' } },
      required: ['severity','concern'] } },
    summary_for_lead: { type: 'string' },
  }, required: ['concerns', 'summary_for_lead'],
}

phase('Plan')
const spawns = [
  () => agent(
    `Architect the plan for task ${TASK_ID}. Brief: ${BRIEF || MISSION_PATH}. Read ${MISSION_PATH} + the repo. ` +
    `Produce decisions[], plan_steps[] (minimal-diff oriented), off_limits[], risks[]. No code, no full-file rewrites.`,
    { label: 'architect', phase: 'Plan', agentType: 'architect', model: HEAVY ? 'opus' : 'sonnet', schema: ARCH_SCHEMA }),
  () => agent(
    `Adversarially critique the proposed approach for task ${TASK_ID}. Brief: ${BRIEF || MISSION_PATH}. ` +
    `Surface concerns: hidden coupling, irreversible ops, unverifiable invariants, missing tests, scope creep. Severity-tag each.`,
    { label: 'critic', phase: 'Plan', agentType: 'critic', model: 'sonnet', schema: CRITIC_SCHEMA }),
]
if (CODEX_ON) {
  spawns.push(() => agent(
    `Run this single blocking call: bash ~/.claude/scripts/leadv2-codex-planner.sh --task-id ${TASK_ID} --mission-file "${MISSION_PATH}" --effort ${HEAVY ? 'xhigh' : 'high'} --wait. ` +
    `The --wait flag blocks until done; no polling needed. When it exits, read findings: bash ~/.claude/scripts/cx-tail.sh <output-file>. ` +
    `Return codex's plan findings as concerns[] (severity-tagged). If codex unavailable (non-zero exit), return empty with summary_for_lead="codex unavailable". Do NOT poll or loop.`,
    { label: 'codex-planner', phase: 'Plan', model: 'haiku', schema: CRITIC_SCHEMA }))
}
const res = (await parallel(spawns)).filter(Boolean)
const archRaw = res.find(r => r && r.decisions)
const architectFailed = !archRaw || (archRaw.decisions.length === 0 && archRaw.plan_steps.length === 0)
const arch = archRaw || { decisions: [], plan_steps: [], off_limits: [], risks: [], summary_for_lead: '' }
const concerns = res.flatMap(r => (r && r.concerns) || [])
const blocking = concerns.filter(c => c.severity === 'critical' || c.severity === 'high')
log(`Plan: ${arch.decisions.length} decisions, ${arch.plan_steps.length} steps, ${concerns.length} concerns (${blocking.length} blocking)`)

if (architectFailed) {
  return {
    task_id: TASK_ID, context_path: CTX,
    decisions_count: 0, steps_count: 0,
    blocking_concerns: blocking.length,
    risk_summary: [],
    needs_founder_decision: true,
    architect_failed: true,
  }
}

phase('Synthesize')
await agent(
  `Write a leadv2 context.yaml to ${CTX} merging this plan. ` +
  `decisions: ${JSON.stringify(arch.decisions)}. steps: ${JSON.stringify(arch.plan_steps)}. ` +
  `off_limits: ${JSON.stringify(arch.off_limits || [])}. risks: ${JSON.stringify(arch.risks || [])}. ` +
  `concerns: ${JSON.stringify(concerns)}. Use the standard leadv2 context.yaml shape (decisions[], off_limits[], plan.steps[], risk summary). ` +
  `Resolve any critic concern into either an off_limit or a plan step. Return "ok".`,
  { label: 'synthesize', phase: 'Synthesize', model: 'sonnet' })

const REQUIRED_FIELDS = ['id', 'mission', 'reads', 'writes', 'acceptance']
const validationResult = await agent(
  `Validate ${CTX}: run python3 -c "import yaml,sys; d=yaml.safe_load(open('${CTX}')); missing=[f for f in ["id","mission","reads","writes","acceptance"] if f not in d]; sys.stdout.write('MISSING:'+','.join(missing) if missing else 'OK')". Return {valid:true} if output is OK, else {valid:false,error:'Missing: <fields>'}.`,
  { label: 'validate-ctx', phase: 'Synthesize', model: 'haiku', schema: { type: 'object', additionalProperties: false, properties: { valid: { type: 'boolean' }, error: { type: 'string' } }, required: ['valid'] } })
let validationError = null
if (validationResult && !validationResult.valid) {
  validationError = validationResult.error || 'context.yaml missing required fields'
  log(`Validation failed: ${validationError} — re-running Synthesize once`)
  await agent(
    `RETRY: context.yaml validation failed with: ${validationError}. Re-write ${CTX} ensuring required fields id, mission, reads, writes, acceptance are present. ` +
    `decisions: ${JSON.stringify(arch.decisions)}. steps: ${JSON.stringify(arch.plan_steps)}. ` +
    `off_limits: ${JSON.stringify(arch.off_limits || [])}. risks: ${JSON.stringify(arch.risks || [])}. ` +
    `concerns: ${JSON.stringify(concerns)}. Return "ok".`,
    { label: 'synthesize-retry', phase: 'Synthesize', model: 'sonnet' })
}

return {
  task_id: TASK_ID, context_path: CTX,
  decisions_count: arch.decisions.length, steps_count: arch.plan_steps.length,
  blocking_concerns: blocking.length,
  risk_summary: (arch.risks || []).slice(0, 3),
  needs_founder_decision: blocking.length > 0,
  architect_failed: undefined,
  validation_error: validationError || undefined,
}
