## 2.5. Nested spawns (v2.1.172+) — 5-LEVEL HARD CAP

**5-LEVEL NESTING HARD CAP (2.1.172):** Claude Code enforces a maximum of 5 nesting levels across the entire spawn chain. The current leadv2 architecture (lead → workflow → developer → subagent) consumes 3 levels. Subagents in that chain may spawn one more level (level 4), but NEVER level 5 — that is the platform ceiling. Any spawn that would exceed level 5 is silently dropped by the runtime with no error. Design nested workflows to stay within levels 1–4.

Claude Code v2.1.172+ allows subagents to spawn sub-subagents (up to 5 levels deep). This capability is **gated** — only cheap discovery probes are permitted.

**Allowed nested spawns:**
```
Agent(subagent_type="Explore",          model="claude-haiku-4-5",   ...)  # graph/file discovery
Agent(subagent_type="general-purpose",  model="claude-sonnet-5",  ...)  # light synthesis
```

**Rules:**
- Max **1 nesting level** — your nested spawn must not itself spawn further agents.
- Max **3 nested spawns per task** across your entire run.
- `model=` is **mandatory and explicit** — never omit it (inherit-guard DENIES unrouted agents).
- Allowed models: any `*haiku*` or `*sonnet*` variant. Never `*opus*`.
- Allowed subagent_type: `Explore` or `general-purpose` only.
- **Never spawn** `developer`, `critic`, `architect`, `security-auditor`, or any build/review role.
- `run_in_background=true` recommended for non-blocking probes.
- If you need deeper graph queries, prefer the **ask-lead.sh graph proxy** (§1c) — it costs lead tokens only and does not count against your nested-spawn budget.

**Hook enforcement:** `leadv2-routing-guard.sh` (PreToolUse:Agent) enforces this allow-list and denies any nested spawn that violates these constraints with an actionable error message.

**Example — allowed:**
```
Agent(subagent_type="Explore", model="claude-haiku-4-5",
      prompt="Find all callers of upsert_snapshot in platform/. Return file paths only.",
      run_in_background=true)
```

**Example — denied:**
```
Agent(subagent_type="developer", model="claude-sonnet-5", ...)  # build role not allowed nested
Agent(subagent_type="Explore",   ...)                              # model= omitted → DENIED
```

## 2.6. Escalation token — when and how

An escalation token allows a single nested spawn of a type/model outside the base allowlist (e.g. `critic+opus` for a deadlock decision). Lead issues the token by writing `docs/handoff/<task-id>/escalation-budget.yaml` at Phase 4 spawn time; it is NOT a right subagents can self-grant.

**Spend the token ONLY when ALL of the following hold:**
1. You have made **2 failed attempts** at the same blocker (concrete evidence: loop counter, logged attempts).
2. Mission requirements and observed code/contracts are **directly contradictory** with no resolution path in your authority.
3. The decision needed is on an **irreversible operation** (schema drop, prod write, security bypass) you are explicitly not authorized to make.

**Never escalate for:**
- Uncertainty or preference ("I'm not sure which approach is better").
- Discovery tasks — use ask-lead.sh graph proxy (§1c) instead.
- Any situation reachable by returning a blocker to lead via your deliverable.

**How to escalate:**
```
Agent(subagent_type="<type in budget allowed_types>",
      model="<model in budget allowed_models>",
      prompt="...",
      run_in_background=true)
```
The hook checks `escalation-budget.yaml`, increments `used` atomically, and allows the spawn. If `used >= max_escalations` the hook denies and you MUST return the blocker to lead instead — never retry.

**Never recursive:** an escalated agent receives no budget and cannot itself escalate.

## Background spawn watchdog — default-on (ANTI-AMNESIA-01)

Every `Agent(run_in_background=true)` call MUST be immediately followed by `Monitor(path=<deliverable-file>)`. The `leadv2-bg-watchdog-gate.sh` PostToolUse:Agent hook enforces this inline: if no Monitor follows the spawn before the next tool call, it injects a blocking `additionalContext` reminder. There is no opt-out. Both `<role>.md` and `<role>.full.md` paths should be covered where the two-file deliverable split applies. Background agents die silently on spend-limit or crash — without a Monitor, the session stalls indefinitely with no recoverable signal.
