export const meta = {
  name: 'leadv2-diagnose',
  description: 'Bug root-cause workflow: symptom-classifier (haiku) → parallel evidence-gather per cluster (haiku, max 3) → sonnet synthesizer. Model-pinned (haiku reads, sonnet synthesizes).',
  whenToUse: 'Use when a bug needs systematic root-cause analysis. Lead invokes with taskId, bugBrief, optional logsHint and dbHint. Returns root_cause, confidence, evidence_files, fix_hint, alternates.',
  phases: [
    { title: 'Classify', detail: 'haiku symptom-classifier: identify up to 3 symptom clusters' },
    { title: 'Trace', detail: 'parallel evidence-gather agents per cluster (haiku, max 3) — fan-out over classifier output' },
    { title: 'Reduce', detail: 'sonnet merges cluster evidence into single root_cause verdict' },
  ],
}
let a
if (typeof args === 'string') { try { a = JSON.parse(args) } catch { a = { problem: args } } }
else { a = args }
a = a || {}
const TASK_ID = a.taskId || 'adhoc'
const BUG_BRIEF = a.bugBrief || ''
const LOGS_HINT = a.logsHint || 'journalctl -u persona-engine --since "1 hour ago" | tail -200'
const DB_HINT = a.dbHint || 'check recent rows in actions, health_metrics, strategy_proposals'

const SYMPTOM_SCHEMA = {
  type: 'object', additionalProperties: false,
  properties: {
    clusters: { type: 'array', maxItems: 3, items: {
      type: 'object', additionalProperties: false,
      properties: {
        name: { type: 'string' },
        domain: { type: 'string', enum: ['logs', 'code', 'db', 'ops'] },
        symptom_hint: { type: 'string' },
        probe_command: { type: 'string' },  // specific command to run for this cluster
      }, required: ['name', 'domain', 'symptom_hint'],
    } },
    summary_for_lead: { type: 'string' },
  }, required: ['clusters', 'summary_for_lead'],
}
const EVIDENCE_SCHEMA = {
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
    cluster: { type: 'string' },
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

// [D4] Phase 1: symptom-classifier (haiku) — replaces monolithic trace fan-out with dynamic clusters

// ── C3: Ledger emit helper ────────────────────────────────────────────────────
async function emitLedger(event, extra) {
  const _taskId = (typeof TASK_ID !== 'undefined' ? TASK_ID : null) || (typeof a !== 'undefined' && a.task_id) || 'unknown'
  const ev = Object.assign({ event, task_id: _taskId }, extra || {})
  const _root = (typeof process !== 'undefined' && process.env && process.env.LEADV2_PROJECT_ROOT) || '.'
  try { await bash(`_EMIT="${_root}/.claude/scripts/lv2-ledger-emit.py"; [ -f "$_EMIT" ] || _EMIT="$HOME/.claude/scripts/lv2-ledger-emit.py"; python3 "$_EMIT" '${JSON.stringify(ev).replace(/'/g, "'\\''")}' 2>/dev/null || true`) } catch (_) {}
}

phase('Classify')
await emitLedger('phase_enter', { phase: 'Classify' })
const classified = await agent(
  `Classify symptoms for bug: ${BUG_BRIEF}. Task: ${TASK_ID}.\n` +
  `Identify up to 3 distinct symptom clusters (domain: logs|code|db|ops). ` +
  `For each cluster: give a name, the domain to probe, a 1-sentence symptom_hint, and an optional probe_command (the exact bash command to run to gather evidence for this cluster). ` +
  `Logs hint available: ${LOGS_HINT}. DB hint: ${DB_HINT}.\n` +
  `Return clusters[] + summary_for_lead.`,
  { label: 'symptom-classifier', phase: 'Classify', model: 'haiku', effort: 'low', schema: SYMPTOM_SCHEMA })

const clusters = (classified && classified.clusters && classified.clusters.length > 0)
  ? classified.clusters
  // Fallback: static three-domain decomposition if classifier returns null/empty
  : [
      { name: 'log-trace', domain: 'logs', symptom_hint: BUG_BRIEF, probe_command: LOGS_HINT },
      { name: 'code-trace', domain: 'code', symptom_hint: BUG_BRIEF },
      { name: 'db-trace', domain: 'db', symptom_hint: DB_HINT, probe_command: DB_HINT },
    ]
log(`Classify: ${clusters.length} symptom clusters: ${clusters.map(c => c.name).join(', ')}`)

// [D4] Phase 2: parallel evidence-gather per cluster (haiku, max 3 concurrent)
phase('Trace')
await emitLedger('phase_enter', { phase: 'Trace' })
const evidenceAgents = clusters.slice(0, 3).map(cl => () => agent(
  `Evidence-gather for cluster "${cl.name}" (domain: ${cl.domain}) of bug: ${BUG_BRIEF}. Task: ${TASK_ID}.\n` +
  `Symptom hint: ${cl.symptom_hint}.\n` +
  (cl.probe_command ? `Run this command to gather evidence: ${cl.probe_command}\n` : '') +
  `Domain-specific guidance:\n` +
  (cl.domain === 'logs'
    ? `Look for ERROR/CRITICAL/Traceback/exception lines near the symptom. Extract timestamps and service names.`
    : cl.domain === 'code'
    ? `Follow the code path from the entry point. Look for: missing null checks, wrong async flow, missing await, type mismatch.`
    : cl.domain === 'db'
    ? `Check Supabase state: ${DB_HINT}. Look for: unexpected nulls, missing rows, stale status, RLS-blocked writes.`
    : `Check ops/infra: systemd unit status, env vars, deploy state, file permissions.`) +
  `\nReturn up to 5 hypotheses (cause, confidence, evidence). Set cluster="${cl.name}".`,
  { label: `trace:${cl.name}`, phase: 'Trace', model: 'haiku', effort: 'low', schema: EVIDENCE_SCHEMA }))

const traceResults = (await parallel(evidenceAgents)).filter(Boolean)
const allHypotheses = traceResults.flatMap(r => r.hypotheses || [])
log(`Trace: ${traceResults.length}/${clusters.length} clusters returned, ${allHypotheses.length} total hypotheses`)

// synth stages: try top model, fall back on null/error
async function synthAgent(prompt, opts = {}) {
  const chain = [...new Set([opts.model || 'opus', 'sonnet'])]
  for (const m of chain) {
    try {
      const r = await agent(prompt, { ...opts, model: m })
      if (r !== null) return r
    } catch (e) { /* fall through */ }
    log(`synthAgent: ${m} unavailable, falling back`)
  }
  return null
}

// [D4] Phase 3: sonnet synthesizer (unchanged interface — backward-compat)
phase('Reduce')
await emitLedger('phase_enter', { phase: 'Reduce' })
const result = await synthAgent(
  `Merge and reduce these ${allHypotheses.length} hypotheses from ${traceResults.length} symptom clusters into a single root cause verdict for bug: ${BUG_BRIEF}.\n` +
  `Hypotheses: ${JSON.stringify(allHypotheses)}\n` +
  `Pick the most likely root_cause (high-confidence wins; corroboration across clusters upgrades confidence). ` +
  `Set evidence_files to specific files/tables implicated. Provide a concrete fix_hint. List alternates for any competing hypotheses.`,
  { label: 'reduce', phase: 'Reduce', model: 'opus', effort: 'medium', schema: ROOT_CAUSE_SCHEMA })

return result || {
  root_cause: 'Reduce agent returned null — review raw hypotheses manually',
  confidence: 'low',
  evidence_files: [],
  fix_hint: 'Re-run with more specific logsHint or dbHint',
  alternates: allHypotheses.map(h => h.cause),
}
