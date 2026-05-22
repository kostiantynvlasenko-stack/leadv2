---
name: leadv2-gemini-ui-check
description: On-demand UI/UX inspection of a deployed URL via Gemini 3.5 Flash's built-in browser tool (Antigravity CLI). Use when the founder asks to "check UI", "look at the page", "evaluate UX", or "посмотри что на странице". Sibling to leadv2-browser-check (Playwright); use this one when the task needs a holistic UX read (layout, copy, hierarchy, accessibility cues) rather than a programmatic DOM/network check. Falls back to leadv2-browser-check if Antigravity CLI (`agy`) is not installed.
---

# Gemini UI Check (on-demand)

Drives Gemini 3.5 Flash's native browser tool to load a URL and produce a textual UX report. Triggered only when the founder explicitly asks — never proactively.

## When to use this vs leadv2-browser-check

| Need | Use |
|---|---|
| "check UI / посмотри" — holistic visual + copy + hierarchy read | **this skill** |
| "evaluate accessibility", "is this readable", "looks broken?" | **this skill** |
| Click element X, fill form, capture network errors | **leadv2-browser-check** (Playwright, scriptable) |
| Need exact DOM selectors, JS console logs, network waterfall | **leadv2-browser-check** |
| Compare two URL versions side-by-side | **this skill** (Gemini multimodal) |

## Prerequisites

- `agy` binary on PATH (install: `curl -fsSL https://antigravity.google/cli/install.sh | bash`)
- Antigravity.app installed and signed in (CLI inherits IDE auth)

Probe with `bash ${CLAUDE_PLUGIN_ROOT}/scripts/leadv2-gemini-check.sh`. Exit 0 = ready. Exit 1 = not installed → fall back to leadv2-browser-check. Exit 2 = installed but unhealthy → tell founder and fall back.

## Invocation

```bash
GEMINI_OK=$(bash ${CLAUDE_PLUGIN_ROOT}/scripts/leadv2-gemini-check.sh >/dev/null 2>&1 && echo 1 || echo 0)

if [[ "$GEMINI_OK" == "1" ]]; then
  bash ${CLAUDE_PLUGIN_ROOT}/scripts/leadv2-gemini-task.sh agent \
    --prompt "Open <URL> in the browser tool. <SPECIFIC ASK>. Report in <=10 lines: layout issues, copy issues, hierarchy/scan path issues, accessibility flags. End with 'Verdict: ship | minor-fixes | needs-redesign'." \
    --out "/tmp/leadv2-gemini-ui-$(date +%s).out" \
    --timeout 180
else
  # Fall back to Playwright skill
  Skill(leadv2-browser-check) with the same URL
fi
```

## Prompt template

Lead with what the founder actually wants to know. Example for a dashboard check:

```
Open https://timbre.fyi/dashboard in the browser tool. Sign in is not required —
the page is read-only. Evaluate:
1. Is the primary KPI immediately visible above the fold?
2. Are loading skeletons or empty-state messages confusing?
3. Are CTAs clearly distinguished from non-actions?
4. Any copy that reads AI-generated or jargon-heavy?

Report in <=10 lines, then 'Verdict: ship | minor-fixes | needs-redesign'.
```

For comparing two versions, pass both URLs in the prompt and ask for a comparison verdict.

## Output handling

The agent prints its report to stdout (also captured to `--out`). Read it with `Read` on the out path. No "Findings" marker contract — output is freeform UX prose.

If output is empty or contains only `# exit=124` → agy hung (rare with browser, but possible on slow pages). Don't retry; tell founder and fall back to Playwright.

## Gotchas

- **Auth-walled pages** — agy can't sign in. Either pass a public preview URL or fall back to Playwright with stored cookies.
- **Mobile viewport** — agy's browser is desktop by default. For mobile UX checks, mention "render at 375px width" in the prompt; if Gemini doesn't honor it, fall back to Playwright.
- **Screenshots** — agy doesn't natively save screenshots to disk in `--print` mode. If founder needs a PNG artifact, use Playwright instead.
- **Cost** — each call burns ~5-15s of Antigravity quota (keyless OAuth via IDE login). No metered API cost. Don't loop on the same URL — one read, one report.

## Don'ts

- Don't trigger this proactively when looking at logs, code, or specs. Only when founder explicitly asks about a rendered page.
- Don't use for synthetic regression tests — use Playwright (`leadv2-browser-check`) which is deterministic.
- Don't use for any auth/billing/admin surface — Playwright with managed creds is the right tool there.
