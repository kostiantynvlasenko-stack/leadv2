export const meta = {
  name: 'leadv2-audit',
  description: 'PE-domain dual-mode audit workflow. mode=personas: haiku collects audit-personas.sh --json rows, parallel sonnet judges each breach with evidence, optional developer fix + haiku re-probe. mode=pages: per-page 3-role parallel (QA/PO/Designer) against 7 criteria, merge fix_items, haiku writes vision-report.md.',
  whenToUse: 'Lead invokes for systematic domain audits. mode=personas for persona-engine health invariants. mode=pages for UI page punch-list. Returns structured counts + confirmed/fixed lists.',
  phases: [
    { title: 'Collect', detail: 'mode=personas: haiku runs audit-personas.sh --json; mode=pages: parallel 3-role sonnet per page' },
    { title: 'Judge', detail: 'mode=personas: parallel sonnet judges each breach row with evidence; mode=pages: merge+dedupe fix_items in JS' },
    { title: 'Fix', detail: 'mode=personas only, if a.fix===true: developer sonnet per confirmed-real breach (cap 4), haiku re-probe to confirm' },
    { title: 'Report', detail: 'mode=pages: haiku writes vision-report.md' },
  ],
}

let a
if (typeof args === 'string') { try { a = JSON.parse(args) } catch { a = { problem: args } } }
else { a = args }
a = a || {}
if (a.probe) return { probe_ok: true, parsed_args: a }

const GLM_OK = (a && a.glmInWorkflows) !== false
async function glmBuild(missionText, label, phase) {
  const r = await agent(
    `You are a GLM dispatch driver. Steps: (1) write the mission below to a temp file; (2) run: ~/.claude/scripts/glm-coder.sh run <tempfile> (blocking; read the script's usage first with head -40 if unsure of arg order); (3) report. Return JSON {glm_ok: boolean, summary: string (<=80 words), out_file: string}. glm_ok=false if the script is missing, exits non-zero, or produced no edits.\n---MISSION---\n${missionText}`,
    { model: 'haiku', effort: 'low', label, phase,
      schema: { type: 'object', properties: { glm_ok: {type:'boolean'}, summary: {type:'string'}, out_file: {type:'string'} }, required: ['glm_ok','summary'] } }
  )
  return r
}

const MODE = a.mode || 'personas'
const REPO_DIR = a.repoDir || '.'
const MAX_JUDGE = typeof a.maxJudge === 'number' ? a.maxJudge : 8

// ── C3: Ledger emit helper ────────────────────────────────────────────────────
// WORKFLOW-BASH-FIX-01 (Move 2): runtime provides no bash() global. Accumulate
// events in-memory (pushLedger, sync, no I/O) and flush ONCE via a single agent()
// call right before each return, instead of one bare bash() per event.
// NOTE: defined here at top level (not inside the mode=personas/mode=pages blocks
// below) so BOTH mode branches can call push/flushLedger -- the old `emitLedger`
// was declared inside the `if (MODE === 'personas')` block only, which meant it
// was out of scope (ReferenceError) for the mode=pages branch's call sites.
const ledgerEvents = []
function pushLedger(event, extra) {
  const _taskId = (typeof TASK_ID !== 'undefined' ? TASK_ID : null) || (typeof a !== 'undefined' && a.task_id) || 'unknown'
  ledgerEvents.push(Object.assign({ event, task_id: _taskId }, extra || {}))
}
async function flushLedger(phaseLabel) {
  if (ledgerEvents.length === 0) return
  const _root = (typeof process !== 'undefined' && process.env && process.env.LEADV2_PROJECT_ROOT) || '.'
  try {
    await agent(
      `Append each of the following ${ledgerEvents.length} JSON objects as its own line to the ledger, ` +
      `one at a time and in order, via this exact command per event (substitute <event-json> with the ` +
      `object, verbatim -- it is already valid JSON, do not reformat or re-derive it):\n` +
      `_EMIT="${_root}/.claude/scripts/lv2-ledger-emit.py"; [ -f "$_EMIT" ] || _EMIT="$HOME/.claude/scripts/lv2-ledger-emit.py"; python3 "$_EMIT" '<event-json>' 2>/dev/null || true\n` +
      `Events (in order): ${JSON.stringify(ledgerEvents)}\n` +
      `Return "flushed:<n>" where n is the number of events processed.`,
      { label: 'ledger-flush', phase: phaseLabel || 'Close', model: 'haiku', effort: 'low' })
  } catch (_) { /* fire-and-forget, never blocks task_close */ }
}

// ─── MODE: personas ───────────────────────────────────────────────────────────

if (MODE === 'personas') {
  const ROWS_SCHEMA = {
    type: 'object', additionalProperties: false,
    properties: {
      rows: {
        type: 'array',
        items: {
          type: 'object', additionalProperties: false,
          properties: {
            persona_id: { type: 'string' },
            invariant: { type: 'string' },
            status: { type: 'string' },
            l2: {},
            l1: {},
            delta: {},
            threshold: { type: 'string' },
          },
          required: ['persona_id', 'invariant', 'status'],
        },
      },
    },
    required: ['rows'],
  }

  const JUDGE_SCHEMA = {
    type: 'object', additionalProperties: false,
    properties: {
      real: { type: 'boolean' },
      root_cause: { type: 'string' },
      evidence: { type: 'string' },
      fix_hint: { type: 'string' },
    },
    required: ['real', 'root_cause', 'evidence', 'fix_hint'],
  }

  const REPROBE_SCHEMA = {
    type: 'object', additionalProperties: false,
    properties: {
      rows: {
        type: 'array',
        items: {
          type: 'object', additionalProperties: false,
          properties: {
            persona_id: { type: 'string' },
            invariant: { type: 'string' },
            status: { type: 'string' },
          },
          required: ['persona_id', 'invariant', 'status'],
        },
      },
    },
    required: ['rows'],
  }

  phase('Collect')

  pushLedger('phase_enter', { phase: 'Collect' })
  const collectResult = await agent(
    `Run the persona audit collect step in the repo at ${REPO_DIR}.
Execute: bash scripts/audit-personas.sh --json
Capture the stdout (JSON array of invariant rows). Return it verbatim as rows[].
Each row has: persona_id, invariant, status (pass/breach/unknown), l2, l1, delta, threshold.
If the script fails or returns empty, return rows: [].`,
    { label: 'collect', phase: 'Collect', model: 'haiku', effort: 'low', schema: ROWS_SCHEMA })

  const allRows = (collectResult && collectResult.rows) || []
  const breachRows = allRows.filter(r => r.status === 'breach').slice(0, MAX_JUDGE)
  log(`Collect: ${allRows.length} rows, ${breachRows.length} breaches (cap ${MAX_JUDGE})`)

  phase('Judge')

  pushLedger('phase_enter', { phase: 'Judge' })
  const judgeResults = breachRows.length > 0
    ? (await parallel(breachRows.map(row => () => agent(
        `You are diagnosing a persona-engine invariant breach. Provide evidence-backed judgment.
Persona: ${row.persona_id}
Invariant: ${row.invariant}
Status: ${row.status}
L2 (external): ${row.l2 !== undefined ? JSON.stringify(row.l2) : 'n/a'}
L1 (internal): ${row.l1 !== undefined ? JSON.stringify(row.l1) : 'n/a'}
Delta: ${row.delta !== undefined ? row.delta : 'n/a'}
Threshold: ${row.threshold || 'n/a'}

Investigate with evidence:
- Read relevant log files, DB state, or probe output for this invariant
- Cite the specific file path or Supabase query that confirms or refutes the breach
- Common invariants: throughput (check action_log vs graph_media), auth (check cookies.enc + token_valid), cycle (check engine_sessions), pillar_drift (check pillar_drift probe)

Return: real (true=confirmed bug, false=probe artifact/race condition), root_cause (one sentence), evidence (file:line or query result), fix_hint (one sentence).`,
        { label: `judge:${row.persona_id}:${row.invariant}`, phase: 'Judge', model: 'sonnet', effort: 'high', schema: JUDGE_SCHEMA })
        .then(v => ({ row, verdict: v }))
    ))).filter(Boolean)
    : []

  const confirmed = judgeResults.filter(r => r.verdict && r.verdict.real)
  const unknown = judgeResults.filter(r => !r.verdict || r.verdict.real === undefined)
  log(`Judge: ${confirmed.length} confirmed, ${unknown.length} unknown`)

  let fixed = []

  if (a.fix === true && confirmed.length > 0) {
    phase('Fix')
    pushLedger('phase_enter', { phase: 'Fix' })
    const fixCandidates = confirmed.slice(0, 4)

    const fixResults = (await parallel(fixCandidates.map(item => async () => {
      const missionText = `You are a developer fixing a confirmed persona-engine bug.
Persona: ${item.row.persona_id}
Invariant: ${item.row.invariant}
Root cause: ${item.verdict.root_cause}
Evidence: ${item.verdict.evidence}
Fix hint: ${item.verdict.fix_hint}

Apply a minimal-diff fix. Read the relevant file(s) first. Do NOT commit.
Return a one-sentence summary of what you changed.`
      const label = `fix:${item.row.persona_id}:${item.row.invariant}`
      if (GLM_OK) {
        const g = await glmBuild(missionText, label, 'Fix')
        if (g && g.glm_ok) return g.summary
        log(`glmBuild fallback: GLM unavailable for ${label}`)
      }
      return agent(missionText, { label, phase: 'Fix', model: 'sonnet', effort: 'medium' })
    }))).filter(Boolean)

    const reprobeResult = await agent(
      `Re-run the persona audit for the specific invariants that were just fixed.
In repo at ${REPO_DIR}, run: bash scripts/audit-personas.sh --json
Then filter for these persona+invariant pairs:
${fixCandidates.map(i => `  ${i.row.persona_id} / ${i.row.invariant}`).join('\n')}
Return only those matching rows as rows[].`,
      { label: 'reprobe', phase: 'Fix', model: 'haiku', effort: 'low', schema: REPROBE_SCHEMA })

    const reprobeRows = (reprobeResult && reprobeResult.rows) || []
    fixed = fixCandidates.map((item, idx) => {
      const reprobe = reprobeRows.find(r => r.persona_id === item.row.persona_id && r.invariant === item.row.invariant)
      return {
        persona_id: item.row.persona_id,
        invariant: item.row.invariant,
        reprobe_status: reprobe ? reprobe.status : 'unknown',
        fix_summary: fixResults[idx] || null,
      }
    })
  }

  pushLedger('task_close', { phase: 'Fix', confirmed: confirmed.length, fixed: fixed.length })
  await flushLedger('Fix')

  return {
    rows_total: allRows.length,
    breaches: breachRows.length,
    confirmed: confirmed.map(r => ({
      persona_id: r.row.persona_id,
      invariant: r.row.invariant,
      root_cause: r.verdict.root_cause,
      evidence: r.verdict.evidence,
      fix_hint: r.verdict.fix_hint,
    })),
    fixed,
    unknown: unknown.map(r => ({
      persona_id: r.row.persona_id,
      invariant: r.row.invariant,
      note: r.verdict ? r.verdict.root_cause : 'judge returned no verdict',
    })),
  }
}

// ─── MODE: pages ──────────────────────────────────────────────────────────────

if (MODE === 'pages') {
  const PAGES = (a.pages || []).slice(0, 10)
  const REPORT_DIR = a.reportDir || 'docs/handoff/audit'

  const PAGE_AUDIT_SCHEMA = {
    type: 'object', additionalProperties: false,
    properties: {
      verdicts: {
        type: 'array',
        items: {
          type: 'object', additionalProperties: false,
          properties: {
            role: { type: 'string' },
            criterion: { type: 'string' },
            result: { type: 'string', enum: ['PASS', 'PARTIAL', 'FAIL'] },
            note: { type: 'string' },
          },
          required: ['role', 'criterion', 'result', 'note'],
        },
      },
      fix_items: {
        type: 'array',
        items: {
          type: 'object', additionalProperties: false,
          properties: {
            prio: { type: 'string', enum: ['HIGH', 'MED', 'LOW'] },
            item: { type: 'string' },
          },
          required: ['prio', 'item'],
        },
      },
    },
    required: ['verdicts', 'fix_items'],
  }

  const CRITERIA = {
    QA: ['working', 'all-states-wired'],
    PO: ['informative', 'no-tech-jargon', 'clear'],
    Designer: ['simple', 'clear', 'beautiful'],
  }

  const CRITERIA_DESC = `
- simple: no clutter, clear hierarchy
- clear: customer language, no UUIDs/jargon, no raw JSON
- beautiful: consistent spacing, color, typography per design system
- working: no broken states, no blank sections, no spinner loops
- informative: data is meaningful, numbers make sense, labels explain units
- no-tech-jargon: no internal IDs, no snake_case labels on customer surfaces
- all-states-wired: loading, empty, error, populated states all render correctly`

  phase('Collect')

  pushLedger('phase_enter', { phase: 'Collect' })
  if (PAGES.length === 0) {
    await flushLedger('Collect')
    return { pages: 0, fail_count: 0, fix_items: [] }
  }

  const allPageResults = []
  for (const page of PAGES) {
    const roleResults = (await parallel([
      () => agent(
        `You are a QA engineer auditing the page: ${page}
Criteria to evaluate: ${CRITERIA.QA.join(', ')}
Criteria definitions: ${CRITERIA_DESC}
QA lens: working + all-states-wired — does every state render? Any broken API call, 404, console error?
Examine the page thoroughly. For each criterion: PASS (fully meets), PARTIAL (partially meets), FAIL (does not meet).
Return verdicts[] (role="QA", criterion, result, note) and fix_items[] (prio HIGH/MED/LOW, item as actionable one-liner).`,
        { label: `qa:${page}`, phase: 'Collect', model: 'sonnet', effort: 'medium', schema: PAGE_AUDIT_SCHEMA }),
      () => agent(
        `You are a Product Owner auditing the page: ${page}
Criteria to evaluate: ${CRITERIA.PO.join(', ')}
Criteria definitions: ${CRITERIA_DESC}
PO lens: informative + no-tech-jargon + clear — does the page communicate value? Would a non-technical customer understand it?
Examine the page thoroughly. For each criterion: PASS/PARTIAL/FAIL.
Return verdicts[] (role="PO", criterion, result, note) and fix_items[] (prio HIGH/MED/LOW, item as actionable one-liner).`,
        { label: `po:${page}`, phase: 'Collect', model: 'sonnet', effort: 'medium', schema: PAGE_AUDIT_SCHEMA }),
      () => agent(
        `You are a Designer auditing the page: ${page}
Criteria to evaluate: ${CRITERIA.Designer.join(', ')}
Criteria definitions: ${CRITERIA_DESC}
Designer lens: simple + clear + beautiful — spacing, hierarchy, color consistency, typography, responsiveness.
Examine the page thoroughly. For each criterion: PASS/PARTIAL/FAIL.
Return verdicts[] (role="Designer", criterion, result, note) and fix_items[] (prio HIGH/MED/LOW, item as actionable one-liner).`,
        { label: `designer:${page}`, phase: 'Collect', model: 'sonnet', effort: 'medium', schema: PAGE_AUDIT_SCHEMA }),
    ])).filter(Boolean)

    const verdicts = roleResults.flatMap(r => (r && r.verdicts) || [])
    const fixItems = roleResults.flatMap(r => (r && r.fix_items) || [])
    allPageResults.push({ page, verdicts, fixItems })
  }

  phase('Judge')

  pushLedger('phase_enter', { phase: 'Judge' })
  // Merge + dedupe fix_items across all pages in JS
  const seen = new Map()
  const PRIO_RANK = { HIGH: 3, MED: 2, LOW: 1 }
  for (const { fixItems } of allPageResults) {
    for (const f of fixItems) {
      const key = f.item.slice(0, 80).toLowerCase()
      const prev = seen.get(key)
      if (!prev || (PRIO_RANK[f.prio] || 0) > (PRIO_RANK[prev.prio] || 0)) {
        seen.set(key, f)
      }
    }
  }
  const mergedFixItems = [...seen.values()].sort((a, b) => (PRIO_RANK[b.prio] || 0) - (PRIO_RANK[a.prio] || 0))
  const failCount = allPageResults.reduce((n, { verdicts }) => n + verdicts.filter(v => v.result === 'FAIL').length, 0)

  log(`Pages: ${PAGES.length} audited, ${failCount} FAIL verdicts, ${mergedFixItems.length} deduped fix_items`)

  phase('Report')

  pushLedger('phase_enter', { phase: 'Report' })
  await agent(
    `Write a vision-report.md to ${REPORT_DIR}/vision-report.md.

Structure:
${allPageResults.map(({ page, verdicts, fixItems }) => `
## Page: ${page}

| Role | Criterion | Result | Note |
|------|-----------|--------|------|
${verdicts.map(v => `| ${v.role} | ${v.criterion} | ${v.result} | ${v.note} |`).join('\n')}

### Fix items
${fixItems.map(f => `- [ ] [${f.prio}] ${f.item}`).join('\n')}
`).join('\n')}

## All fix items (deduped, HIGH → MED → LOW)
${mergedFixItems.map(f => `- [ ] [${f.prio}] ${f.item}`).join('\n')}

Create parent directories if needed. Return "ok".`,
    { label: 'report', phase: 'Report', model: 'haiku', effort: 'low' })

  pushLedger('task_close', { phase: 'Report', pages: PAGES.length, fail_count: failCount })
  await flushLedger('Report')

  return {
    pages: PAGES.length,
    fail_count: failCount,
    fix_items: mergedFixItems,
  }
}

await flushLedger('Close')
return { error: `Unknown mode: ${MODE}. Use mode=personas or mode=pages.` }
