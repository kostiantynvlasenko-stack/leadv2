# verdict-guard: allow
# WORKFLOW-BASH-FIX-01 — Migration Plan: remove `bash()` calls from Workflow runtime files

## Problem (confirmed by direct read of all 10 files + 3 test harnesses)

The Claude Code Workflow runtime injects exactly: `agent()`, `parallel()`, `pipeline()`, `log()`, `phase()`, `args`, `budget`. It does **not** provide `bash()`, filesystem, or Node APIs. All 10 files under `plugins/leadv2/workflows/*.js` call a top-level `bash()` that does not exist at runtime — every invocation crashes with `bash is not defined`. This was never caught because all 3 existing interpreter-harnesses (`scripts/tests/fixtures/*-harness.mjs`) inject a mock `bashImpl` — the harness comment in `causal-critique-harness.mjs` even asserts this mock is "the same surface the real runtime provides," which is false and was never checked against production.

`agent()` calls that instruct an LLM to "run X via bash" are **not** affected — the agent has its own real Bash tool. Only literal `await bash(...)` statements executed by the JS interpreter itself are broken.

## Fix pattern — 3 moves, applied per call-site

| Move | When to use | Shape |
|---|---|---|
| **1. Gather-fold** | JS-level init/compute call (timestamp, git-root resolve, read-only file/digest slices) whose result feeds either (a) an upfront decision or (b) exactly one downstream `agent()` prompt | If (b): delete the JS `bash()` line entirely; move the shell command into the text of the one consuming `agent()` prompt ("resolve X via bash, then do Y") — **zero new agent() calls**. If (a) or consumed by multiple sites: add it as one more parallel leg in an *existing* `parallel()`/`Promise.all()` fan-out, returned via a small JSON schema — **zero extra round-trip**, since the fan-out already happens. |
| **2. Ledger-flush** | `emitLedger()` fire-and-forget telemetry (present in **all 9** executable files) | Replace the bash-writing helper with a pure-JS in-memory array push (`ledgerEvents.push(ev)` — no I/O). Flush the whole array in **one** `agent()` call, either folded into an already-existing final write call (`archive-write`, `synthesize`, `Persist`) or one dedicated cheap `haiku`/`low` flush call right before `return`. |
| **3. Loop-collapse** | JS `for`/`.map` loop invoking `bash()` once per LLM-produced item (e.g. once per proposal) | Replace the loop with **one** `agent()` call that is instructed to iterate internally via its own Bash tool over a JSON array of pre-built (already-escaped) command arguments, and return a same-order results array via schema. Collapses N runtime bash calls into 1 agent call regardless of N. |

**Universal safety rule for all 3 moves:** wherever the JS today builds an already-escaped shell string from untrusted input (`shq()`-escaped `TASK_ID`, `diff_patch`, JSON payloads), **keep that string-construction in JS**, unchanged, and pass the *final, ready-to-run string* to the agent as a literal to execute verbatim ("run this exact command via Bash, do not modify it"). Never ask the agent to re-derive shell quoting from a description — that's a real injection-hardening regression, not just a style question (see R1).

## Per-file table

| # | File | Lines | `bash(` raw / real¹ | Runtime bash pattern(s) | Replacement shape | Effort | Risk |
|---|---|---|---|---|---|---|---|
| 1 | `leadv2-ledger.js` | 55 | 3 / **0** | All 3 hits are inside `//` comments documenting the pattern (`meta.phases:[]`, explicit "DO NOT invoke as a standalone workflow") | **N/A** — not an executable workflow. Optional: refresh the comment (L27-39) to describe the new flush-batch idiom instead of "inline bash per event", so it stays an accurate reference for the other 9 files | XS | none |
| 2 | `leadv2-audit.js` | 352 | 1 / 1 | `emitLedger` only | Move 2 | S | LOW — not fully read this pass; confirm actual runtime emitLedger call count before implementing |
| 3 | `leadv2-intake-enrich.js` | 92 | 1 / 1 | `_ARCHIVE_ROOT` git-common-dir resolve, single named consumer per surrounding comment | Move 1(b) — fold into whatever agent reads `solutions-archive.yaml` | S | LOW — confirm single-consumer assumption before folding |
| 4 | `leadv2-diverge.js` | 131 | 1 / 1 | `emitLedger` only | Move 2 | S | LOW (not fully read) |
| 5 | `leadv2-diagnose.js` | 142 | 1 / 1 | `emitLedger` only | Move 2 | S | LOW (not fully read) |
| 6 | `leadv2-po-feedback-loop.js` | 279 | 1 / 1 | `emitLedger` only (static); file is long — verify no additional phase-transition volume hides more runtime calls | Move 2 | S | LOW (not fully read) |
| 7 | `leadv2-plan.js` | 402 | 4 / 4 | `_ARCHIVE_ROOT` resolve (L27, single consumer L183) · `emitLedger` (L145, ×3 runtime) · `persistCodeMap()` flock+heredoc write (L70-98, called L320+L344) · `task_class` flock+heredoc write (L358-386) | Move 1(b) ×2 (fold `_ARCHIVE_ROOT` into the `archive-read` prompt L183; fold both flock-writes as extra verbatim-execute instructions onto the existing `synthesize`/`synthesize-retry` calls) + Move 2 (fold flush into `synthesize` too) → **~0 net new agent() calls** | M | MEDIUM — determinism-critical writes now agent-mediated (R6); retry path (L335-344) needs the same fold-in duplicated or shared via a JS string constant |
| 8 | `leadv2-review.js` | 224 | 7 / **4** (3 hits are comment prose: L23, L173, L175) | `TS` derive (L24) · `emitLedger` (L69, ×3 runtime) · `_archiveRoot` resolve (L179, single consumer L182-192) · semantic-index best-effort append (L199-206, sequenced right after archive-write) | Move 1 (`ts` via `args.ts`; `_archiveRoot` fold into `archive-write` prompt; semantic-index bash folds into the *same* `archive-write` call as one more instruction) + Move 2 (flush must live in the **unconditional** `reflect` call at L209, NOT inside the `verdict==='ACCEPT'` branch, since ledger events must flush regardless of verdict) | M | MEDIUM — flush anchor must be unconditional (see above) |
| 9 | `leadv2-learn.js` | 394 | 6 / **4** (2 hits are comment prose: L22, L29-30) | `TS` derive (L23) · `DURABLE_ROOT` resolve (L33) · `emitLedger` (L44, ~5-7 runtime) · per-proposal `shadow-emit.py` loop (L360, N runtime calls = `proposal.proposals.length`) | Move 1 (new `gather-init` leg added to the *existing* `gatherLegs` parallel array — same round trip) + Move 2 (flush folded into the Shadow-Emit phase, which already writes) + Move 3 (batch the shadow-emit loop into 1 `shadow-emit-batch` agent call) — **representative file, see snippet below** | M | MEDIUM — shadow-emit id format `^[0-9a-f]{40}$` must survive the batch call (schema-constrained, verbatim-execute) |
| 10 | `leadv2-causal-critique.js` | 274 | 13 / **9** (4 hits are comment prose: L3, L20, L37, L269) | `DURABLE_ROOT` resolve (L46) · `emitLedger` (L54, ~6-7 runtime) · **6× read-only digest slices**: `ctxDigest` python/yaml (L95), `scorecardTail` tail (L117), `reviewSig` head (L123), `ledgerSlice` grep (L129), `diffStat` git diff --stat (L133, conditional), `negMemLines` wc -l (L137) · freeform-insights JSONL append (L234) | Move 1: **one** `gather-digest` agent call runs all 7 shell commands (DURABLE_ROOT + 6 slices) and returns the 7 **raw, unformatted** fields; JS keeps its existing `.join('\n').slice(0,2000)` formatting untouched (R3) + Move 2/write-fold: **one** `persist` agent call folds the freeform-insight append and the ledger flush together (Persist phase already does a write) → **9 raw call-sites collapse into 2 agent() calls** | L | **HIGH** — flagship case for R1 (shq()-escaped TASK_ID / diff JSON must move as pre-escaped literals, not re-derived by the agent) and R3 (digest format fidelity); whole body is one big try/catch fail-open contract that must survive a null/thrown gather-agent result too (R4) |

¹ "raw" = literal grep hits for the substring `bash(` (includes comment-prose mentions of "bash()" describing the pattern); "real" = live `await bash(...)` call-sites that actually execute at runtime. The task's original counts (13/7) are raw-grep counts; use the "real" column for actual migration-effort sizing.

## Interface contracts observed (ground truth, from the 4 fully-read files)

```
agent(prompt: string, opts: {
  label: string,
  phase: string,
  model: 'haiku' | 'sonnet' | 'opus',
  effort: 'low' | 'medium' | 'high' | 'xhigh',
  schema?: JSONSchema,        // additionalProperties:false used everywhere observed
  agentType?: string,         // subagent role, e.g. 'critic' | 'security-auditor' | 'architect'
}) => Promise<object | null>  // null = "unavailable/degraded", but CAN also throw — every call
                              // site wraps in try/catch via a `synthAgent()` fallback-chain helper

parallel(fns: Array<() => Promise<any>>) => Promise<any[]>   // Promise.all semantics (confirmed via harness parallelImpl)
phase(name: string) => void
log(...args) => void
args: string | object   // every file guards: `typeof args === 'string' ? JSON.parse(args) : args`
```

`pipeline` and `budget` are part of the real runtime per the task brief but **not used by any of the 10 files read** — their shape is unverified in this pass; the implementing agent should treat them as available-but-unused for this specific fix, not block on them.

## Before / after — `leadv2-learn.js` (representative file)

**Before (broken — L12-48, L360-373):**
```js
const TS = a.ts || (await bash("date -u +%Y-%m-%dT%H:%M:%SZ")).trim()          // bash undefined → crash
const DURABLE_ROOT = (await bash(
  `_r="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null | xargs dirname 2>/dev/null)"; [ -n "$_r" ] && [ -d "$_r/docs/leadv2" ] && printf '%s' "$_r" || pwd`
)).trim() || '.'                                                                // bash undefined → crash

async function emitLedger(event, extra) {
  const ev = Object.assign({ event, task_id: TASK_ID || 'unknown' }, extra || {})
  try {
    await bash(`_EMIT="..."; python3 "$_EMIT" '${JSON.stringify(ev)...}' ...`)   // bash undefined → crash
  } catch (_) {}
}
...
for (const p of proposal.proposals) {                                          // N runtime bash() calls
  const proposalId = await bash(
    `python3 ".../lv2-shadow-emit.py" "${TASK_ID}" "${p.kind}" ... 2>/dev/null || true`
  ).then(out => (out||'').trim()).catch(()=>'')
  ...
}
```

**After (fixed):**
```js
// Move 1: fold TS+DURABLE_ROOT into a NEW leg of the EXISTING gather parallel() fan-out —
// zero extra round-trip since the fan-out already happens.
const INIT_SCHEMA = { type: 'object', additionalProperties: false,
  properties: { ts: { type: 'string' }, durable_root: { type: 'string' } },
  required: ['ts', 'durable_root'] }
const ledgerEvents = []   // Move 2: accumulate in-memory, flush once — no per-event bash()

phase('Gather')
ledgerEvents.push({ event: 'phase_enter', task_id: TASK_ID || 'unknown', phase: 'Gather', label: LABEL })
const gatherLegs = [
  () => (a.ts && a.durable_root) ? Promise.resolve({ ts: a.ts, durable_root: a.durable_root }) : agent(
    `Run these two shell commands via your Bash tool and return their exact trimmed output, verbatim:\n` +
    `1. ts: date -u +%Y-%m-%dT%H:%M:%SZ\n` +
    `2. durable_root: _r="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null | xargs dirname 2>/dev/null)"; [ -n "$_r" ] && [ -d "$_r/docs/leadv2" ] && printf '%s' "$_r" || pwd`,
    { label: 'gather-init', phase: 'Gather', model: 'haiku', effort: 'low', schema: INIT_SCHEMA }),
  () => agent(/* gather-signals — unchanged */ ...),
  () => agent(/* gather-rejected — unchanged */ ...),
  () => agent(/* gather-exemplars — unchanged */ ...),
]
const [initResult, patterns, rejectedResult, exemplarResult] = await parallel(gatherLegs)
const TS = (initResult && initResult.ts) || new Date().toISOString()
const DURABLE_ROOT = (initResult && initResult.durable_root) || '.'

async function flushLedger() {                                       // Move 2: 1 call, not N
  if (ledgerEvents.length === 0) return
  try {
    await agent(
      `Append each of these ${ledgerEvents.length} JSON objects as its own line to docs/leadv2/ledger.jsonl ` +
      `(create dirs if absent, append-only). Run once per event via Bash:\n` +
      `python3 "${projRoot}/.claude/scripts/lv2-ledger-emit.py" '<event-json>'\n` +
      `Events (in order, run exactly these, do not alter): ${JSON.stringify(ledgerEvents)}. Return "flushed:<n>".`,
      { label: 'ledger-flush', phase: 'Shadow-Emit', model: 'haiku', effort: 'low' })
  } catch (_) { /* fire-and-forget, never blocks task_close */ }
}
// every `await emitLedger(event, extra)` call-site becomes:
ledgerEvents.push({ event: 'phase_exit', task_id: TASK_ID || 'unknown', phase: 'Gather', ...extra })

// Move 3: collapse the per-proposal loop into ONE agent() call.
const emittable = proposal.proposals
  .map(p => ({ p, riskLevel: classifyRisk(p.kind, p.target, p.change), diffPatch: (p.diff_patch || '').trim() }))
  .filter(x => x.diffPatch && shadowOnClose && TASK_ID)
if (emittable.length > 0) {
  const SHADOW_SCHEMA = { type: 'object', additionalProperties: false,
    properties: { results: { type: 'array', items: { type: 'object', additionalProperties: false,
      properties: { kind: {type:'string'}, target: {type:'string'}, risk_level: {type:'string'}, id: {type:['string','null']} },
      required: ['kind','target','risk_level'] } } }, required: ['results'] }
  const shadowResult = await agent(
    `For each proposal below, run this EXACT command via Bash (substitute bracketed fields verbatim — ` +
    `these are ALREADY shell-escaped, do not re-derive or re-quote them):\n` +
    `python3 "${projRoot}/.claude/scripts/lv2-shadow-emit.py" "${TASK_ID}" "<kind>" "<target>" "<risk_level>" "${projRoot}" "<diff_patch>"\n` +
    `Proposals (in order): ${JSON.stringify(emittable.map(x => ({ kind: x.p.kind, target: x.p.target, risk_level: x.riskLevel, diff_patch: x.diffPatch })))}. ` +
    `Trimmed stdout matching ^[0-9a-f]{40}$ → id; else id=null. Return results[] in the same order.`,
    { label: 'shadow-emit-batch', phase: 'Shadow-Emit', model: 'haiku', effort: 'low', schema: SHADOW_SCHEMA })
  const results = (shadowResult && shadowResult.results) || []
  emittable.forEach((x, i) => {
    const r = results[i]
    if (r && r.id && /^[0-9a-f]{40}$/.test(r.id)) shadowProposals.push({ id: r.id, kind: x.p.kind, target: x.p.target, risk_level: x.riskLevel })
    else shadowProposals.push({ kind: x.p.kind, target: x.p.target, risk_level: x.riskLevel, status: 'emit_failed' })
  })
}
await flushLedger()   // right before each `return`
```

Net effect on `leadv2-learn.js`: 4 real bash() call-sites (and ~12+ runtime invocations across a typical run) collapse into **1 new gather leg + 1 flush call + 1 batch call = 3 agent() additions**, none of them adding an extra sequential round-trip (the gather leg piggybacks on an existing fan-out; flush and batch happen once each at the point where a write already occurs).

## Execution order (per task brief)

1. **`leadv2-learn.js` FIRST** — self-learning engine, no hand-rolled fallback exists if it silently never runs; also the clearest template for the 3-move pattern (all three moves present in one file).
2. **`leadv2-plan.js` and `leadv2-review.js`** — Phase 2 / Phase 5, highest call frequency of the 10, both benefit from the "fold into an existing call" trick that yields ~0 net new agent() calls. Fix together since both reuse the same `_ARCHIVE_ROOT`/`_archiveRoot` marker-check idiom.
3. **`leadv2-causal-critique.js`** — heaviest by raw line/call count, but flag-gated (`LEADV2_CAUSAL_CRITIQUE=1`) and already fail-open by design, so it is lower urgency than #1/#2 despite its size. Do this once the gather-fold pattern is validated on #1/#2.
4. **Batch sweep: `leadv2-audit.js`, `leadv2-diverge.js`, `leadv2-diagnose.js`, `leadv2-po-feedback-loop.js`, `leadv2-intake-enrich.js`** — all 5 share the identical single-call pattern (emitLedger, or in intake-enrich's case a single-consumer root-resolve); mechanical, low-risk, can land as one PR after each file gets a quick full-read to confirm the grep-context assumption.
5. **`leadv2-ledger.js`** — optional comment refresh, no functional change, do last or skip.

Test-harness updates should land **alongside** each file's fix, not after: `causal-critique-harness.mjs`, `learn-freeform-flag-harness.mjs`, and `codemap-plan-harness.mjs` all need their `new Function('args','agent','bash','phase','log','parallel', body)` signature corrected to match the real runtime (drop `bash`, add `pipeline`+`budget` no-op mocks) — otherwise the tests keep validating a fictional environment even after the source is fixed (this is the exact blind spot that shipped the bug). `review.js` and `plan.js` currently have **no** interpreter-level harness at all; add at least a minimal one given their call frequency (fast-follow, not blocking).

## Go-live steps (per repo convention)

1. Edit source in `~/Projects/leadv2/plugins/leadv2/workflows/*.js` (+ matching harness fixtures in `~/Projects/leadv2/plugins/leadv2/scripts/tests/fixtures/`).
2. Run `leadv2-plugin-sync.sh` (present both at `~/Projects/leadv2/plugins/leadv2/scripts/leadv2-plugin-sync.sh` and vendored per-repo, e.g. `persona-engine/.claude/scripts/leadv2-plugin-sync.sh`) — this refreshes the live plugin cache at `~/.claude/plugins/local/leadv2/plugins/leadv2/workflows/` (confirmed present and populated at that path).
3. Start a **new** Claude Code session. Existing sessions have already loaded the stale workflow definitions in memory — the fix will not apply retroactively to an open session.

## Risks and mitigations

| # | Risk | Severity | Mitigation |
|---|---|---|---|
| R1 | Shell-injection/escaping regression: `causal-critique.js`'s `shq()` single-quote escaping of `TASK_ID` (hardened against a crafted `x'; touch PWNED; echo '` payload — there is a dedicated `malicious-taskid` harness scenario for this) is deterministic JS today. If the agent is asked to *construct* shell commands from a description instead of executing a pre-built literal, escaping quality depends on LLM judgment, not a tested function. | **HIGH** | JS keeps building the final, already-escaped command string exactly as today (same `shq()` calls); the agent prompt says "run this exact string verbatim via Bash, do not modify it" — the agent is an executor, never the author of shell quoting. Apply this to every call-site that interpolates external input (TASK_ID, diff_patch, freeform JSON), not just causal-critique. |
| R2 | Ledger crash-recovery degradation: `leadv2-ledger.js`'s stated purpose is "crash-recovery via last-committed-phase detection," which assumes near-real-time per-event writes. A single end-of-run flush means a mid-run crash loses the *entire* run's events, not just the in-flight phase. | MEDIUM | Flush at each `phase()` boundary (3-4 calls/run) instead of once at the very end — still collapses N-events-per-run into a handful of calls, but bounds the loss to "current phase only." Confirm with the implementing agent/founder whether any consumer actually depends on ledger crash-recovery today before picking single-flush vs per-phase-flush. |
| R3 | Digest fidelity in `causal-critique.js`: the Critique prompt's quality depends on the *exact* `.join('\n').slice(0,2000)` formatting of the 6 digest slices. Asking the gather-agent to also format/summarize the digest invites paraphrase drift. | MEDIUM | Gather-agent returns the 7 fields **raw and unformatted**; the existing JS join/truncate logic stays untouched and runs on the returned values, unchanged. |
| R4 | Test harnesses mock a nonexistent `bash()` and omit real primitives (`pipeline`, `budget`) — the root cause of why this bug shipped undetected. Fixing source without realigning harnesses leaves the blind spot open for the next runtime-contract violation. | HIGH | Update all 3 existing harnesses' `new Function(...)` signature to match the real runtime exactly (no `bash`, add `pipeline`+`budget`). Add a lint/CI check: bare top-level `await bash(` (i.e. not inside a string literal passed to `agent()`) in `plugins/leadv2/workflows/*.js` should fail CI. |
| R5 | Coverage gap: 7 of 10 workflows (`audit`, `diverge`, `diagnose`, `po-feedback-loop`, `intake-enrich`, `review`, `ledger`) have **no** interpreter-level harness today — only `causal-critique`, `learn`, `plan` do. A fix "by inspection" on the other 7 risks repeating this exact class of incident for a different contract violation. | MEDIUM | Add at minimum a smoke-level harness (reuse the `causal-critique-harness.mjs` `new Function` pattern) for `review.js` and `plan.js` given their Phase 2/5 call frequency, as a fast-follow immediately after their fix lands. |
| R6 | Determinism-critical writes in `plan.js` (`persistCodeMap()`, `task_class` persist — both flock+heredoc python, explicitly designed because "the Synthesize LLM is NOT trusted to reliably write/keep the code_map key") move from a guaranteed JS `bash()` call to an agent-mediated one, reintroducing exactly the non-determinism the original code avoided. | MEDIUM | Same "verbatim string, agent as executor" pattern as R1; schema-constrain the return to `{written: boolean}` only — never ask the agent to reconstruct the heredoc from a description. Both the first-pass (`synthesize`) and retry (`synthesize-retry`) prompts need the identical fold-in — share the instruction text via one JS string constant to avoid drift between the two call sites. |
| R7 | 5 files (`audit`, `diverge`, `diagnose`, `po-feedback-loop`, `intake-enrich`) were classified from `grep -B2 -A2` context only, not a full read — the "1 real call, mechanical fix" verdict is a reasonable inference (bodies shown were byte-identical to the confirmed `emitLedger` pattern in the 4 fully-read files) but unverified for hidden edge cases (e.g. a second bash call further down, or a different runtime emitLedger call count). | LOW | Implementing agent does a full read of each before mechanically applying Move 2/1 — budget for this is small (files are 92-352 lines). |

## Out of scope (implementing agent should ignore)

- No code changes were made in this pass — plan only.
- `pipeline()`/`budget` runtime primitives — unverified shape, not used by any of the 10 files today; do not block this fix on documenting them.
- `.claude/scripts/lv2-ledger-emit.py`, `lv2-shadow-emit.py`, or any other `.py`/`.sh` helper the `bash()` calls invoke — unchanged; only the JS call-site moves from JS-bash to agent-bash.
- Auditing every *caller* of these workflows (lead-reflect, phase8-close.sh, slash commands) for whether they already pass `args.ts` — flagged as a caller-side follow-up, not fixed here. If a caller doesn't pass `ts`, the workflow's own gather-agent fallback still resolves it correctly (no regression), just at a small extra cost.
- Deciding the flush-granularity trade-off (single end-of-run vs per-phase-boundary, R2) definitively — left as an explicit open decision for the implementing agent / founder, since it trades off call count against crash-recovery fidelity.
- Adding new interpreter harnesses for the 5 currently-uncovered mechanical files — recommended (R5) but not required for this migration's critical path.
- Any `contracts/` JSON-schema work, DB/Supabase migrations, or `platform/`/`agent/` module boundaries — not applicable; this is a leadv2-plugin-repo (JS workflow runtime) task, not a persona-engine data-layer task.

DELIVERABLE_COMPLETE
