export const meta = {
  name: 'leadv2-diagnose',
  description: 'Bug root-cause workflow: parallel Trace phase (log-trace + code-trace + db-trace), then Reduce to a single root_cause verdict. Model-pinned (haiku for log reading, sonnet for code/db/reduce).',
  whenToUse: 'Use when a bug needs systematic root-cause analysis. Lead invokes with taskId, bugBrief, optional logsHint and dbHint. Returns root_cause, confidence, evidence_files, fix_hint, alternates.',
  phases: [
    { title: 'Trace', detail: 'parallel: log-trace (haiku) + code-trace (sonnet) + db-trace (sonnet)' },
    { title: 'Reduce', detail: 'sonnet merges hypotheses into single root_cause verdict' },
  ],
}
const a = (typeof args === 'string' ? JSON.parse(args) : args) || {}
const TASK_ID = a.taskId || 'adhoc'
const BUG_BRIEF = a.bugBrief || ''
const LOGS_HINT = a.logsHint || 'journalctl -u persona-engine --since "1 hour ago" | tail -200'
const DB_HINT = a.dbHint || 'check recent rows in actions, health_metrics, strategy_proposals'

const HYPOTHESIS_SCHEMA = {
  type: 'object', additionalProperties: false,
  properties: {
    hypotheses: { type: 'array', items: {
      type: 'object', additionalProperties: false,
      properties: {
        cause: { type: 'string' },
        confidence: { type: 'string', enum: ['high', 'medium', 'low'] },
        evidence: { type: 'string' },
      }, required: ['cause', 'confidence', 'evidence'],
    } },
    summary_for_lead: { type: 'string' },
  }, required: ['hypotheses', 'summary_for_lead'],
}
const ROOT_CAUSE_SCHEMA = {
  type: 'object', additionalProperties: false,
  properties: {
    root_cause: { type: 'string' },
    confidence: { type: 'string', enum: ['high', 'medium', 'low'] },
    evidence_files: { type: 'array', items: { type: 'string' } },
    fix_hint: { type: 'string' },
    alternates: { type: 'array', items: { type: 'string' } },
  }, required: ['root_cause', 'confidence', 'fix_hint'],
}

phase('Trace')
const tracers = [
  () => agent(
    `Log-trace for bug: ${BUG_BRIEF}. Task: ${TASK_ID}.\n` +
    `Run: ${LOGS_HINT}\n` +
    `Look for ERROR/CRITICAL/Traceback/exception lines near the symptom. Extract timestamps and service names. ` +
    `Return up to 5 hypotheses with cause, confidence, and the log evidence snippet.`,
    { label: 'log-trace', phase: 'Trace', model: 'haiku', schema: HYPOTHESIS_SCHEMA }),
  () => agent(
    `Code-trace for bug: ${BUG_BRIEF}. Task: ${TASK_ID}.\n` +
    `Follow the code path from the entry point related to this bug. Read only files relevant to the symptom. ` +
    `Look for: missing null checks, wrong async flow, incorrect condition, missing await, type mismatch. ` +
    `Return up to 5 hypotheses with cause, confidence, and evidence (file:line).`,
    { label: 'code-trace', phase: 'Trace', model: 'sonnet', schema: HYPOTHESIS_SCHEMA }),
  () => agent(
    `DB-trace for bug: ${BUG_BRIEF}. Task: ${TASK_ID}.\n` +
    `DB hint: ${DB_HINT}\n` +
    `Check Supabase state: ${DB_HINT}. Look for: unexpected nulls, missing rows, stale state, wrong status values, RLS-blocked writes (empty data with no error). ` +
    `Return up to 5 hypotheses with cause, confidence, and evidence (table/column/value).`,
    { label: 'db-trace', phase: 'Trace', model: 'sonnet', schema: HYPOTHESIS_SCHEMA }),
]
const traceResults = (await parallel(tracers)).filter(Boolean)
const allHypotheses = traceResults.flatMap(r => r.hypotheses || [])
log(`Trace: ${traceResults.length}/3 traces returned, ${allHypotheses.length} total hypotheses`)

phase('Reduce')
const result = await agent(
  `Merge and reduce these ${allHypotheses.length} hypotheses from log/code/db traces into a single root cause verdict for bug: ${BUG_BRIEF}.\n` +
  `Hypotheses: ${JSON.stringify(allHypotheses)}\n` +
  `Pick the most likely root_cause (high-confidence wins; corroboration across traces upgrades confidence). ` +
  `Set evidence_files to specific files/tables implicated. Provide a concrete fix_hint. List alternates for any competing hypotheses.`,
  { label: 'reduce', phase: 'Reduce', model: 'sonnet', schema: ROOT_CAUSE_SCHEMA })

return result || {
  root_cause: 'Reduce agent returned null — review raw hypotheses manually',
  confidence: 'low',
  evidence_files: [],
  fix_hint: 'Re-run with more specific logsHint or dbHint',
  alternates: allHypotheses.map(h => h.cause),
}
