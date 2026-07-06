export const meta = {
  name: 'leadv2-po-feedback-loop',
  description: 'PO feedback loop: 4-phase orchestration (Audit → Build → Verify → Iterate) for UI-heavy features. Architect-opus audits preprod vs benchmarks+baseline, parallel Sonnet developers fix by file ownership, Playwright auto-verify, up to maxRounds iteration. LOCAL-9 lessons encoded: baseline-for-comparisons P0 rule, screenshot-required for numeric/format items, FloorDelta critic trap.',
  whenToUse: 'After initial build push for class >= Standard with >= 2 .tsx UI files changed. Lead invokes with preprodUrl + taskId + designBaseline. Returns p0/p1/pass/fail counts, followups, audit_path.',
  phases: [
    { title: 'Audit', detail: 'architect(opus) Playwright walk of preprodUrl all states + mobile 375x812, compare vs benchmarks+designBaseline+modern-web; parallel critic(sonnet) checks findings for semantic traps (FloorDelta class, baseline-for-comparisons)' },
    { title: 'Build', detail: 'group P0+P1 by file, parallel developer(sonnet) agents with disjoint ownership, type-check subset, no commit' },
    { title: 'Verify', detail: 'sonnet Playwright-assert each P0/P1; numeric/format items require screenshot path' },
    { title: 'Iterate', detail: 'loop while FAIL>0 and round<=maxRounds: developer fix then re-verify; cap remaining to followups' },
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

const TASK_ID = a.taskId || 'adhoc'
const FEATURE = a.featureName || 'feature'
const PREPROD_URL = a.preprodUrl || ''
const REPO_DIR = a.repoDir || '.'
const TASK_DIR = a.taskDir || `docs/handoff/${TASK_ID}`
const DESIGN_BASELINE = a.designBaseline || 'generic modern web guidance'
const BENCHMARKS = a.benchmarks || 'top industry peers for this product domain'
const MAX_ROUNDS = typeof a.maxRounds === 'number' ? a.maxRounds : 2
const MAX_BUILD_GROUPS = typeof a.maxBuildGroups === 'number' ? a.maxBuildGroups : 4

const AUDIT_SCHEMA = {
  type: 'object', additionalProperties: false,
  properties: {
    working: { type: 'array', items: { type: 'string' } },
    findings: {
      type: 'array',
      items: {
        type: 'object', additionalProperties: false,
        properties: {
          id: { type: 'string' },
          severity: { type: 'string', enum: ['P0', 'P1', 'P2'] },
          title: { type: 'string' },
          element: { type: 'string' },
          fix: { type: 'string' },
          effort: { type: 'string', enum: ['S', 'M', 'L'] },
          file: { type: 'string' },
        },
        required: ['id', 'severity', 'title', 'element', 'fix', 'effort'],
      },
    },
    screenshots: { type: 'array', items: { type: 'string' } },
  },
  required: ['working', 'findings', 'screenshots'],
}

const CRITIC_SCHEMA = {
  type: 'object', additionalProperties: false,
  properties: {
    traps: {
      type: 'array',
      items: {
        type: 'object', additionalProperties: false,
        properties: {
          finding_id: { type: 'string' },
          issue: { type: 'string' },
        },
        required: ['finding_id', 'issue'],
      },
    },
  },
  required: ['traps'],
}

const VERIFY_SCHEMA = {
  type: 'object', additionalProperties: false,
  properties: {
    checks: {
      type: 'array',
      items: {
        type: 'object', additionalProperties: false,
        properties: {
          finding_id: { type: 'string' },
          status: { type: 'string', enum: ['PASS', 'FAIL', 'PARTIAL', 'INCONCLUSIVE'] },
          note: { type: 'string' },
          screenshot: { type: 'string' },
        },
        required: ['finding_id', 'status', 'note'],
      },
    },
  },
  required: ['checks'],
}


// ── C3: Ledger emit helper ────────────────────────────────────────────────────
async function emitLedger(event, extra) {
  const _taskId = (typeof TASK_ID !== 'undefined' ? TASK_ID : null) || (typeof a !== 'undefined' && a.task_id) || 'unknown'
  const ev = Object.assign({ event, task_id: _taskId }, extra || {})
  const _root = (typeof process !== 'undefined' && process.env && process.env.LEADV2_PROJECT_ROOT) || '.'
  try { await bash(`_EMIT="${_root}/.claude/scripts/lv2-ledger-emit.py"; [ -f "$_EMIT" ] || _EMIT="$HOME/.claude/scripts/lv2-ledger-emit.py"; python3 "$_EMIT" '${JSON.stringify(ev).replace(/'/g, "'\\''")}' 2>/dev/null || true`) } catch (_) {}
}

phase('Audit')
await emitLedger('phase_enter', { phase: 'Audit' })
const auditResults = (await parallel([
  () => agent(
    `You are a senior product-owner architect. Visit the deployed preprod URL: ${PREPROD_URL}
Use Playwright to walk ALL states of the feature: loaded, empty, error, loading, and mobile (viewport 375x812).
Walk the key user flows: entry → primary CTA → outcome.
Compare what you see against:
  - Industry benchmarks: ${BENCHMARKS}
  - Local design baseline: ${DESIGN_BASELINE}
  - Modern-web guidance: contrast ratios, touch targets >=44px, dvh viewport, loading states, ARIA labels, responsive layout.

MANDATORY baseline-for-comparisons check (LOCAL-9 lesson): any delta, percentage, ratio, or comparison column (Floor Δ, % change, vs market, since last…) MUST specify:
  1. Baseline — what value is compared against? (e.g. current_floor vs floor_at_event_time)
  2. Time semantics — is the baseline live or snapshotted at event-time?
  3. API contract — does the API expose a per-row snapshot field, or only the live aggregate?
If any of these 3 are missing for a delta/ratio column, classify that finding as P0, NOT P2.

Output schema must include: working[] (what to preserve), findings[] (P0 max 5, P1 max 6, P2 max 4; each with id, severity, title, specific element, concrete fix, effort S/M/L, file if known), screenshots[].
Also write a markdown report to ${TASK_DIR}/po-audit.md summarizing the same findings.`,
    { label: 'audit', phase: 'Audit', agentType: 'architect', model: 'opus', schema: AUDIT_SCHEMA }),
  () => agent(
    `You are an adversarial critic. You will receive the findings list from a UI audit of ${FEATURE} (${PREPROD_URL}).
Wait for the audit agent to complete, then review the findings for semantic traps (LOCAL-9 FloorDelta class).
Specifically check:
  - Any delta/percentage/ratio finding that does NOT specify baseline + time semantics + API contract → that's a trap (should be P0, not lower severity)
  - Any finding that confuses "Playwright PASS" with visual correctness for numeric formatting, axis labels, color-coding, or dual-axis layouts
  - Any finding with vague language like "improve cards" without a specific element + fix
Return traps[]: each trap references the finding_id and explains the issue in one sentence.
If no traps, return traps: [].
Read ${TASK_DIR}/po-audit.md once it exists to get the findings list.`,
    { label: 'critic-traps', phase: 'Audit', agentType: 'critic', model: 'sonnet', schema: CRITIC_SCHEMA }),
])).filter(Boolean)

const auditRaw = auditResults.find(r => r && r.findings)
const criticRaw = auditResults.find(r => r && r.traps)
const audit = auditRaw || { working: [], findings: [], screenshots: [] }
const criticTraps = (criticRaw && criticRaw.traps) || []

const p0p1 = audit.findings.filter(f => f.severity === 'P0' || f.severity === 'P1')
log(`Audit: ${audit.findings.length} findings (${p0p1.length} P0+P1), ${criticTraps.length} critic traps`)

phase('Build')
await emitLedger('phase_enter', { phase: 'Build' })
// Group P0+P1 findings by file in JS, disjoint ownership, cap at maxBuildGroups
const fileMap = new Map()
for (const f of p0p1) {
  const key = f.file || 'unknown'
  if (!fileMap.has(key)) fileMap.set(key, [])
  fileMap.get(key).push(f)
}
const fileGroups = [...fileMap.entries()].slice(0, MAX_BUILD_GROUPS)

const buildResults = fileGroups.length > 0
  ? (await parallel(fileGroups.map(([file, findings], idx) => {
      const offLimits = fileGroups.filter((_, i) => i !== idx).map(([f]) => f)
      return async () => {
        const missionText = `You are a developer fixing UI issues for task ${TASK_ID}, ${FEATURE}.
Your assigned file: ${file}
Your findings to fix:
${findings.map(f => `  [${f.severity}] ${f.id}: ${f.title} — element: ${f.element} — fix: ${f.fix} (effort: ${f.effort})`).join('\n')}

OFF-LIMITS files (owned by other agents — do NOT touch):
${offLimits.map(f => `  ${f}`).join('\n')}

Instructions:
1. Read the file(s) in your scope first.
2. Apply each fix with minimal diff.
3. Run type-check on your subset: npx tsc --noEmit (or pnpm type-check if available in ${REPO_DIR}).
4. Do NOT commit. Return a summary of changes made per finding_id.`
        const label = `build:group-${idx}`
        if (GLM_OK) {
          const g = await glmBuild(missionText, label, 'Build')
          if (g && g.glm_ok) return g.summary
          log(`glmBuild fallback: GLM unavailable for ${label}`)
        }
        return agent(missionText, { label, phase: 'Build', model: 'sonnet' })
      }
    }
  ))).filter(Boolean)
  : []

log(`Build: ${buildResults.length} groups completed`)

phase('Verify')
await emitLedger('phase_enter', { phase: 'Verify' })
let verifyResult = await agent(
  `You are a QA engineer verifying fixes for task ${TASK_ID}, ${FEATURE}.
Preprod URL: ${PREPROD_URL}

Use Playwright to assert EACH of the following P0 and P1 items:
${p0p1.map(f => `  [${f.severity}] ${f.id}: ${f.title} — element: ${f.element}`).join('\n')}

For EACH item:
- DOM presence check (page.locator(...))
- Behavior check (click → expected response/state)
- REQUIRED for numeric/format/visual items: save a screenshot to /tmp/v-${TASK_ID}-<id>.png and include the path in the screenshot field

Return checks[] with finding_id, status (PASS/FAIL/PARTIAL/INCONCLUSIVE), note, and screenshot (path or null).
PASS = element + behavior verified. FAIL = missing or broken. PARTIAL = present but degraded. INCONCLUSIVE = cannot programmatically verify (canvas charts, JS animations).`,
  { label: 'verify', phase: 'Verify', model: 'sonnet', schema: VERIFY_SCHEMA })

let checks = (verifyResult && verifyResult.checks) || []

phase('Iterate')
await emitLedger('phase_enter', { phase: 'Iterate' })
let round = 1
while (round <= MAX_ROUNDS) {
  const failedChecks = checks.filter(c => c.status === 'FAIL')
  if (failedChecks.length === 0) break

  log(`Iterate round ${round}: ${failedChecks.length} FAIL items`)
  const failedIds = new Set(failedChecks.map(c => c.finding_id))
  const failedFindings = p0p1.filter(f => failedIds.has(f.id))

  {
    const missionText = `You are a developer fixing remaining FAIL items for task ${TASK_ID}, ${FEATURE}, iteration round ${round}.
${round >= 2 ? 'ROUND 2 HINT: these items failed re-verify — investigate more deeply. Check if the selector is correct, the component is actually rendering, or if there is a Vercel cache issue. Read the relevant source files before assuming the fix was applied.' : ''}

Failed items to fix:
${failedFindings.map(f => `  [${f.severity}] ${f.id}: ${f.title} — element: ${f.element} — fix: ${f.fix}`).join('\n')}

Apply targeted minimal-diff fixes. Do NOT commit. Return summary per finding_id.`
    const label = `iterate-fix:round-${round}`
    if (GLM_OK) {
      const g = await glmBuild(missionText, label, 'Iterate')
      if (!g || !g.glm_ok) {
        log(`glmBuild fallback: GLM unavailable for ${label}`)
        await agent(missionText, { label, phase: 'Iterate', model: 'sonnet' })
      }
    } else {
      await agent(missionText, { label, phase: 'Iterate', model: 'sonnet' })
    }
  }

  const reVerify = await agent(
    `Re-verify only the previously-failed items for task ${TASK_ID}, ${FEATURE} at ${PREPROD_URL}.
Items to re-check:
${failedFindings.map(f => `  [${f.severity}] ${f.id}: ${f.title} — element: ${f.element}`).join('\n')}

For numeric/format/visual items, REQUIRED: save screenshot to /tmp/v-${TASK_ID}-r${round}-<id>.png and include path.
Return checks[] with finding_id, status, note, screenshot.`,
    { label: `iterate-verify:round-${round}`, phase: 'Iterate', model: 'sonnet', schema: VERIFY_SCHEMA })

  const reChecks = (reVerify && reVerify.checks) || []
  // Merge: update checks in place for re-verified items
  const reMap = new Map(reChecks.map(c => [c.finding_id, c]))
  checks = checks.map(c => reMap.has(c.finding_id) ? reMap.get(c.finding_id) : c)

  round++
}

const finalFail = checks.filter(c => c.status === 'FAIL')
const followups = finalFail.length > 0
  ? p0p1.filter(f => finalFail.some(c => c.finding_id === f.id))
  : []

return {
  p0: audit.findings.filter(f => f.severity === 'P0').length,
  p1: audit.findings.filter(f => f.severity === 'P1').length,
  pass: checks.filter(c => c.status === 'PASS').length,
  fail: finalFail.length,
  partial: checks.filter(c => c.status === 'PARTIAL').length,
  inconclusive: checks.filter(c => c.status === 'INCONCLUSIVE').length,
  rounds: round - 1,
  followups: followups.map(f => ({ id: f.id, severity: f.severity, title: f.title, file: f.file })),
  audit_path: `${TASK_DIR}/po-audit.md`,
  critic_traps: criticTraps,
}
