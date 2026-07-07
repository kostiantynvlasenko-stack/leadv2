export const meta = {
  name: 'leadv2-plan',
  description: 'leadv2 Phase 2 Plan as a workflow: capability-match classifier (haiku) → dynamic role fan-out + context envelope → synthesize into context.yaml. Model-pinned.',
  whenToUse: 'leadv2 Phase 2 for class >= Standard. Lead invokes instead of hand-rolled triad + Monitor. Returns a compact plan summary; full context.yaml written to disk.',
  phases: [
    { title: 'Classify', detail: 'haiku capability-match: pick roles from task brief + file patterns (F5)' },
    { title: 'Plan', detail: 'dynamic role fan-out + context envelope from shared-memory + solutions-archive (F8)' },
    { title: 'Synthesize', detail: 'merge into context.yaml' },
  ],
}
let a
if (typeof args === 'string') { try { a = JSON.parse(args) } catch { a = { problem: args } } }
else { a = args }
a = a || {}
const TASK_ID = a.taskId || 'adhoc'
const BRIEF = a.taskBrief || ''
const HEAVY = a.heavy === true || a.archKeyword === true
const MISSION_PATH = a.missionPath || `docs/handoff/${TASK_ID}/plan-mission.md`
const CTX = `docs/handoff/${TASK_ID}/context.yaml`
const CODEX_ON = a.codexEnabled !== false
// M-3: task_class enum passed from lead; avoids BRIEF.slice(0,50) non-match
const TASK_CLASS = a.taskClass || 'general'
// MEM-WRITE-PATH-FIX-01 round2: solutions-archive.yaml is gitignored, worktree-
// local-by-default; a bare relative read here was one of the two stale consumers
// left behind after the review.js/learn.js round-1 fix (finding #3). Anchor to the
// same durable main-repo root, marker-checked (see leadv2-review.js for rationale).
const _ARCHIVE_ROOT = (await bash(`_r="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null | xargs dirname 2>/dev/null)"; [ -n "$_r" ] && [ -d "$_r/docs/leadv2" ] && printf '%s' "$_r" || pwd`)).trim() || '.'
// [BANDIT-WIRE-01] Consume bandit model selections from args.models (set by lead before Workflow call).
// args.models absent (or LEADV2_ROUTE_BANDIT != 1) => falls back to existing pinned defaults.
// Flag-off guarantee: if args.models is not provided, model values are identical to pre-BANDIT-WIRE-01.
const _MODELS = (a.models && typeof a.models === 'object') ? a.models : {}
const ARCH_MODEL = _MODELS.architect || (HEAVY ? 'opus' : 'sonnet')
const CRITIC_MODEL = _MODELS.critic || 'sonnet'

const ARCH_SCHEMA = {
  type: 'object', additionalProperties: false,
  properties: {
    decisions: { type: 'array', items: { type: 'string' } },
    plan_steps: { type: 'array', items: { type: 'string' } },
    off_limits: { type: 'array', items: { type: 'string' } },
    risks: { type: 'array', items: { type: 'string' } },
    summary_for_lead: { type: 'string' },
  }, required: ['decisions', 'plan_steps', 'summary_for_lead'],
}
const CRITIC_SCHEMA = {
  type: 'object', additionalProperties: false,
  properties: {
    concerns: { type: 'array', items: { type: 'object', additionalProperties: false,
      properties: { severity: { type: 'string', enum: ['critical','high','medium','low'] }, concern: { type: 'string' } },
      required: ['severity','concern'] } },
    summary_for_lead: { type: 'string' },
  }, required: ['concerns', 'summary_for_lead'],
}

// [F5-CAP-MATCH] Capability-match schema: haiku classifies task → recommended_roles[]
const CAP_SCHEMA = {
  type: 'object', additionalProperties: false,
  properties: {
    recommended_roles: { type: 'array', items: { type: 'string',
      enum: ['architect', 'critic', 'developer', 'postgres-pro', 'frontend-developer',
             'devops-engineer', 'security-auditor'] } },
    task_class: { type: 'string', enum: ['schema', 'api', 'ui', 'ops', 'security', 'general'] },
    rationale: { type: 'string' },
  }, required: ['recommended_roles', 'rationale'],
}

// [F5] Phase 0: capability-match classifier — haiku, ~5s, zero extra cost
// Capability map mirrors agent frontmatter capabilities: fields.
// Fallback: if classifier returns empty/null, static triad is used (backward-compat preserved).
const STATIC_TRIAD = ['architect', 'critic']


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

phase('Classify')
await emitLedger('phase_enter', { phase: 'Classify' })
// [F8] Also read context envelope sources in parallel: shared-memory + solutions-archive
const [capResult, sharedMemRaw, archiveRaw] = await Promise.all([
  agent(
    `Classify this task to pick the right agent roles. Task brief: "${BRIEF || MISSION_PATH}". ` +
    `Available agent capabilities:\n` +
    `  architect: [schema, api-design, migration, data-flow, module-boundaries]\n` +
    `  critic: [code-review, adversarial, type-safety, test-coverage]\n` +
    `  developer: [python, async, llm-integration, bash-ops, api]\n` +
    `  postgres-pro: [sql, rls, migration, supabase, query-optimization]\n` +
    `  frontend-developer: [ui, nextjs, react, tailwind, server-actions]\n` +
    `  devops-engineer: [deploy, systemd, vps, cron, bash-scripting, ops]\n` +
    `  security-auditor: [security, auth, rls, injection, secrets, webhook]\n` +
    `Return 2-4 recommended_roles that best match the task. Always include architect for Standard+ tasks. ` +
    `Critic is optional for Light tasks. Return task_class and rationale (1 sentence).`,
    { label: 'capability-classifier', phase: 'Classify', model: 'haiku', effort: 'low', schema: CAP_SCHEMA }),
  agent(
    `Read docs/leadv2/shared-memory.yaml if it exists and return its raw text content (max 500 chars). ` +
    `If the file does not exist, return the string "EMPTY". Do not analyze, just return the content.`,
    { label: 'shared-mem-read', phase: 'Classify', model: 'haiku', effort: 'low' }),
  agent(
    `Read ${_ARCHIVE_ROOT}/docs/leadv2/solutions-archive.yaml if it exists. ` +
    `Find entries where task_class matches "${TASK_CLASS}". ` +
    `Return top-3 by score as JSON array [{task_id,score,diff_summary}] or [] if none match or file absent.`,
    { label: 'archive-read', phase: 'Classify', model: 'haiku', effort: 'low' }),
])

const recommendedRoles = (capResult && Array.isArray(capResult.recommended_roles) && capResult.recommended_roles.length > 0)
  ? capResult.recommended_roles
  : STATIC_TRIAD
log(`Classify: roles=${recommendedRoles.join(',')} class=${capResult ? capResult.task_class : 'fallback'} rationale="${capResult ? capResult.rationale : 'classifier null — static triad'}"`)

// [F8] Build context envelope (≤1500 tokens cap) from shared-memory + solutions-archive
const sharedMemSnippet = (typeof sharedMemRaw === 'string' && sharedMemRaw !== 'EMPTY')
  ? sharedMemRaw.slice(0, 600) : ''
const archiveSnippet = (typeof archiveRaw === 'string' && archiveRaw.trim() !== '[]' && archiveRaw.trim() !== '')
  ? archiveRaw.slice(0, 600) : ''
const contextEnvelope = (sharedMemSnippet || archiveSnippet)
  ? `\n\n## Context envelope (prior exemplars — use as positive examples)\n` +
    (sharedMemSnippet ? `### Shared memory (top exemplars):\n${sharedMemSnippet}\n` : '') +
    (archiveSnippet ? `### Solutions archive (matching task class):\n${archiveSnippet}\n` : '')
  : ''

phase('Plan')
await emitLedger('phase_enter', { phase: 'Plan' })
// [F5+F8] Dynamic spawns from recommended_roles + context envelope injected into architect prompt
const spawns = []
if (recommendedRoles.includes('architect')) {
  spawns.push(() => synthAgent(
    `Architect the plan for task ${TASK_ID}. Brief: ${BRIEF || MISSION_PATH}. Read ${MISSION_PATH} + the repo. ` +
    `Produce decisions[], plan_steps[] (minimal-diff oriented), off_limits[], risks[]. No code, no full-file rewrites.` +
    contextEnvelope,
    { label: 'architect', phase: 'Plan', agentType: 'architect', model: ARCH_MODEL, effort: HEAVY ? (ARCH_MODEL === 'sonnet' ? 'high' : 'xhigh') : 'medium', schema: ARCH_SCHEMA }))
}
if (recommendedRoles.includes('critic')) {
  spawns.push(() => agent(
    `Adversarially critique the proposed approach for task ${TASK_ID}. Brief: ${BRIEF || MISSION_PATH}. ` +
    `Surface concerns: hidden coupling, irreversible ops, unverifiable invariants, missing tests, scope creep. Severity-tag each.`,
    { label: 'critic', phase: 'Plan', agentType: 'critic', model: CRITIC_MODEL, effort: 'high', schema: CRITIC_SCHEMA }))
}
if (recommendedRoles.includes('postgres-pro')) {
  spawns.push(() => agent(
    `DB/schema review for task ${TASK_ID}. Brief: ${BRIEF || MISSION_PATH}. ` +
    `Check: migration sequencing, RLS policy coverage, partial-index upsert traps, N+1 risks. ` +
    `Return concerns[] (severity-tagged) + summary_for_lead.`,
    { label: 'postgres-pro', phase: 'Plan', model: 'sonnet', effort: 'high', schema: CRITIC_SCHEMA }))
}
if (recommendedRoles.includes('security-auditor')) {
  spawns.push(() => agent(
    `Security review for task ${TASK_ID}. Brief: ${BRIEF || MISSION_PATH}. ` +
    `Check: auth gaps, injection risks, RLS correctness, secret handling. ` +
    `Return concerns[] (severity-tagged) + summary_for_lead.`,
    { label: 'security-plan', phase: 'Plan', agentType: 'security-auditor', model: 'sonnet', effort: 'high', schema: CRITIC_SCHEMA }))
}
// lean: devops-engineer and frontend-developer plan-phase spawns omitted — rarely needed at Plan stage; upgrade when task_class=ops|ui is common
// [COST-LEVERS-01] Codex is the PRIMARY adversarial brain for Plan (Lever 3). Agent critic above is the fallback when CODEX_ON=false.
// Both run in parallel; Codex findings are weighted first during concern dedup (higher signal-to-token ratio).
if (CODEX_ON) {
  spawns.unshift(() => agent(
    `Run this single blocking call: bash ~/.claude/scripts/leadv2-codex-planner.sh --task-id ${TASK_ID} --mission-file "${MISSION_PATH}" --effort ${HEAVY ? 'xhigh' : 'high'} --wait. ` +
    `The --wait flag blocks until done; no polling needed. When it exits, read findings: bash ~/.claude/scripts/cx-tail.sh <output-file>. ` +
    `Return codex's plan findings as concerns[] (severity-tagged). If codex unavailable (non-zero exit), return empty with summary_for_lead="codex unavailable". Do NOT poll or loop.`,
    { label: 'codex-planner', phase: 'Plan', model: 'haiku', effort: 'low', schema: CRITIC_SCHEMA }))
}
const res = (await parallel(spawns)).filter(Boolean)
const archRaw = res.find(r => r && r.decisions)
const architectFailed = !archRaw || (archRaw.decisions.length === 0 && archRaw.plan_steps.length === 0)
const arch = archRaw || { decisions: [], plan_steps: [], off_limits: [], risks: [], summary_for_lead: '' }
const concerns = res.flatMap(r => (r && r.concerns) || [])
const blocking = concerns.filter(c => c.severity === 'critical' || c.severity === 'high')
log(`Plan: ${arch.decisions.length} decisions, ${arch.plan_steps.length} steps, ${concerns.length} concerns (${blocking.length} blocking)`)

if (architectFailed) {
  return {
    task_id: TASK_ID, context_path: CTX,
    decisions_count: 0, steps_count: 0,
    blocking_concerns: blocking.length,
    risk_summary: [],
    needs_founder_decision: true,
    architect_failed: true,
  }
}

// [AGENT-HINT-01] Deterministic agent_hint per plan step — zero extra LLM calls.
// Lookup order: SQL/migrations/RLS → postgres-pro; web/*.tsx → frontend-developer;
// auth/cookie/webhook/session/token/secret → security-auditor;
// *.sh/systemd/deploy/vps → devops-engineer; else → developer.
// Build phase consumes step.agent_hint as default subagent_type (fallback: developer).
function inferAgentHint(stepText) {
  const s = (stepText || '').toLowerCase()
  if (/\.sql$/.test(s) || /migrations\//.test(s) || /\brls\b|\bpolicy\b/.test(s)) return 'postgres-pro'
  if (/web\/.*\.tsx?$/.test(s)) return 'frontend-developer'
  if (/\b(auth|cookie|webhook|session|token|secret)\b/.test(s)) return 'security-auditor'
  if (/\.sh$/.test(s) || /\b(systemd|deploy|vps|ops)\b/.test(s)) return 'devops-engineer'
  return 'developer'
}
const annotatedSteps = arch.plan_steps.map((stepText, i) => ({
  id: i + 1, mission: stepText, agent_hint: inferAgentHint(stepText),
}))
log(`Agent hints: ${annotatedSteps.map(s => `${s.id}:${s.agent_hint}`).join(', ')}`)

phase('Synthesize')
await emitLedger('phase_enter', { phase: 'Synthesize' })
await agent(
  `Write a leadv2 context.yaml to ${CTX} merging this plan. ` +
  `decisions: ${JSON.stringify(arch.decisions)}. steps (with agent_hint per step): ${JSON.stringify(annotatedSteps)}. ` +
  `off_limits: ${JSON.stringify(arch.off_limits || [])}. risks: ${JSON.stringify(arch.risks || [])}. ` +
  `concerns: ${JSON.stringify(concerns)}. Use the standard leadv2 context.yaml shape (decisions[], off_limits[], plan.steps[], risk summary). ` +
  `Each plan.steps[i] MUST include the agent_hint field from the annotated steps above. ` +
  `Resolve any critic concern into either an off_limit or a plan step. ` +
  `ALSO emit verification.criteria[] WHEN concrete checkable criteria exist (a shell command, a judge rubric, or a human signoff). ` +
  `Keep verification.live_signal as the human description. criteria[] is OPTIONAL — omit it entirely when no concrete criteria apply. ` +
  `Each criterion: {id, type:programmatic|judge|human, expect?:exit_zero|exit_nonzero|stdout_contains, check?:argv-array, contains?:string, rubric?:string, prompt?:string}. Return "ok".`,
  { label: 'synthesize', phase: 'Synthesize', model: 'sonnet', effort: 'medium' })

const REQUIRED_FIELDS = ['id', 'mission', 'reads', 'writes', 'acceptance']
const validationResult = await agent(
  `Validate ${CTX}: run python3 -c "import yaml,sys; d=yaml.safe_load(open('${CTX}')); missing=[f for f in ["id","mission","reads","writes","acceptance"] if f not in d]; sys.stdout.write('MISSING:'+','.join(missing) if missing else 'OK')". Return {valid:true} if output is OK, else {valid:false,error:'Missing: <fields>'}.`,
  { label: 'validate-ctx', phase: 'Synthesize', model: 'haiku', effort: 'low', schema: { type: 'object', additionalProperties: false, properties: { valid: { type: 'boolean' }, error: { type: 'string' } }, required: ['valid'] } })
let validationError = null
if (validationResult && !validationResult.valid) {
  validationError = validationResult.error || 'context.yaml missing required fields'
  log(`Validation failed: ${validationError} — re-running Synthesize once`)
  await agent(
    `RETRY: context.yaml validation failed with: ${validationError}. Re-write ${CTX} ensuring required fields id, mission, reads, writes, acceptance are present. ` +
    `decisions: ${JSON.stringify(arch.decisions)}. steps (with agent_hint per step): ${JSON.stringify(annotatedSteps)}. ` +
    `off_limits: ${JSON.stringify(arch.off_limits || [])}. risks: ${JSON.stringify(arch.risks || [])}. ` +
    `concerns: ${JSON.stringify(concerns)}. Each plan.steps[i] MUST include the agent_hint field. Return "ok".`,
    { label: 'synthesize-retry', phase: 'Synthesize', model: 'sonnet', effort: 'medium' })
}

// [TASK-CLASS-PERSIST] Write task_class into context.yaml (additive, backward-compat).
// This is the source-of-truth for phase8-close.sh → learn-trigger chain.
// capResult.task_class wins if present; fallback to args.taskClass (M-3 enum); else 'general'.
const resolvedTaskClass = (capResult && capResult.task_class) || TASK_CLASS || 'general'
try {
  // [TASK-CLASS-PERSIST] Serialize under per-task .context.lock (same lock used by context-prune.sh).
  // Uses flock --exclusive --timeout 10 (command form: flock LOCKFILE cmd) + temp+os.replace
  // atomic write + yaml.safe_dump. _ctxDir is resolved in JS (no shell subshell) so _lockFile
  // equals exactly $(dirname "$CTX")/.context.lock as used by context-prune.sh.
  const _ctxDir = CTX.includes('/') ? CTX.substring(0, CTX.lastIndexOf('/')) : '.'
  const _lockFile = `${_ctxDir}/.context.lock`
  await bash(
    `touch '${_lockFile}' 2>/dev/null || true
flock --exclusive --timeout 10 '${_lockFile}' python3 - <<'__PYEOF__'
import yaml, sys, os, tempfile, pathlib
p = pathlib.Path('${CTX}')
if not p.exists():
    print('context.yaml not found — task_class not persisted', file=sys.stderr)
    sys.exit(0)
d = yaml.safe_load(p.read_text()) or {}
d['task_class'] = '${resolvedTaskClass}'
ctx_dir = str(p.parent)
fd, tmp = tempfile.mkstemp(dir=ctx_dir, suffix='.ctx.tmp')
try:
    with os.fdopen(fd, 'w', encoding='utf-8') as tf:
        tf.write(yaml.safe_dump(d, default_flow_style=False, allow_unicode=True, width=120))
        tf.flush()
        os.fsync(tf.fileno())
    os.replace(tmp, str(p))
except Exception:
    try:
        os.unlink(tmp)
    except OSError:
        pass
    raise
print('task_class persisted: ${resolvedTaskClass}')
__PYEOF__
`
  )
} catch (_) { /* non-blocking — task_class defaults to general at learn time */ }

return {
  task_id: TASK_ID, context_path: CTX,
  decisions_count: arch.decisions.length, steps_count: arch.plan_steps.length,
  agent_hints: annotatedSteps.map(s => ({ id: s.id, agent_hint: s.agent_hint })),
  blocking_concerns: blocking.length,
  risk_summary: (arch.risks || []).slice(0, 3),
  needs_founder_decision: blocking.length > 0,
  recommended_roles: recommendedRoles,
  task_class: resolvedTaskClass,
  architect_failed: undefined,
  validation_error: validationError || undefined,
}
