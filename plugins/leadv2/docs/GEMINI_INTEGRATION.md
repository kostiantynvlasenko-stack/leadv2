# Gemini Integration (Antigravity CLI)

Single source of truth for /leadv2 lead and subagents on when and how to invoke Gemini 3.5 via the Antigravity CLI (`agy`). Read this once at session start when `leadv2-gemini-check.sh` reports `ok`.

## Why Gemini at all

Gemini 3.5 Flash, released 2026-05-19, sits in a different slot than Claude:

- **1M-token context window** — long-doc summaries cheaper than Sonnet/Opus
- **289 tok/s** — ~4× faster than frontier
- **Native browser tool** — open URLs, read page content, no Playwright glue
- **Native multimodal** — images/PDFs/audio/video (CLI text-only in 1.0.1; multimodal lands in Antigravity.app GUI)
- **Keyless** — uses founder's Antigravity.app OAuth, no API key, no metered cost on our side

Gemini is **not** a Claude replacement. Opus still wins SWE-Bench Pro by 9pp. Use Gemini where its profile fits.

## When to call Gemini

| Use case | Mode | Script |
|---|---|---|
| Summarize a large file/log/PR diff/post batch (>20K tokens) | summarize | `leadv2-gemini-task.sh summarize` |
| Web research (open a URL, read a page, structured Q from web sources) | research | `leadv2-gemini-task.sh research` |
| Short knowledge Q&A (math, lookup, classification) | consult | `leadv2-gemini-task.sh consult` |
| On-demand UI/UX inspection of a deployed URL (visual + copy + hierarchy) | agent | `leadv2-gemini-ui-check` skill |
| Multi-step agentic file ops in a scratch workspace | agent | `leadv2-gemini-task.sh agent` |

## When NOT to call Gemini

- **Phase 2 Plan (architect)** — Opus wins hard reasoning. Don't substitute.
- **Phase 5 Review adversarial** — `agy --print` not stateless enough for large-diff adversarial reviews (verified 2026-05-22). Stick with Codex + critic.
- **Phase 6 Deploy gate (llm-judge)** — irreversible decisions stay on Opus.
- **Persona voice/content generation** — invariant for persona-engine: voice DNA stays Claude+RAG.
- **Anything secret/proprietary on m3-market** — see compliance note in `<repo>/.claude/leadv2-overrides/gemini-policy.yaml`.

## Headless caveats (agy 1.0.1, verified 2026-05-22)

Antigravity CLI is interactive-first. `--print` headless mode is buggy:

- **`--print-timeout` flag** triggers tool-use exploration. Never pass it. Use shell `timeout` only.
- **`--dangerously-skip-permissions` without `--add-dir`** triggers meta-mode about the flag. Always pair with a workspace dir (use the seeded `~/.gemini/antigravity-cli/scratch/leadv2`).
- **`--print` + cwd in a real repo** — agy ignores prompt, explores the repo via codebase-memory-mcp. Always `cd` to a clean scratch dir or `$HOME` first.
- **Browser tool in `--print`** — works ~25% of the time empirically. Falls back to Playwright (`leadv2-browser-check`) when it goes meta.
- **`-m <model>` flag** — does not exist in 1.0.1. Switch Flash↔Pro via `/model` in Antigravity.app GUI; CLI inherits.
- **`@file` syntax** — works in TUI, doesn't return content in `--print`. Inline content into prompt instead.
- **`--output-format json`** — flag exists but triggers meta-mode in `--print`. Don't rely on structured output.

## Standard invocation pattern

```bash
# Probe first
if bash "${CLAUDE_PLUGIN_ROOT}/scripts/leadv2-gemini-check.sh" >/dev/null 2>&1; then
  GEMINI_OK=1
else
  GEMINI_OK=0
fi

# Use if available
if [[ "$GEMINI_OK" == "1" ]]; then
  bash "${CLAUDE_PLUGIN_ROOT}/scripts/leadv2-gemini-task.sh" <mode> \
    --prompt "$PROMPT" \
    --out "/tmp/leadv2-gemini-$(date +%s).out" \
    --timeout 120
  # Read result via Read tool on the --out path
fi

# Always have a fallback path that works without Gemini
```

## Cost / quota

- Keyless via founder's Antigravity.app OAuth — no metered API spend
- Counts against Google AI Pro / Ultra subscription quota
- Treat as "cheap but not free" — don't loop on the same content
- Each browser-tool call ≈ 5-15s of cold-start

## Per-repo policy

Each repo can constrain Gemini via `<repo>/.claude/leadv2-overrides/gemini-policy.yaml`:

```yaml
gemini_enabled: true        # global on/off
allowed_modes: [consult, summarize, research, agent, ui-check]
disallowed_content:
  - "secrets, API keys, customer PII"
  - "proprietary business logic"  # corp repos
compliance_note: "Personal Google OAuth. Do not paste proprietary code."
```

If a repo's policy says `gemini_enabled: false`, all skills here must skip Gemini and fall back. If `disallowed_content` lists categories, lead must redact before composing the prompt.

## Lead awareness self-test

Before considering Gemini in a phase, lead should:

1. Run `bash ${CLAUDE_PLUGIN_ROOT}/scripts/leadv2-gemini-check.sh` (~5s, cache result for the session)
2. Read `<repo>/.claude/leadv2-overrides/gemini-policy.yaml` if present
3. Check this doc's "When NOT to call" list
4. Compose prompt without protected content per policy
5. Invoke via the standard pattern above; ALWAYS have a fallback for `exit != 0`

If lead skips step 1-2, treat as a process bug and surface to founder.
