export const meta = {
  name: 'leadv2-learn',
  description: 'Learning-aggregation workflow: consume accumulated review/plan signatures + immune patterns, detect recurring failure modes, propose concrete tuning (prompts/routing/skill-promotion). Writes a GOVERNANCE proposal — never auto-applies. Model-pinned.',
  whenToUse: 'Periodically or at Phase 8 Close. Turns per-task signatures into compounding system improvement ("the system gets smarter"). Founder/auto-approve applies proposals.',
  phases: [
    { title: 'Gather', detail: 'aggregate signatures + immune patterns' },
    { title: 'Propose', detail: 'recurring-pattern → concrete tuning proposal' },
  ],
}
const a = (typeof args === 'string' ? JSON.parse(args) : args) || {}
const LABEL = a.label || 'latest'
const OUT = `docs/leadv2/learning-proposals/${LABEL}.md`

const PATTERNS_SCHEMA = {
  type: 'object', additionalProperties: false,
  properties: {
    recurring: { type: 'array', items: { type: 'object', additionalProperties: false,
      properties: { signal: { type: 'string' }, count: { type: 'number' }, where: { type: 'string' } },
      required: ['signal', 'count'] } },
    revise_rate: { type: 'string' },
    summary_for_lead: { type: 'string' },
  }, required: ['recurring', 'summary_for_lead'],
}
const PROPOSAL_SCHEMA = {
  type: 'object', additionalProperties: false,
  properties: {
    proposals: { type: 'array', items: { type: 'object', additionalProperties: false,
      properties: {
        kind: { type: 'string', enum: ['prompt-tweak', 'routing-change', 'skill-promote', 'negative-memory', 'other'] },
        target: { type: 'string' }, change: { type: 'string' }, rationale: { type: 'string' },
      }, required: ['kind', 'target', 'change'] } },
    summary_for_lead: { type: 'string' },
  }, required: ['proposals', 'summary_for_lead'],
}

phase('Gather')
const patterns = await agent(
  `Aggregate the leadv2 learning signals. Steps:\n` +
  `1. Run: bash .claude/scripts/leadv2-signatures-aggregate.sh (if present) and read its output.\n` +
  `2. Read all docs/handoff/*/review-signature.md lines (verdict/blocking/dims).\n` +
  `3. Read docs/leadv2/immune-patterns.yaml (or .claude immune store) if present.\n` +
  `Identify recurring failure signals: which review dimensions recur, REVISE rate, repeated failure_classes/phases. ` +
  `Return them as recurring[] with counts. Be factual — only what the data shows.`,
  { label: 'gather', phase: 'Gather', model: 'haiku', schema: PATTERNS_SCHEMA })
const safePatterns = patterns || { recurring: [], revise_rate: 'n/a', summary_for_lead: 'gather returned null' }

log(`Gather: ${safePatterns.recurring.length} recurring signals, revise_rate=${safePatterns.revise_rate || 'n/a'}`)

phase('Propose')
const proposal = await agent(
  `Given these recurring leadv2 signals, propose CONCRETE, minimal tuning. ` +
  `Recurring: ${JSON.stringify(safePatterns.recurring)}.\n` +
  `For each: a prompt-tweak (which mission/skill), routing-change (routing.yaml), skill-promote candidate, ` +
  `or negative-memory entry. Be specific (name the file/skill). Then WRITE the proposal to ${OUT} as a ` +
  `governance markdown (status: pending — NOT auto-applied; founder or auto-approve decides). Return the proposals[].`,
  { label: 'propose', phase: 'Propose', model: 'sonnet', schema: PROPOSAL_SCHEMA })

return {
  label: LABEL, proposal_path: OUT,
  recurring_signals: safePatterns.recurring.length,
  proposals_count: proposal.proposals.length,
  proposals: proposal.proposals.map(p => ({ kind: p.kind, target: p.target })),
}
