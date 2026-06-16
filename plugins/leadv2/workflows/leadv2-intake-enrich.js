export const meta = {
  name: 'leadv2-intake-enrich',
  description: 'leadv2 Phase 0 intake enrichment: reads shared-memory.yaml + solutions-archive.yaml, returns a context envelope (top-1 matching exemplar + prior solutions) for injection into plan-mission.md brief. Model-pinned (haiku reads, no synth needed).',
  whenToUse: 'Lead calls at Phase 0 Intake before spawning leadv2-plan. Enriches the task brief with scored exemplars from prior runs. Returns enriched_brief for direct inclusion in plan-mission.md.',
  phases: [
    { title: 'Enrich', detail: 'parallel: shared-memory read (haiku) + solutions-archive top-K (haiku)' },
  ],
}
let a
if (typeof args === 'string') { try { a = JSON.parse(args) } catch { a = { problem: args } } }
else { a = args }
a = a || {}
const TASK_ID = a.taskId || 'adhoc'
const BRIEF = a.taskBrief || ''
const TASK_CLASS = a.taskClass || 'general'

// [F7] Structured, scored exemplar injection at Intake (§3 of design: extract into Workflow)
// Lead reads shared-memory.yaml (< 200 lines) via this workflow; no inline read in lead chat.
// Token budget: context envelope is capped at 1500 tokens total before injection into plan-mission.md.
const ENVELOPE_CAP = 1400  // chars (rough ~350 tokens at 4 chars/token)

const EXEMPLAR_SCHEMA = {
  type: 'object', additionalProperties: false,
  properties: {
    top_exemplar: { type: 'string' },       // best matching exemplar summary
    task_class_match: { type: 'string' },   // matched task_class from shared-memory
    score: { type: 'number' },
    found: { type: 'boolean' },
  }, required: ['found'],
}
const ARCHIVE_SCHEMA = {
  type: 'object', additionalProperties: false,
  properties: {
    exemplars: { type: 'array', items: {
      type: 'object', additionalProperties: false,
      properties: { task_id: { type: 'string' }, score: { type: 'number' }, diff_summary: { type: 'string' } },
      required: ['task_id', 'score'],
    } },
    found: { type: 'boolean' },
  }, required: ['found'],
}

phase('Enrich')
const [memResult, archResult] = await Promise.all([
  agent(
    `Read docs/leadv2/shared-memory.yaml. It is a YAML file with a list of entries: ` +
    `[{task_id, task_class, top_exemplar_summary, score}]. ` +
    `Find the entry whose task_class best matches "${TASK_CLASS}" (exact match preferred, then partial). ` +
    `If the file does not exist or has no matching entry, return {found: false}. ` +
    `Otherwise return {found: true, top_exemplar: <top_exemplar_summary>, task_class_match: <matched task_class>, score: <score>}.`,
    { label: 'shared-mem-exemplar', phase: 'Enrich', model: 'haiku', schema: EXEMPLAR_SCHEMA }),
  agent(
    `Read docs/leadv2/solutions-archive.yaml. It is a YAML list: [{task_id, task_class, score, diff_summary, ts}]. ` +
    `Filter entries where task_class == "${TASK_CLASS}". Sort by score descending. Return top-3. ` +
    `If the file does not exist or has no matches, return {found: false, exemplars: []}. ` +
    `Otherwise return {found: true, exemplars: [{task_id, score, diff_summary}]}.`,
    { label: 'archive-top-k', phase: 'Enrich', model: 'haiku', schema: ARCHIVE_SCHEMA }),
])

// Build context envelope — capped at ENVELOPE_CAP chars
let envelope = ''
if (memResult && memResult.found && memResult.top_exemplar) {
  envelope += `## Prior exemplar (task_class=${memResult.task_class_match}, score=${memResult.score})\n${memResult.top_exemplar}\n`
}
if (archResult && archResult.found && archResult.exemplars && archResult.exemplars.length > 0) {
  envelope += `## Top solutions from archive (task_class=${TASK_CLASS})\n`
  for (const ex of archResult.exemplars.slice(0, 3)) {
    envelope += `- [${ex.task_id}] score=${ex.score}: ${ex.diff_summary || '(no summary)'}\n`
  }
}

const truncatedEnvelope = envelope.slice(0, ENVELOPE_CAP)
const enriched = truncatedEnvelope.length > 0
const enrichedBrief = enriched
  ? `${BRIEF}\n\n${truncatedEnvelope}`
  : BRIEF

log(`Enrich: mem_found=${memResult ? memResult.found : false} archive_found=${archResult ? archResult.found : false} exemplars=${archResult && archResult.exemplars ? archResult.exemplars.length : 0} envelope_chars=${truncatedEnvelope.length}`)

return {
  task_id: TASK_ID,
  task_class: TASK_CLASS,
  enriched,
  exemplar_found: memResult ? memResult.found : false,
  archive_exemplars: archResult && archResult.exemplars ? archResult.exemplars.length : 0,
  enriched_brief: enrichedBrief,   // pass as taskBrief to leadv2-plan
  envelope_chars: truncatedEnvelope.length,
}
