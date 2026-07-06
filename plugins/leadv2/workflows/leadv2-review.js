export const meta = {
  name: 'leadv2-review',
  description: 'leadv2 Phase 5 adversarial review: parallel critic + hack-detection + (security) + Codex → dedup → verify blocking → quality score → solutions-archive. Model-pinned.',
  whenToUse: 'leadv2 Phase 5 Review for class >= Standard. Lead invokes instead of hand-rolled Agent+Monitor. Returns one synthesized verdict + quality_score; lead context stays clean.',
  phases: [
    { title: 'Review', detail: 'parallel critic + hack-detect + security(if safety) + codex-adversarial' },
    { title: 'Verify', detail: 'adversarial refute pass on each blocking finding' },
    { title: 'Reflect', detail: 'quality scoring + write solutions-archive + append signature' },
  ],
}
let a
if (typeof args === 'string') { try { a = JSON.parse(args) } catch { a = { problem: args } } }
else { a = args }
a = a || {}
const TASK_ID = a.taskId || 'adhoc'
const BASE = a.base || 'main'
const SAFETY = a.safetyTouched === true
const MISSION = a.missionPath || `docs/handoff/${TASK_ID}/review-mission.md`
const DIFF = a.diffPath || `/tmp/leadv2-review-${TASK_ID}.diff`
const CODEX_ON = a.codexEnabled !== false
const TASK_CLASS = a.taskClass || 'general'
// H-1: single init-time timestamp — replay-safe on workflow resume.
// Workflow runtime throws on Date.now()/argless new Date() — derive stamp via bash() instead.
const TS = a.ts || (await bash("date -u +%Y-%m-%dT%H:%M:%SZ")).trim()
// [BANDIT-WIRE-01] Consume bandit model selections from args.models (set by lead before Workflow call).
// args.models absent (or LEADV2_ROUTE_BANDIT != 1) => falls back to existing pinned defaults.
// Flag-off guarantee: if args.models is not provided, model values are identical to pre-BANDIT-WIRE-01.
const _MODELS = (a.models && typeof a.models === 'object') ? a.models : {}
const CRITIC_MODEL = _MODELS.critic || (SAFETY ? 'opus' : 'sonnet')
const VERIFY_MODEL = _MODELS.verify || 'sonnet'
const FINDINGS_SCHEMA = {
  type: 'object', additionalProperties: false,
  properties: {
    findings: { type: 'array', items: {
      type: 'object', additionalProperties: false,
      properties: {
        severity: { type: 'string', enum: ['critical', 'high', 'medium', 'low', 'nit'] },
        dimension: { type: 'string' }, file: { type: 'string' },
        description: { type: 'string' }, suggested_fix: { type: 'string' },
      }, required: ['severity', 'dimension', 'description'],
    } },
    summary_for_lead: { type: 'string' },
  }, required: ['findings', 'summary_for_lead'],
}
const VERDICT_SCHEMA = {
  type: 'object', additionalProperties: false,
  properties: { is_real: { type: 'boolean' }, rationale: { type: 'string' } },
  required: ['is_real', 'rationale'],
}
// [F6] Quality scoring schema — structured rubric, not free-form
const QUALITY_SCHEMA = {
  type: 'object', additionalProperties: false,
  properties: {
    diff_coherence: { type: 'integer', minimum: 0, maximum: 4 },   // is diff focused, minimal, no dead code?
    test_coverage: { type: 'integer', minimum: 0, maximum: 3 },    // evidence of tests for new logic
    security_pass: { type: 'integer', minimum: 0, maximum: 3 },    // no obvious security gaps
    novelty_bonus: { type: 'integer', minimum: 0, maximum: 1 },    // touches new file paths (+1)
    quality_score: { type: 'number', minimum: 0, maximum: 10 },    // sum: coherence+coverage+security+novelty_bonus (capped 10)
    diff_summary: { type: 'string' },
  }, required: ['diff_coherence', 'test_coverage', 'security_pass', 'quality_score', 'diff_summary'],
}
const SEV_RANK = { critical: 4, high: 3, medium: 2, low: 1, nit: 0 }

// ── C3: Ledger emit helper ────────────────────────────────────────────────────
async function emitLedger(event, extra) {
  const _taskId = (typeof TASK_ID !== 'undefined' ? TASK_ID : null) || (typeof a !== 'undefined' && a.task_id) || 'unknown'
  const ev = Object.assign({ event, task_id: _taskId }, extra || {})
  const _root = (typeof process !== 'undefined' && process.env && process.env.LEADV2_PROJECT_ROOT) || '.'
  try { await bash(`_EMIT="${_root}/.claude/scripts/lv2-ledger-emit.py"; [ -f "$_EMIT" ] || _EMIT="$HOME/.claude/scripts/lv2-ledger-emit.py"; python3 "$_EMIT" '${JSON.stringify(ev).replace(/'/g, "'\\''")}' 2>/dev/null || true`) } catch (_) {}
}

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

phase('Review')
await emitLedger('phase_enter', { phase: 'Review' })
// [COST-LEVERS-01] Codex is the PRIMARY adversarial brain for Review (Lever 3). Agent critic is the fallback when CODEX_ON=false.
// Codex runs first (unshifted to front) for highest signal-to-token ratio; critic always present as fallback.
const reviewers = [
  () => synthAgent(
    `Adversarial code review of the diff at ${DIFF}. Brief: ${MISSION}. Read the diff yourself (git diff ${BASE}). Report findings: correctness bugs, type/RLS gaps, N+1, missing tests, design-system violations. Severity-tag each. Minimal-diff context only.`,
    { label: 'critic', phase: 'Review', agentType: 'critic', model: CRITIC_MODEL, effort: (SAFETY && CRITIC_MODEL !== 'sonnet') ? 'xhigh' : 'high', schema: FINDINGS_SCHEMA }),
  () => agent(
    `Run hack-detection on the diff at ${DIFF}: TODO/FIXME band-aids, magic numbers, broad except, hardcoded creds/secrets, silent fallbacks. Return each as a finding (dimension="hack").`,
    { label: 'hack-detect', phase: 'Review', model: 'haiku', effort: 'low', schema: FINDINGS_SCHEMA }),
]
if (SAFETY) {
  reviewers.push(() => agent(
    `Security review of the diff at ${DIFF}. Full-file read allowed for security paths. Check injection, auth/session, RLS correctness, webhook verification, secret handling, CSRF, rate-limit gaps. Severity-tag (dimension="security").`,
    { label: 'security-auditor', phase: 'Review', agentType: 'security-auditor', model: 'sonnet', effort: 'high', schema: FINDINGS_SCHEMA }))
}
if (CODEX_ON) {
  // Codex is primary: unshift to run before agent-critic in parallel (first slot = primary adversarial brain)
  reviewers.unshift(() => agent(
    `Run and wait: bash ~/.claude/scripts/codex-task.sh adversarial-review --wait --base ${BASE}. Then read findings with: bash ~/.claude/scripts/cx-tail.sh <output-file>. Parse [critical]/[high]/[medium]/[low] lines into findings (dimension="codex"). If codex unavailable (exit non-zero), return empty findings with summary_for_lead="codex unavailable". Do NOT invent findings.`,
    { label: 'codex-adversarial', phase: 'Review', model: 'haiku', effort: 'low', schema: FINDINGS_SCHEMA }))
}
const reviewResults = (await parallel(reviewers)).filter(Boolean)
const allFindings = reviewResults.flatMap(r => r.findings || [])
const seen = new Map()
for (const f of allFindings) {
  const key = `${f.dimension || ''}|${f.file || ''}|${(f.description || '').slice(0, 80).toLowerCase()}`
  const prev = seen.get(key)
  if (!prev || (SEV_RANK[f.severity] || 0) > (SEV_RANK[prev.severity] || 0)) seen.set(key, f)
}
const deduped = [...seen.values()]
const blocking = deduped.filter(f => f.severity === 'critical' || f.severity === 'high')
log(`Review: ${allFindings.length} raw -> ${deduped.length} deduped, ${blocking.length} blocking`)
// [STALL-DETECT-01] Deterministic no-progress guard: identical blocking signature across rounds triggers escalation
const blocking_count = blocking.length
const sig = deduped.filter(f => /critical|high/i.test(f.severity || '')).map(f => (f.dimension || '?') + ':' + (f.severity || '?')).sort().join('|')
const prior = Array.isArray(a.priorSignatures) ? a.priorSignatures : []
const recent = [...prior, sig]
const stall = blocking_count > 0 && recent.length >= 2 && recent.slice(-2).every(s => s === sig)
phase('Verify')
await emitLedger('phase_enter', { phase: 'Verify' })
const MAX_VERIFY = a.maxVerify || 10
const overflowFindings = blocking.length > MAX_VERIFY ? blocking.slice(MAX_VERIFY) : []
const cappedBlocking = blocking.slice(0, MAX_VERIFY)
let confirmedBlocking = cappedBlocking
if (cappedBlocking.length > 0) {
  const verdicts = await parallel(cappedBlocking.map(f => () =>
    agent(
      `Try to REFUTE this finding. Default is_real=false if you cannot concretely confirm it against ${DIFF}. Finding [${f.severity}/${f.dimension}]: ${f.description}. Fix: ${f.suggested_fix || '(none)'}.`,
      { label: `verify:${f.dimension}`, phase: 'Verify', model: VERIFY_MODEL, effort: 'high', schema: VERDICT_SCHEMA }
    ).then(v => ({ ...f, verdict: v }))))
  confirmedBlocking = verdicts.filter(Boolean).filter(f => f.verdict && f.verdict.is_real)
  log(`Verify: ${cappedBlocking.length} capped (${overflowFindings.length} overflow) -> ${confirmedBlocking.length} survived refutation`)
}
phase('Reflect')
await emitLedger('phase_enter', { phase: 'Reflect' })
const ROUND = a.round || 1
const maxSev = deduped.reduce((m, f) => Math.max(m, SEV_RANK[f.severity] || 0), 0)
const ESCALATE_VERDICT = 'ESCALATE'
let verdict = confirmedBlocking.length === 0 ? 'ACCEPT' : (ROUND >= 2 ? ESCALATE_VERDICT : 'REVISE')
// [STALL-DETECT-01] Force escalation when blocking signature unchanged across 2+ rounds
if (stall) { verdict = ESCALATE_VERDICT }

// [F6] Quality scoring — structured rubric via JSON schema; only fires on ACCEPT or informational pass
// Score: diff_coherence(0-4) + test_coverage(0-3) + security_pass(0-3) + novelty_bonus(0-1) = max 10
const qualityResult = await agent(
  `Score the quality of this diff for task ${TASK_ID} using this rubric:\n` +
  `1. diff_coherence (0-4): Is the diff focused and minimal? 4=tight/no dead code, 0=sprawling/unrelated changes.\n` +
  `2. test_coverage (0-3): Evidence of tests for new logic? 3=full coverage, 0=none.\n` +
  `3. security_pass (0-3): No obvious security gaps (injection, missing auth, exposed secrets)? 3=clean, 0=critical gap.\n` +
  `4. novelty_bonus (0-1): Does the diff touch new file paths not previously seen? 1=yes, 0=no.\n` +
  `quality_score = min(10, diff_coherence + test_coverage + security_pass + novelty_bonus).\n` +
  `Read git diff ${BASE} to assess. Write a 1-sentence diff_summary.\n` +
  `Review findings context: ${confirmedBlocking.length} blocking, ${deduped.length} total findings.`,
  { label: 'quality-scorer', phase: 'Reflect', model: 'haiku', effort: 'low', schema: QUALITY_SCHEMA })

const qualityScore = qualityResult ? qualityResult.quality_score : null
const diffSummary = qualityResult ? qualityResult.diff_summary : '(scoring unavailable)'
log(`Quality score: ${qualityScore}/10 — ${diffSummary}`)

// [F6] Write scored entry to solutions-archive.yaml (append-safe via python3)
// Only write on ACCEPT; REVISE/ESCALATE entries have incomplete solutions — skip to avoid polluting archive
if (verdict === 'ACCEPT' && qualityScore !== null) {
  await agent(
    `Append a new entry to docs/leadv2/solutions-archive.yaml. ` +
    `Create the file with an empty YAML list if it does not exist. ` +
    `Read the file first, append this entry to the list, then write the full file back:\n` +
    `  - task_id: "${TASK_ID}"\n` +
    `    task_class: "${TASK_CLASS}"\n` +
    `    score: ${qualityScore}\n` +
    `    diff_summary: "${diffSummary.replace(/"/g, "'")}"\n` +
    `    ts: "${TS}"\n` +
    `Use python3: import yaml; load existing or []; append entry; dump back. Return "ok".`,
    { label: 'archive-write', phase: 'Reflect', model: 'haiku', effort: 'low' })
}

await agent(
  `Append one line to docs/handoff/${TASK_ID}/review-signature.md (create if absent): "${TASK_ID} | verdict=${verdict} | blocking=${confirmedBlocking.length} | dims=${[...new Set(deduped.map(f => f.dimension))].join(',')} | quality=${qualityScore !== null ? qualityScore : 'n/a'}". One Bash echo, no analysis. Return "ok".`,
  { label: 'reflect', phase: 'Reflect', model: 'haiku', effort: 'low' })
return {
  task_id: TASK_ID, verdict, round: ROUND, blocking_count: confirmedBlocking.length,
  blocking: confirmedBlocking.map(f => ({ severity: f.severity, dimension: f.dimension, file: f.file, description: f.description })),
  total_findings: deduped.length,
  max_severity: ['nit', 'low', 'medium', 'high', 'critical'][maxSev],
  quality_score: qualityScore,
  diff_summary: diffSummary,
  followups: deduped.filter(f => !(f.severity === 'critical' || f.severity === 'high')),
  overflow_findings: overflowFindings.map(f => ({ ...f, confirmed: false })),
  signature: sig,
  stall,
  ...(stall ? { stall_reason: 'identical blocking signature 2 rounds' } : {}),
}
