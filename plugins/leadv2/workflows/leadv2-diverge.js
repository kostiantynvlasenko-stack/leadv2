export const meta = {
  name: 'leadv2-diverge',
  description: 'leadv2 Phase 1.5 Diverge as a workflow (judge-panel): N isolated frame-shifted generators + judge scores/clusters/flags traps + TopK selection. Model-pinned.',
  whenToUse: 'Open-ended high-stakes design decisions (Heavy / explicit /leadv2 diverge). Surfaces a non-obvious-but-viable candidate set for Phase 2 to converge on.',
  phases: [
    { title: 'Generate', detail: 'N isolated frame-shifted generators (zero cross-talk)' },
    { title: 'Judge', detail: 'critic scores / clusters / flags traps / deepens top-K' },
    { title: 'Select', detail: 'TopK=3 filter: drop traps, rank by score, dedupe clusters' },
  ],
}
const a = (typeof args === 'string' ? JSON.parse(args) : args) || {}
const TASK_ID = a.taskId || 'adhoc'
const PROBLEM = a.problem || a.taskBrief || ''
const OUT = `docs/handoff/${TASK_ID}/divergence.md`
const TOP_K = a.topK || 3   // [F6] TopK — default 3, caller can override
// Deterministic frame-shift by index (no Math.random — would break journaling/resume)
const FRAMES = [
  'MVP-first: simplest thing that could possibly work',
  'risk-first: minimize blast radius and irreversibility',
  'user-first: optimize the operator/customer experience',
  'cost-first: minimize token/compute/ops cost',
  'contrarian: invert the obvious approach, do the opposite',
  'first-principles: ignore how it is done today, derive from scratch',
  'steal-from-adjacent: port a pattern from a different domain',
  'automate-it-away: can the problem be deleted instead of solved',
]
const N = Math.min(Math.max(a.n || 6, 2), FRAMES.length)
const IDEA_SCHEMA = {
  type: 'object', additionalProperties: false,
  properties: { idea: { type: 'string' }, approach: { type: 'string' }, key_risk: { type: 'string' } },
  required: ['idea', 'approach'],
}
// [F6] Extended judge schema with quality scores per candidate
const JUDGE_SCHEMA = {
  type: 'object', additionalProperties: false,
  properties: {
    ranked: { type: 'array', items: { type: 'object', additionalProperties: false,
      properties: {
        idea: { type: 'string' },
        score: { type: 'number', minimum: 0, maximum: 10 },  // [F6] 0-10 quality score
        cluster: { type: 'string' },
        trap: { type: 'boolean' },
        why: { type: 'string' },
      },
      required: ['idea', 'score'] } },
    recommended: { type: 'string' },
    summary_for_lead: { type: 'string' },
  }, required: ['ranked', 'recommended', 'summary_for_lead'],
}


// ── C3: Ledger emit helper ────────────────────────────────────────────────────
async function emitLedger(event, extra) {
  const _taskId = (typeof TASK_ID !== 'undefined' ? TASK_ID : null) || (typeof a !== 'undefined' && a.task_id) || 'unknown'
  const ev = Object.assign({ event, task_id: _taskId }, extra || {})
  const _root = (typeof process !== 'undefined' && process.env && process.env.LEADV2_PROJECT_ROOT) || '.'
  try { await bash(`python3 "${_root}/.claude/scripts/lv2-ledger-emit.py" '${JSON.stringify(ev).replace(/'/g, "'\''")}' 2>/dev/null || true`) } catch (_) {}
}

phase('Generate')
await emitLedger('phase_enter', { phase: 'Generate' })
const gens = []
for (let i = 0; i < N; i++) {
  const frame = FRAMES[i]
  gens.push(() => agent(
    `Generate ONE distinct solution to this problem, strictly through this lens — ${frame}.\n` +
    `Problem: ${PROBLEM || `see docs/handoff/${TASK_ID}/`}.\n` +
    `Do not hedge toward the obvious answer; commit to the lens. Give idea + approach + key_risk.`,
    { label: `gen:${i}`, phase: 'Generate', model: 'sonnet', schema: IDEA_SCHEMA }))
}
const ideas = (await parallel(gens)).filter(Boolean)
log(`Generate: ${ideas.length}/${N} candidate ideas`)

phase('Judge')
await emitLedger('phase_enter', { phase: 'Judge' })
let judged = await agent(
  `Score and cluster these ${ideas.length} candidate solutions for task ${TASK_ID}. ` +
  `Score each 0-10 (10=best): feasibility(0-4) + novelty(0-3) + blast-radius(0-3, higher=safer). ` +
  `Flag traps (plausible-but-doomed, trap=true). Recommend ONE (or a synthesis) and say why. ` +
  `Also write a short divergence.md to ${OUT} with the ranked set.\n` +
  `Candidates: ${JSON.stringify(ideas)}`,
  { label: 'judge', phase: 'Judge', agentType: 'critic', model: 'sonnet', schema: JUDGE_SCHEMA })
if (judged === null) {
  log('Judge returned null — generating fallback summary via haiku')
  judged = await agent(
    `Judge agent failed for task ${TASK_ID}. Write a minimal fallback divergence.md to ${OUT} listing these ideas with no scores. ` +
    `Return { ranked: [], recommended: 'judge-failed — review ideas manually', summary_for_lead: 'Judge returned null; raw ideas listed in divergence.md' }.\n` +
    `Ideas: ${JSON.stringify(ideas.map(i => i.idea || '(unnamed)'))}`,
    { label: 'judge-fallback', phase: 'Judge', model: 'haiku', schema: JUDGE_SCHEMA })
}

phase('Select')
await emitLedger('phase_enter', { phase: 'Select' })
// [F6] TopK selection: drop traps, dedupe clusters (keep highest score per cluster), take top-K by score
const ranked = judged ? (judged.ranked || []) : []
const nonTraps = ranked.filter(r => !r.trap)
// Dedupe by cluster: keep highest score per cluster label
const clusterBest = new Map()
for (const r of nonTraps) {
  const cl = r.cluster || 'ungrouped'
  if (!clusterBest.has(cl) || r.score > clusterBest.get(cl).score) clusterBest.set(cl, r)
}
const deduped = [...clusterBest.values()].sort((a, b) => b.score - a.score)
const topK = deduped.slice(0, TOP_K)
log(`Select: ${ranked.length} ranked -> ${nonTraps.length} non-trap -> ${deduped.length} cluster-deduped -> ${topK.length} TopK`)

return {
  task_id: TASK_ID, divergence_path: OUT,
  candidate_count: ideas.length,
  ok: judged !== null,
  recommended: judged ? judged.recommended : null,
  top: topK,                              // [F6] TopK filtered + deduped (was slice(0,3) of raw ranked)
  top_raw: ranked.slice(0, 3),           // backward-compat: raw ranked top-3 still available
  traps_filtered: ranked.length - nonTraps.length,
}
