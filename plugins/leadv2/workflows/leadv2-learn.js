export const meta = { // MUST be first statement — runtime rejects file otherwise
  name: 'leadv2-learn',
  description: 'Learning-aggregation workflow: consume accumulated review/plan signatures + immune patterns, detect recurring failure modes, propose concrete tuning (prompts/routing/skill-promotion). Writes a GOVERNANCE proposal — never auto-applies. Model-pinned.',
  whenToUse: 'Periodically or at Phase 8 Close. Turns per-task signatures into compounding system improvement ("the system gets smarter"). Founder/auto-approve applies proposals.',
  phases: [
    { title: 'Gather', detail: 'aggregate signals + read rejected-edits (fan-out: signal-counter + rejected-reader in parallel)' },
    { title: 'Propose', detail: 'recurring-pattern → concrete tuning proposal (only if count >= LEADV2_SKILL_SYNTH_THRESHOLD)' },
    { title: 'Shadow-Emit', detail: 'classify risk_level + emit shadow proposals to docs/leadv2/shadow/proposals/' },
  ],
}

let a
if (typeof args === 'string') { try { a = JSON.parse(args) } catch { a = { problem: args } } }
else { a = args }
a = a || {}
const LABEL = a.label || 'latest'
const TASK_ID = a.task_id || ''
const OUT = `docs/leadv2/learning-proposals/${LABEL}.md`
// C-1: task_class from args; avoids undefined cap-result reference
const TASK_CLASS = a.task_class || 'general'
// H-1: single init-time timestamp — replay-safe on workflow resume.
// Workflow runtime throws on Date.now()/argless new Date() — derive stamp via bash() instead.
const TS = a.ts || (await bash("date -u +%Y-%m-%dT%H:%M:%SZ")).trim()

// ── C3: Ledger emit helper ────────────────────────────────────────────────────
// Defined AFTER const declarations so TASK_ID is initialized before this closure captures it.
// Fire-and-forget: never throws, never blocks workflow on failure.
async function emitLedger(event, extra) {
  const ev = Object.assign({ event, task_id: TASK_ID || 'unknown' }, extra || {})
  const projRoot = (typeof process !== 'undefined' && process.env && process.env.LEADV2_PROJECT_ROOT) || '.'
  try {
    await bash(
      `_EMIT="${projRoot}/.claude/scripts/lv2-ledger-emit.py"; [ -f "$_EMIT" ] || _EMIT="$HOME/.claude/scripts/lv2-ledger-emit.py"; python3 "$_EMIT" '${JSON.stringify(ev).replace(/'/g, "'\\''")}' 2>/dev/null || true`
    )
  } catch (_) { /* fire-and-forget */ }
}

// ── B1: SkillOpt threshold (LEADV2_SKILL_SYNTH_THRESHOLD) ────────────────────
// Env var already defined in settings.json. This wires it mechanically.
// Default 3 matches the design spec. Gather fan-out counts signals by class-key;
// only passes to Propose when count >= threshold. Sub-threshold signals accumulate
// in docs/leadv2/signal-accumulator.yaml across task closes.
const SYNTH_THRESHOLD = parseInt(
  (typeof process !== 'undefined' && process.env && process.env.LEADV2_SKILL_SYNTH_THRESHOLD) || '3',
  10
)

// ── Risk classification rules (D3 / G3c) ─────────────────────────────────────
// Encoded constants — NOT runtime heuristics. Resolves C-critical-2 / R9.
const HIGH_RISK_KINDS = new Set(['skill-promote', 'negative-memory', 'cross-repo-pattern', 'other'])
const DEPLOY_SAFETY_PATTERNS = [/deploy/i, /safety[_-]gate/i, /guard/i, /scorecard/i]

/** classifyRisk — enumerated rules (D3). Returns 'low' | 'high'. */
function classifyRisk(kind, target, change) {
  if (HIGH_RISK_KINDS.has(kind)) return 'high'
  for (const pat of DEPLOY_SAFETY_PATTERNS) { if (pat.test(target)) return 'high' }
  if (kind === 'routing-change') {
    if (target.includes('routing.yaml')) {
      const keyMutation = /^[+-][a-zA-Z_][a-zA-Z0-9_]*:/m
      if (keyMutation.test(change || '')) return 'high'
      return 'low'
    }
    return 'high'
  }
  if (kind === 'prompt-tweak') return 'low'
  return 'high'
}

const PATTERNS_SCHEMA = {
  type: 'object', additionalProperties: false,
  properties: {
    recurring: { type: 'array', items: { type: 'object', additionalProperties: false,
      properties: {
        signal: { type: 'string' }, count: { type: 'number' }, where: { type: 'string' },
        class_key: { type: 'string' },  // B1: "{phase}:{task_class}:{agent_role}:{failure_mode}"
      },
      required: ['signal', 'count'] } },
    revise_rate: { type: 'string' },
    summary_for_lead: { type: 'string' },
  }, required: ['recurring', 'summary_for_lead'],
}

// B1: schema for rejected-edits reader — returns list of rejection keys to filter
const REJECTED_SCHEMA = {
  type: 'object', additionalProperties: false,
  properties: {
    rejected_keys: { type: 'array', items: { type: 'string' } },
    rejected_count: { type: 'number' },
    summary_for_lead: { type: 'string' },
  }, required: ['rejected_keys', 'rejected_count', 'summary_for_lead'],
}

// B2: schema for solutions-archive exemplar reader
const EXEMPLAR_SCHEMA = {
  type: 'object', additionalProperties: false,
  properties: {
    exemplars: { type: 'array', items: { type: 'object', additionalProperties: false,
      properties: {
        task_id: { type: 'string' }, task_class: { type: 'string' },
        score: { type: 'number' }, diff_summary: { type: 'string' },
      }, required: ['task_id', 'task_class', 'score'] } },
    summary_for_lead: { type: 'string' },
  }, required: ['exemplars', 'summary_for_lead'],
}

const PROPOSAL_SCHEMA = {
  type: 'object', additionalProperties: false,
  properties: {
    proposals: { type: 'array', items: { type: 'object', additionalProperties: false,
      properties: {
        kind: { type: 'string', enum: ['prompt-tweak', 'routing-change', 'skill-promote', 'negative-memory', 'cross-repo-pattern', 'other'] },
        target: { type: 'string' }, change: { type: 'string' }, rationale: { type: 'string' },
        diff_patch: { type: 'string' },
        class_key: { type: 'string' },  // B1: for threshold tracking
      }, required: ['kind', 'target', 'change'] } },
    summary_for_lead: { type: 'string' },
  }, required: ['proposals', 'summary_for_lead'],
}

// ── B3: Gather fan-out — signal-counter (haiku) + rejected-edits-reader (haiku) in parallel ──
phase('Gather')
await emitLedger('phase_enter', { phase: 'Gather', label: LABEL })
const [patterns, rejectedResult, exemplarResult] = await parallel([
  // Fan-out leg 1: signal aggregation (unchanged logic, model=haiku)
  () => agent(
    `Aggregate the leadv2 learning signals. Steps:\n` +
    `1. Run: bash .claude/scripts/leadv2-signatures-aggregate.sh (if present) and read its output.\n` +
    `2. Read all docs/handoff/*/review-signature.md lines (verdict/blocking/dims).\n` +
    `3. Read docs/leadv2/reflect-history.yaml (if present) — this contains per-close reflect entries (patterns, failure_classes, lessons). It is the PRIMARY accumulated signal source (680+ lines). Parse each entry's failure_class, pattern, and lesson fields.\n` +
    `4. Read docs/leadv2/immune-patterns.yaml (or .claude immune store) if present.\n` +
    `5. Read docs/leadv2/signal-accumulator.yaml — merge its accumulated signals (from prior below-threshold runs) into the count for each class_key.\n` +
    `Combine signals from BOTH review-signature.md files AND reflect-history.yaml entries. ` +
    `For each recurring signal, compute a class_key as "<phase>:<task_class>:<agent_role>:<failure_mode>" (use "unknown" for any unknown field). ` +
    `Identify recurring failure signals: which review dimensions recur, REVISE rate, repeated failure_classes/phases. ` +
    `Return them as recurring[] with counts and class_keys. Be factual — only what the data shows.`,
    { label: 'gather-signals', phase: 'Gather', model: 'haiku', effort: 'low', schema: PATTERNS_SCHEMA }),

  // B1 fan-out leg 2: rejected-edits reader (model=haiku)
  () => agent(
    `Read docs/leadv2/rejected-edits.md. Extract each YAML block entry (--- delimited). ` +
    `Filter to entries where rejected_at date is within the last 30 days (today is approx ${TS.slice(0,10)}). ` +
    `Return rejected_keys[] = array of class_key strings for recent rejections. ` +
    `If file does not exist or is empty, return rejected_keys=[] rejected_count=0.`,
    { label: 'gather-rejected', phase: 'Gather', model: 'haiku', effort: 'low', schema: REJECTED_SCHEMA }),

  // B2 fan-out leg 3: solutions-archive exemplar reader (model=haiku)
  () => agent(
    `Read docs/leadv2/solutions-archive.yaml. ` +
    `Group entries by task_class. For each task_class, keep only the top-K=3 entries by score (descending). ` +
    `Return those as exemplars[]. If file does not exist or solutions is empty, return exemplars=[].`,
    { label: 'gather-exemplars', phase: 'Gather', model: 'haiku', effort: 'low', schema: EXEMPLAR_SCHEMA }),
])

const safePatterns = patterns || { recurring: [], revise_rate: 'n/a', summary_for_lead: 'gather returned null' }
const safeRejected = rejectedResult || { rejected_keys: [], rejected_count: 0, summary_for_lead: 'rejected-reader null' }
const safeExemplars = exemplarResult || { exemplars: [], summary_for_lead: 'exemplar-reader null' }

// B1: filter rejected class_keys from recurring signals
const rejectedKeySet = new Set(safeRejected.rejected_keys)
const recurringFiltered = safePatterns.recurring.filter(r => {
  if (r.class_key && rejectedKeySet.has(r.class_key)) {
    log(`Gather: filtering rejected class_key=${r.class_key} (in 30-day rejection window)`)
    return false
  }
  return true
})

// B1: enforce threshold — only signals with count >= SYNTH_THRESHOLD proceed to Propose
const aboveThreshold = recurringFiltered.filter(r => r.count >= SYNTH_THRESHOLD)
const belowThreshold = recurringFiltered.filter(r => r.count < SYNTH_THRESHOLD)

log(`Gather: ${safePatterns.recurring.length} raw signals, ${safeRejected.rejected_count} recently rejected filtered, ` +
    `${aboveThreshold.length} above threshold (>=${SYNTH_THRESHOLD}), ${belowThreshold.length} below (accumulating)`)
await emitLedger('phase_exit', { phase: 'Gather', signals_raw: safePatterns.recurring.length, above_threshold: aboveThreshold.length })

// B1: persist below-threshold signals to accumulator for next cycle
if (belowThreshold.length > 0) {
  await agent(
    `Update docs/leadv2/signal-accumulator.yaml. ` +
    `For each signal in the list below, find the matching entry by class_key (or signal text if class_key absent) and increment count, or append as new entry. ` +
    `Preserve existing entries for class_keys NOT in this list. ` +
    `Remove any entry whose class_key appears in the above-threshold list (consumed). ` +
    `Signals to accumulate: ${JSON.stringify(belowThreshold)}. ` +
    `Above-threshold keys to remove: ${JSON.stringify(aboveThreshold.map(r => r.class_key || r.signal))}. ` +
    `Write the full updated YAML to docs/leadv2/signal-accumulator.yaml. Return "ok".`,
    { label: 'accumulate-signals', phase: 'Gather', model: 'haiku', effort: 'low' })
}

// Early-exit if nothing above threshold — no proposal needed this cycle
if (aboveThreshold.length === 0) {
  log(`Gather: no signals above threshold=${SYNTH_THRESHOLD} — skipping Propose. Signals accumulating.`)
  await emitLedger('task_close', { phase: 'Gather', skipped_reason: `below_threshold=${SYNTH_THRESHOLD}` })
  return {
    label: LABEL,
    recurring_signals: safePatterns.recurring.length,
    above_threshold: 0,
    below_threshold: belowThreshold.length,
    proposals_count: 0,
    proposals: [],
    shadow_proposals: [],
    shadow_emitted: 0,
    skipped_reason: `all signals below threshold=${SYNTH_THRESHOLD}`,
  }
}

// synth stages: try top model, fall back on null/error (fable sunsets ~2026-07-07)
async function synthAgent(prompt, opts = {}) {
  const chain = [...new Set([opts.model || 'fable', 'opus', 'sonnet'])]
  for (const m of chain) {
    try {
      const r = await agent(prompt, { ...opts, model: m })
      if (r !== null) return r
    } catch (e) { /* fall through */ }
    log(`synthAgent: ${m} unavailable, falling back`)
  }
  return null
}

phase('Propose')
await emitLedger('phase_enter', { phase: 'Propose', above_threshold: aboveThreshold.length })
const proposal = await synthAgent(
  `Given these recurring leadv2 signals (all have count >= ${SYNTH_THRESHOLD} — threshold enforced), propose CONCRETE, minimal tuning. ` +
  `Recurring (above threshold): ${JSON.stringify(aboveThreshold)}.\n` +
  `Top-K exemplars from solutions archive (use as positive examples — don't repeat what worked): ${JSON.stringify(safeExemplars.exemplars)}.\n` +
  `For each signal: a prompt-tweak (which mission/skill), routing-change (routing.yaml), skill-promote candidate, ` +
  `or negative-memory entry. Be specific (name the file/skill). Include a diff_patch (unified diff string) ` +
  `when the change can be expressed as a deterministic file patch — required for shadow-apply. ` +
  `Include class_key in each proposal (same as the signal's class_key) for threshold-tracking. ` +
  `Then WRITE the proposal to ${OUT} as a governance markdown ` +
  `(status: pending — NOT auto-applied; founder or auto-approve decides). Return the proposals[].`,
  { label: 'propose', phase: 'Propose', model: 'fable', effort: 'medium', schema: PROPOSAL_SCHEMA })
await emitLedger('phase_exit', { phase: 'Propose', proposals_count: (proposal && proposal.proposals) ? proposal.proposals.length : 0 })

// ── Shadow-Emit phase (D3 / G3c + C1/C2 dual-memory) ────────────────────────
phase('Shadow-Emit')
await emitLedger('phase_enter', { phase: 'Shadow-Emit', proposals_count: proposal.proposals.length })
const shadowProposals = []
const projRoot = (typeof process !== 'undefined' && process.env && process.env.LEADV2_PROJECT_ROOT) || '.'
const shadowOnClose = (typeof process !== 'undefined' && process.env && process.env.LEADV2_SHADOW_ON_CLOSE) === '1'

// ── C1: Episodic memory write ─────────────────────────────────────────────────
// Writes docs/leadv2/episodic/<task_class>/<task_id>.yaml when TASK_ID is known.
// Entry: {problem_summary, reasoning_trace, solution_summary, score, ts, task_class}
// GC: after write, if count > 50 for this class, keep top-50 by score (decay: score * 0.9^months_old).
// Worktree-safe: writes per-file path, no concurrent write contention (each task_id is unique).
// lean: reasoning_trace is a summary string (not full trace) — upgrade when trace replay is needed
if (TASK_ID && proposal && proposal.proposals && proposal.proposals.length > 0) {
  const taskClass = TASK_CLASS
  const topProposal = proposal.proposals[0]
  // Best available score: from solutions-archive exemplar for this task_id, else default 5.0
  const exemplarScore = (safeExemplars.exemplars.find(e => e.task_id === TASK_ID) || {}).score || 5.0
  await agent(
    `Write episodic memory for task ${TASK_ID}.\n` +
    `Target file: docs/leadv2/episodic/${taskClass}/${TASK_ID}.yaml\n` +
    `Create parent directories if absent (mkdir -p docs/leadv2/episodic/${taskClass}/).\n` +
    `Write this YAML content (do NOT alter field names):\n` +
    `task_id: "${TASK_ID}"\n` +
    `task_class: "${taskClass}"\n` +
    `problem_summary: "${(safePatterns.summary_for_lead || '').replace(/"/g, "'")}"\n` +
    `reasoning_trace: "${(topProposal.rationale || topProposal.change || '').slice(0, 300).replace(/"/g, "'")}"\n` +
    `solution_summary: "${(topProposal.change || '').slice(0, 200).replace(/"/g, "'")}"\n` +
    `score: ${exemplarScore}\n` +
    `ts: "${TS}"\n\n` +
    `After writing, run GC:\n` +
    `List all .yaml files in docs/leadv2/episodic/${taskClass}/. If count > 50, identify the lowest-scoring ` +
    `entries by reading each file's score field (apply decay: score * 0.9^months_old where months_old = ` +
    `(now_ms - Date.parse(ts)) / 2592000000). Keep top-50, delete the rest. ` +
    `Return "written" or "written+gc:<N>_deleted".`,
    { label: 'episodic-write', phase: 'Shadow-Emit', model: 'haiku', effort: 'low' })
  log(`Shadow-Emit: episodic entry written for task=${TASK_ID} class=${taskClass} score=${exemplarScore}`)
}

// ── C2: Shared-memory.yaml update (fixed-size k=5) ───────────────────────────
// Worktree contention: write to shared-memory.<worktree>.tmp.yaml; lead merges on Close.
// Only update when we have proposals and a TASK_ID (meaningful close signal).
// lean: worktree detection uses LEADV2_WORKTREE env var; absent = main checkout (writes canonical directly)
if (TASK_ID && proposal && proposal.proposals && proposal.proposals.length > 0) {
  const worktreeId = (typeof process !== 'undefined' && process.env && process.env.LEADV2_WORKTREE) || ''
  const sharedMemPath = worktreeId
    ? `docs/leadv2/shared-memory.${worktreeId}.tmp.yaml`
    : 'docs/leadv2/shared-memory.yaml'
  const taskClassSm = TASK_CLASS
  const topExemplarSummary = (proposal.proposals[0].change || proposal.proposals[0].rationale || '').slice(0, 150)
  const smScore = (safeExemplars.exemplars.find(e => e.task_id === TASK_ID) || {}).score || 5.0
  await agent(
    `Update shared-memory at ${sharedMemPath}.\n` +
    `Read the file if it exists. It contains a YAML list (entries: [...]) with k<=5 items, each:\n` +
    `  {task_id, task_class, top_exemplar_summary, score}\n` +
    `Add this new entry:\n` +
    `  task_id: "${TASK_ID}"\n` +
    `  task_class: "${taskClassSm}"\n` +
    `  top_exemplar_summary: "${topExemplarSummary.replace(/"/g, "'")}"\n` +
    `  score: ${smScore}\n` +
    `If the list already has 5 or more entries, drop the entry with the lowest score before adding. ` +
    `Write the full updated YAML back to ${sharedMemPath}. ` +
    `${worktreeId ? 'This is a per-worktree tmp file; lead will merge it on Close.' : 'This is the canonical shared-memory file.'} ` +
    `Return "updated:<count>_entries".`,
    { label: 'shared-mem-update', phase: 'Shadow-Emit', model: 'haiku', effort: 'low' })
  log(`Shadow-Emit: shared-memory updated at ${sharedMemPath} (worktree="${worktreeId || 'main'}")`)
}

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

await emitLedger('task_close', {
  phase: 'Shadow-Emit',
  proposals_count: proposal.proposals.length,
  shadow_emitted: shadowProposals.filter(sp => sp.id).length,
  episodic_written: !!(TASK_ID && proposal.proposals.length > 0),
})
return {
  label: LABEL, proposal_path: OUT,
  recurring_signals: safePatterns.recurring.length,
  above_threshold: aboveThreshold.length,
  below_threshold: belowThreshold.length,
  proposals_count: proposal.proposals.length,
  proposals: proposal.proposals.map(p => ({ kind: p.kind, target: p.target })),
  shadow_proposals: shadowProposals,
  shadow_emitted: shadowProposals.filter(sp => sp.id).length,
}
