export const meta = {
  name: 'leadv2-review',
  description: 'leadv2 Phase 5 adversarial review as a workflow: parallel critic + hack-detection + (security) + Codex, reduce to blocking count, optional adversarial verify, reflect tail. Model-pinned (never Opus-by-inheritance).',
  whenToUse: 'leadv2 Phase 5 Review for class >= Standard. Lead invokes instead of hand-rolled Agent+Monitor. Returns one synthesized verdict; lead context stays clean.',
  phases: [
    { title: 'Review', detail: 'parallel critic + hack-detect + security(if safety) + codex-adversarial' },
    { title: 'Verify', detail: 'adversarial refute pass on each blocking finding' },
    { title: 'Reflect', detail: 'append signatures/learning note' },
  ],
}
const a = (typeof args === 'string' ? JSON.parse(args) : args) || {}
const TASK_ID = a.taskId || 'adhoc'
const BASE = a.base || 'main'
const SAFETY = a.safetyTouched === true
const MISSION = a.missionPath || `docs/handoff/${TASK_ID}/review-mission.md`
const DIFF = a.diffPath || `/tmp/leadv2-review-${TASK_ID}.diff`
const CODEX_ON = a.codexEnabled !== false
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
const SEV_RANK = { critical: 4, high: 3, medium: 2, low: 1, nit: 0 }
phase('Review')
const reviewers = [
  () => agent(
    `Adversarial code review of the diff at ${DIFF}. Brief: ${MISSION}. Read the diff yourself (git diff ${BASE}). Report findings: correctness bugs, type/RLS gaps, N+1, missing tests, design-system violations. Severity-tag each. Minimal-diff context only.`,
    { label: 'critic', phase: 'Review', agentType: 'critic', model: SAFETY ? 'opus' : 'sonnet', schema: FINDINGS_SCHEMA }),
  () => agent(
    `Run hack-detection on the diff at ${DIFF}: TODO/FIXME band-aids, magic numbers, broad except, hardcoded creds/secrets, silent fallbacks. Return each as a finding (dimension="hack").`,
    { label: 'hack-detect', phase: 'Review', model: 'haiku', schema: FINDINGS_SCHEMA }),
]
if (SAFETY) {
  reviewers.push(() => agent(
    `Security review of the diff at ${DIFF}. Full-file read allowed for security paths. Check injection, auth/session, RLS correctness, webhook verification, secret handling, CSRF, rate-limit gaps. Severity-tag (dimension="security").`,
    { label: 'security-auditor', phase: 'Review', agentType: 'security-auditor', model: 'sonnet', schema: FINDINGS_SCHEMA }))
}
if (CODEX_ON) {
  reviewers.push(() => agent(
    `Run and wait: bash ~/.claude/scripts/codex-task.sh adversarial-review --wait --base ${BASE}. Then read findings with: bash ~/.claude/scripts/cx-tail.sh <output-file>. Parse [critical]/[high]/[medium]/[low] lines into findings (dimension="codex"). If codex unavailable (exit non-zero), return empty findings with summary_for_lead="codex unavailable". Do NOT invent findings.`,
    { label: 'codex-adversarial', phase: 'Review', model: 'haiku', schema: FINDINGS_SCHEMA }))
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
phase('Verify')
const MAX_VERIFY = a.maxVerify || 10
const overflowFindings = blocking.length > MAX_VERIFY ? blocking.slice(MAX_VERIFY) : []
const cappedBlocking = blocking.slice(0, MAX_VERIFY)
let confirmedBlocking = cappedBlocking
if (cappedBlocking.length > 0) {
  const verdicts = await parallel(cappedBlocking.map(f => () =>
    agent(
      `Try to REFUTE this finding. Default is_real=false if you cannot concretely confirm it against ${DIFF}. Finding [${f.severity}/${f.dimension}]: ${f.description}. Fix: ${f.suggested_fix || '(none)'}.`,
      { label: `verify:${f.dimension}`, phase: 'Verify', model: 'sonnet', schema: VERDICT_SCHEMA }
    ).then(v => ({ ...f, verdict: v }))))
  confirmedBlocking = verdicts.filter(Boolean).filter(f => f.verdict && f.verdict.is_real)
  log(`Verify: ${cappedBlocking.length} capped (${overflowFindings.length} overflow) -> ${confirmedBlocking.length} survived refutation`)
}
phase('Reflect')
const ROUND = a.round || 1
const maxSev = deduped.reduce((m, f) => Math.max(m, SEV_RANK[f.severity] || 0), 0)
const verdict = confirmedBlocking.length === 0 ? 'ACCEPT' : (ROUND >= 2 ? 'ESCALATE' : 'REVISE')
await agent(
  `Append one line to docs/handoff/${TASK_ID}/review-signature.md (create if absent): "${TASK_ID} | verdict=${verdict} | blocking=${confirmedBlocking.length} | dims=${[...new Set(deduped.map(f => f.dimension))].join(',')}". One Bash echo, no analysis. Return "ok".`,
  { label: 'reflect', phase: 'Reflect', model: 'haiku' })
return {
  task_id: TASK_ID, verdict, round: ROUND, blocking_count: confirmedBlocking.length,
  blocking: confirmedBlocking.map(f => ({ severity: f.severity, dimension: f.dimension, file: f.file, description: f.description })),
  total_findings: deduped.length,
  max_severity: ['nit', 'low', 'medium', 'high', 'critical'][maxSev],
  followups: deduped.filter(f => !(f.severity === 'critical' || f.severity === 'high')),
  overflow_findings: overflowFindings.map(f => ({ ...f, confirmed: false })),
}
