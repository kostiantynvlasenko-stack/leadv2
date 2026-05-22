---
name: leadv2-gemini-research
description: On-demand web research via Gemini 3.5 Flash's native browser tool. Triggers when founder asks to "research", "ресёрчни", "find docs for", "что нового про X", "какие best practices", or when lead needs current-web info (library docs, CVE advisories, vendor API specs, ecosystem updates) that Claude's WebSearch can't reliably fetch. Falls back to WebFetch + WebSearch if Antigravity CLI (`agy`) is not installed. Read plugins/leadv2/docs/GEMINI_INTEGRATION.md for the full invocation contract.
---

# Gemini Web Research

Use Gemini's native browser to fetch live web content and produce a structured answer. Better than WebSearch when you need actual page content, not a search-result snippet.

## When to fire

- Founder asks "что нового в X за последний месяц", "найди как настроить Y", "какие best practices для Z"
- Phase 2 plan needs current library/API docs (e.g. "how does new Postgres feature X work")
- Phase 5 security-audit wants live CVE/advisory check
- Phase 7 recovery wants alt-approach references ("how did others solve this")

**Do not fire** for:
- Internal docs (Slack threads, private wikis, customer data) — browser hits public web only
- Anything time-sensitive that needs hard verification (Gemini summary can drift; cite URLs and re-read with WebFetch)
- Already-known answers that Sonnet would emit faster

## Invocation

```bash
GEMINI_OK=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/leadv2-gemini-check.sh" >/dev/null 2>&1 && echo 1 || echo 0)

if [[ "$GEMINI_OK" == "1" ]]; then
  bash "${CLAUDE_PLUGIN_ROOT}/scripts/leadv2-gemini-task.sh" research \
    --prompt "Open <URL or hint> in the browser tool. <SPECIFIC ASK>. Cite the URLs you used. Output: Key Findings (<=8 bullets) + Sources (URL list)." \
    --out "/tmp/leadv2-gemini-research-$(date +%s).out" \
    --timeout 180
else
  # Fall back: WebSearch + WebFetch parallel calls
fi
```

## Prompt templates

**Library upgrade research:**
```
Open <library-docs-url> and the GitHub release notes. What breaks moving from <old> to <new>? List: (1) breaking changes (2) deprecations (3) recommended migration steps. Cite URLs.
```

**Vendor API spec lookup:**
```
Find current <vendor> docs for <specific endpoint or feature>. Report: (1) request schema (2) response schema (3) rate limits (4) known gotchas. Cite URL of each source page.
```

**Industry/protocol reference:**
```
Research <protocol/standard X> as of <year>. Output: (1) what it specifies (2) current status (3) reference implementations (4) common pitfalls. Cite URLs.
```

**Competitive scan:**
```
Open <competitor-url> and look at how they present <feature/concept>. Report: (1) their stated positioning (2) UI/copy approach (3) what they omit. <=10 lines.
```

## Output handling

Output should always include a Sources block at the end with raw URLs. Lead can re-verify with `WebFetch` if any finding is load-bearing.

If output is empty / `# exit=124` → Gemini's browser got stuck. Don't retry; fall back to WebFetch on the most likely URL, then WebSearch.

## Gotchas

- **Auth-walled pages** — Gemini can't sign in. Use public preview URLs only. If page requires login → tell founder, don't speculate.
- **JS-heavy SPAs** — Gemini's browser handles modern web, but very SPA-rendered docs (some Google Cloud / AWS pages) may return shells. WebFetch handles them too poorly; verify with founder if critical.
- **Time-sensitive answers** — Gemini's training cutoff may bias even browser-augmented answers. Always cite URLs and prefer explicit "as of today, per <URL>" framing.
- **Multilingual** — Gemini handles non-English sources fine but responds in prompt language. For mixed projects, request "Respond in English with original-language quotes preserved."
- **Cost on long pages** — browser session for a 100K-token page = ~30s wall clock. Don't research speculatively; have a concrete question.
