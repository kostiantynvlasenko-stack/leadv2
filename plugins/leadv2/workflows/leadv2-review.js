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
// [FAMILY-GATE-01] Cross-provider-family review gate kill-switch — default ON; '0' disables
// the whole feature (no families/family_coverage fields, no downgrade, byte-identical to
// pre-FAMILY-GATE-01 behavior).
const FAMILY_GATE_ON = ((typeof process !== 'undefined' && process.env && process.env.LEADV2_REVIEW_FAMILY_GATE) || '1') !== '0'
// WORKFLOW-BASH-FIX-01: the real Workflow runtime provides ONLY agent()/parallel()/pipeline()/
// log()/phase()/args/budget — there is NO bash() global. This file used to make 4 real bare
// `await bash(...)` calls (undefined at runtime → crash): the TS derive (single consumer:
// the archive-write entry below), emitLedger (×3 runtime), the _archiveRoot git-common-dir
// resolve (single consumer: archive-write), and the semantic-index best-effort append (always
// sequenced right after archive-write). All 4 are folded into the SAME existing 'archive-write'
// / 'reflect' agent calls (Move 1 + Move 2) — zero net new agent() calls:
//   - TS: pass-through from args.ts if the caller supplied it; else the archive-write prompt
//     asks the agent to resolve it itself via Bash, verbatim, as one more instruction.
//   - _archiveRoot resolve: folded into the archive-write prompt (agent resolves it itself,
//     same pattern as leadv2-plan.js's archive-read).
//   - semantic-index append: built as ONE fully self-contained, already-escaped shell command
//     in JS (unchanged escaping logic — R1) and passed to the SAME archive-write agent call as
//     a best-effort trailing instruction (never blocks Reflect on failure).
//   - emitLedger → pure-JS in-memory ledgerEvents array (pushLedger, no I/O); flushed via the
//     'reflect' agent call at the end — that call runs UNCONDITIONALLY regardless of verdict,
//     so the ledger flush must live there (NOT inside the verdict==='ACCEPT' branch, since
//     ledger events must flush every round, not just on accept).
const TS = a.ts || ''
// [BANDIT-WIRE-01] Consume bandit model selections from args.models (set by lead before Workflow call).
// args.models absent (or LEADV2_ROUTE_BANDIT != 1) => falls back to existing pinned defaults.
// Flag-off guarantee: if args.models is not provided, model values are identical to pre-BANDIT-WIRE-01.
const _MODELS = (a.models && typeof a.models === 'object') ? a.models : {}
const CRITIC_MODEL = _MODELS.critic || (SAFETY ? 'opus' : 'sonnet')
const VERIFY_MODEL = _MODELS.verify || 'sonnet'
const projRoot = (typeof process !== 'undefined' && process.env && process.env.LEADV2_PROJECT_ROOT) || '.'
// Single canonical root-resolve one-liner, shared by both the archive-write prompt's own
// resolve instruction and the self-contained semantic-index command below — kept as ONE
// un-split literal (not concatenated across `+`-joined segments) so it stays a single
// extractable unit, e.g. for tests/tools that locate this exact resolution pattern by content.
const ROOT_RESOLVE_CMD = `_r="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null | xargs dirname 2>/dev/null)"; [ -n "$_r" ] && [ -d "$_r/docs/leadv2" ] && printf '%s' "$_r" || pwd`
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
// Move 2 (Ledger-flush): accumulate in-memory, no I/O per event. Flushed via the final
// 'reflect' agent call, which runs unconditionally (every round, every verdict).
const ledgerEvents = []
function pushLedger(event, extra) {
  const _taskId = (typeof TASK_ID !== 'undefined' ? TASK_ID : null) || (typeof a !== 'undefined' && a.task_id) || 'unknown'
  ledgerEvents.push(Object.assign({ event, task_id: _taskId }, extra || {}))
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
pushLedger('phase_enter', { phase: 'Review' })
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
// [FAMILY-GATE-01] Provider family per reviewer, built in lockstep with `reviewers` (same
// push/unshift order) so index i in reviewerFamilies always matches index i in reviewers.
const reviewerFamilies = ['anthropic', 'anthropic']
if (SAFETY) {
  reviewers.push(() => agent(
    `Security review of the diff at ${DIFF}. Full-file read allowed for security paths. Check injection, auth/session, RLS correctness, webhook verification, secret handling, CSRF, rate-limit gaps. Severity-tag (dimension="security").`,
    { label: 'security-auditor', phase: 'Review', agentType: 'security-auditor', model: 'sonnet', effort: 'high', schema: FINDINGS_SCHEMA }))
  reviewerFamilies.push('anthropic')
}
if (CODEX_ON) {
  // Codex is primary: unshift to run before agent-critic in parallel (first slot = primary adversarial brain)
  reviewers.unshift(() => agent(
    `Run and wait: bash ~/.claude/scripts/codex-task.sh adversarial-review --wait --base ${BASE} --tier top. Then read findings with: bash ~/.claude/scripts/cx-tail.sh <output-file>. Parse [critical]/[high]/[medium]/[low] lines into findings (dimension="codex"). If codex unavailable (exit non-zero), return empty findings with summary_for_lead="codex unavailable". Do NOT invent findings.`,
    { label: 'codex-adversarial', phase: 'Review', model: 'haiku', effort: 'low', schema: FINDINGS_SCHEMA }))
  reviewerFamilies.unshift('openai')
}
const rawReviewResults = await parallel(reviewers)
const reviewResults = rawReviewResults.filter(Boolean)
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
pushLedger('phase_enter', { phase: 'Verify' })
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
pushLedger('phase_enter', { phase: 'Reflect' })
const ROUND = a.round || 1
const maxSev = deduped.reduce((m, f) => Math.max(m, SEV_RANK[f.severity] || 0), 0)
const ESCALATE_VERDICT = 'ESCALATE'
let verdict = confirmedBlocking.length === 0 ? 'ACCEPT' : (ROUND >= 2 ? ESCALATE_VERDICT : 'REVISE')
// [STALL-DETECT-01] Force escalation when blocking signature unchanged across 2+ rounds
if (stall) { verdict = ESCALATE_VERDICT }

// [FAMILY-GATE-01] Cross-provider-family review gate. A panel that only ever ran reviewers
// from ONE provider family (e.g. Codex login down -> only anthropic-family critic/hack-detect
// ran) must not be allowed to self-certify ACCEPT -- downgrade to ESCALATE so the lead sees
// verification was partial. FAIL-SOFT: any error here falls through to the original verdict.
// A reviewer that FAILED still returns a non-null sentinel (e.g. the codex path returns
// `summary_for_lead="codex unavailable"` with empty findings on exit non-zero) -- that sentinel
// must NOT count toward family coverage, or a dead Codex silently satisfies the >=2-family bar.
const isUnavailableResult = (r) => !!(r && typeof r.summary_for_lead === 'string' && /unavailable/i.test(r.summary_for_lead))
let families = []
let family_coverage = null
if (FAMILY_GATE_ON) {
  try {
    families = [...new Set(rawReviewResults.map((r, i) => (r && !isUnavailableResult(r)) ? reviewerFamilies[i] : null).filter(Boolean))]
    if (families.length < 2 && verdict === 'ACCEPT') {
      family_coverage = `single:${families[0] || 'none'}`
      verdict = ESCALATE_VERDICT
      log(`family-gate: single-family panel (${family_coverage}) -- downgrading ACCEPT -> ESCALATE`)
      // TODO(family-gate): add zhipu (GLM) fallback reviewer here before downgrading. No
      // reviewer-spawn helper exists in this file beyond the reviewers[]/agent()/synthAgent()
      // wiring already built above -- wiring an automatic GLM reviewer spawn on gate-trip would
      // be new spawn infra, out of scope for this change.
    } else {
      family_coverage = families.length >= 2 ? 'multi' : (families.length === 1 ? `single:${families[0]}` : 'none')
    }
  } catch (e) {
    log(`family-gate: error computing family coverage, falling through to original verdict -- ${e && e.message}`)
    families = []
    family_coverage = null
  }
}

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
  // MEM-WRITE-PATH-FIX-01: a bare relative path resolves inside the task's worktree
  // cwd, and solutions-archive.yaml is intentionally gitignored (local state, never
  // committed) -- so a worktree-local write is silently lost on worktree sweep.
  // Anchor to the shared main-repo root (git-common-dir, same .git for every worktree).
  // MEM-WRITE-PATH-FIX-01 round2: marker-check hardening. Ambient bash() cwd is
  // unverified (no platform contract found -- see build.md Fix round 2 finding #1);
  // if bash() ever ran from an unrelated git repo (e.g. plugin-cache dir), a bare
  // git-common-dir resolve would silently land in the WRONG repo's docs/leadv2.
  // Require the resolved root to actually contain docs/leadv2/ before trusting it;
  // otherwise fail safe to ambient pwd rather than writing into a foreign repo.
  const diffSummaryEsc = diffSummary.replace(/"/g, "'")
  // WORKFLOW-BASH-FIX-01: fully self-contained, already-escaped shell command built in JS
  // (unchanged escaping logic — R1). Independently re-resolves the archive root itself so it
  // does not depend on any shell state persisting from a prior instruction in this same
  // agent turn. Best-effort — must never block Reflect on failure.
  const diffSummaryShEsc = diffSummary.replace(/'/g, "'\\''")
  const semanticIndexCmd =
    `PLUGIN_SCRIPTS="\${CLAUDE_PLUGIN_ROOT:-}/scripts"; ` +
    `[ -f "$PLUGIN_SCRIPTS/leadv2-semantic-index.sh" ] || exit 0; ` +
    `text='${diffSummaryShEsc} ${TASK_CLASS}'; ` +
    `chash=$(printf '%s' "$text" | shasum -a 1 | awk '{print $1}'); ` +
    `_archive_root="$(${ROOT_RESOLVE_CMD})"; ` +
    `bash "$PLUGIN_SCRIPTS/leadv2-semantic-index.sh" solutions '${TASK_ID}' "" "$chash" "$text" "$(basename "$_archive_root")" >/dev/null 2>&1 || true`
  await agent(
    `First resolve the durable repo root by running this EXACT command via your Bash tool, ` +
    `verbatim (do not modify it):\n${ROOT_RESOLVE_CMD}\n` +
    `(this resolves the shared main-repo root even when cwd is a task worktree, but only trusts ` +
    `it if docs/leadv2 actually exists there — else falls back to pwd). ` +
    `Then append a new entry to <that_root>/docs/leadv2/solutions-archive.yaml. ` +
    `Create the file with an empty YAML list if it does not exist. ` +
    `Read the file first, append this entry to the list, then write the full file back:\n` +
    `  - task_id: "${TASK_ID}"\n` +
    `    task_class: "${TASK_CLASS}"\n` +
    `    score: ${qualityScore}\n` +
    `    diff_summary: "${diffSummaryEsc}"\n` +
    `    ts: "${TS || '<run: date -u +%Y-%m-%dT%H:%M:%SZ via Bash and use its trimmed stdout here>'}"\n` +
    `Use python3: import yaml; load existing or []; append entry; dump back. ` +
    `Then, best-effort (never fail this whole step if it errors — it is optional indexing, ` +
    `not required for the archive write above to count as done), run this EXACT command via ` +
    `Bash, verbatim (it is already fully constructed and shell-escaped, do not modify it):\n${semanticIndexCmd}\n` +
    `Return "ok".`,
    { label: 'archive-write', phase: 'Reflect', model: 'haiku', effort: 'low' })
}

pushLedger('task_close', {
  verdict, blocking_count: confirmedBlocking.length, total_findings: deduped.length,
  quality_score: qualityScore,
})
// Move 2: ledger flush folded into this 'reflect' call, which runs UNCONDITIONALLY every
// round regardless of verdict — events must flush every round, not just on ACCEPT.
const ledgerFlushInstructions = ledgerEvents.length > 0
  ? `\n\nALSO append each of these ${ledgerEvents.length} JSON objects as its own line to the ` +
    `ledger, one at a time and in order, via this exact command per event (substitute ` +
    `<event-json> with the object, verbatim — it is already valid JSON, do not reformat or ` +
    `re-derive it):\n` +
    `_EMIT="${projRoot}/.claude/scripts/lv2-ledger-emit.py"; [ -f "$_EMIT" ] || _EMIT="$HOME/.claude/scripts/lv2-ledger-emit.py"; python3 "$_EMIT" '<event-json>' 2>/dev/null || true\n` +
    `Events (in order): ${JSON.stringify(ledgerEvents)}\n`
  : ''
await agent(
  `Append one line to docs/handoff/${TASK_ID}/review-signature.md (create if absent): "${TASK_ID} | verdict=${verdict} | blocking=${confirmedBlocking.length} | dims=${[...new Set(deduped.map(f => f.dimension))].join(',')} | quality=${qualityScore !== null ? qualityScore : 'n/a'}". One Bash echo, no analysis.` +
  ledgerFlushInstructions +
  `Return "ok" once the review-signature append${ledgerEvents.length > 0 ? ' and the ledger-flush commands have' : ' has'} completed.`,
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
  // [FAMILY-GATE-01] auditability -- omitted entirely when LEADV2_REVIEW_FAMILY_GATE=0
  ...(FAMILY_GATE_ON ? { families, family_coverage } : {}),
}
