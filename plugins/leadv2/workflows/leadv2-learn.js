export const meta = {
  name: 'leadv2-learn',
  description: 'Learning-aggregation workflow: consume accumulated review/plan signatures + immune patterns, detect recurring failure modes, propose concrete tuning (prompts/routing/skill-promotion). Writes a GOVERNANCE proposal — never auto-applies. Model-pinned.',
  whenToUse: 'Periodically or at Phase 8 Close. Turns per-task signatures into compounding system improvement ("the system gets smarter"). Founder/auto-approve applies proposals.',
  phases: [
    { title: 'Gather', detail: 'aggregate signatures + immune patterns' },
    { title: 'Propose', detail: 'recurring-pattern → concrete tuning proposal' },
    { title: 'Shadow-Emit', detail: 'classify risk_level + emit shadow proposals to docs/leadv2/shadow/proposals/' },
  ],
}
const a = (typeof args === 'string' ? JSON.parse(args) : args) || {}
const LABEL = a.label || 'latest'
const TASK_ID = a.task_id || ''
const OUT = `docs/leadv2/learning-proposals/${LABEL}.md`

// ── Risk classification rules (D3 / G3c) ─────────────────────────────────────
// Encoded constants — NOT runtime heuristics. Resolves C-critical-2 / R9.
// HIGH-risk: kind in {skill-promote, negative-memory, cross-repo-pattern, other};
//            routing-change that mutates routing.yaml KEYS (not just numeric values);
//            any target matching deploy/safety gate file patterns.
// LOW-risk:  prompt-tweak targeting mission-template lines;
//            routing-change targeting ONLY numeric threshold values in routing.yaml.
// cross-repo-pattern: always high (D21) — routes to immune-pattern insertion path
//            with cross-repo provenance metadata preserved; same branch as negative-memory.
// risk_level written at emit time; shadow-apply reads it from the yaml — never re-derives.

// cross-repo-pattern: always high-risk (founder-gated); D21
const HIGH_RISK_KINDS = new Set(['skill-promote', 'negative-memory', 'cross-repo-pattern', 'other'])
const DEPLOY_SAFETY_PATTERNS = [/deploy/i, /safety[_-]gate/i, /guard/i, /scorecard/i]

/** classifyRisk — enumerated rules (D3). Returns 'low' | 'high'. */
function classifyRisk(kind, target, change) {
  if (HIGH_RISK_KINDS.has(kind)) return 'high'
  for (const pat of DEPLOY_SAFETY_PATTERNS) { if (pat.test(target)) return 'high' }
  if (kind === 'routing-change') {
    if (target.includes('routing.yaml')) {
      // Key-level mutation (adds/removes a YAML key) = high
      const keyMutation = /^[+-][a-zA-Z_][a-zA-Z0-9_]*:/m
      if (keyMutation.test(change || '')) return 'high'
      return 'low'  // only numeric value changes
    }
    return 'high'  // routing-change on unknown target
  }
  if (kind === 'prompt-tweak') return 'low'
  return 'high'  // fail-safe default
}

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
        kind: { type: 'string', enum: ['prompt-tweak', 'routing-change', 'skill-promote', 'negative-memory', 'cross-repo-pattern', 'other'] },
        target: { type: 'string' }, change: { type: 'string' }, rationale: { type: 'string' },
        diff_patch: { type: 'string' },
      }, required: ['kind', 'target', 'change'] } },
    summary_for_lead: { type: 'string' },
  }, required: ['proposals', 'summary_for_lead'],
}

phase('Gather')
const patterns = await agent(
  `Aggregate the leadv2 learning signals. Steps:\n` +
  `1. Run: bash .claude/scripts/leadv2-signatures-aggregate.sh (if present) and read its output.\n` +
  `2. Read all docs/handoff/*/review-signature.md lines (verdict/blocking/dims).\n` +
  `3. Read docs/leadv2/reflect-history.yaml (if present) — this contains per-close reflect entries (patterns, failure_classes, lessons). It is the PRIMARY accumulated signal source (680+ lines). Parse each entry\'s failure_class, pattern, and lesson fields.\n` +
  `4. Read docs/leadv2/immune-patterns.yaml (or .claude immune store) if present.\n` +
  `Combine signals from BOTH review-signature.md files AND reflect-history.yaml entries. ` +
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
  `or negative-memory entry. Be specific (name the file/skill). Include a diff_patch (unified diff string) ` +
  `when the change can be expressed as a deterministic file patch — required for shadow-apply. ` +
  `Then WRITE the proposal to ${OUT} as a governance markdown ` +
  `(status: pending — NOT auto-applied; founder or auto-approve decides). Return the proposals[].`,
  { label: 'propose', phase: 'Propose', model: 'sonnet', schema: PROPOSAL_SCHEMA })

// ── Shadow-Emit phase (D3 / G3c) ─────────────────────────────────────────────
// Emit proposals with risk_level to docs/leadv2/shadow/proposals/<id>.yaml.
// NOT to learning-proposals/ — D10 state separation (pending state lives here).
// Guard: LEADV2_SHADOW_ON_CLOSE=1 required (D6 backward-compat).

phase('Shadow-Emit')
const shadowProposals = []
const projRoot = (typeof process !== 'undefined' && process.env && process.env.LEADV2_PROJECT_ROOT) || '.'
const shadowOnClose = (typeof process !== 'undefined' && process.env && process.env.LEADV2_SHADOW_ON_CLOSE) === '1'

for (const p of proposal.proposals) {
  const riskLevel = classifyRisk(p.kind, p.target, p.change)
  const diffPatch = (p.diff_patch || '').trim()

  if (!diffPatch) {
    log(`Shadow-Emit: skipping ${p.kind}:${p.target} -- no diff_patch`)
    shadowProposals.push({ kind: p.kind, target: p.target, risk_level: riskLevel, status: 'skipped_no_patch' })
    continue
  }

  if (!shadowOnClose || !TASK_ID) {
    log(`Shadow-Emit: LEADV2_SHADOW_ON_CLOSE not set -- skipping emit for ${p.kind}:${p.target} (risk=${riskLevel})`)
    shadowProposals.push({ kind: p.kind, target: p.target, risk_level: riskLevel, status: 'dry_skip' })
    continue
  }

  // Emit via bash+python3: sha1(task_id+kind+target_file) = id; arm=hash(task_id)%2 (D4).
  // before_snapshot = path template (written by shadow-apply.sh --promote at apply time, D7).
  const EMIT_SCRIPT = `${projRoot}/.claude/scripts/_lv2_shadow_emit.py`
  const proposalId = await bash(
    `python3 "${projRoot}/.claude/scripts/lv2-shadow-emit.py" ` +
    `"${TASK_ID}" "${p.kind}" "${p.target}" "${riskLevel}" "${projRoot}" ` +
    `"${diffPatch.replace(/\\/g, '\\\\').replace(/"/g, '\\"').replace(/\n/g, '\\n')}" 2>/dev/null || true`
  ).then(out => (out||'').trim()).catch(()=>'')

  if (proposalId && /^[0-9a-f]{40}$/.test(proposalId)) {
    shadowProposals.push({ id: proposalId, kind: p.kind, target: p.target, risk_level: riskLevel })
    log(`Shadow-Emit: emitted ${proposalId} kind=${p.kind} risk=${riskLevel}`)
  } else {
    log(`Shadow-Emit: emit failed for ${p.kind}:${p.target}`)
    shadowProposals.push({ kind: p.kind, target: p.target, risk_level: riskLevel, status: 'emit_failed' })
  }
}

return {
  label: LABEL, proposal_path: OUT,
  recurring_signals: safePatterns.recurring.length,
  proposals_count: proposal.proposals.length,
  proposals: proposal.proposals.map(p => ({ kind: p.kind, target: p.target })),
  shadow_proposals: shadowProposals,
  shadow_emitted: shadowProposals.filter(sp => sp.id).length,
}
