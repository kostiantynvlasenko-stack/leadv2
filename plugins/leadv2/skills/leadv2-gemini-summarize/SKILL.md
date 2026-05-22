---
name: leadv2-gemini-summarize
description: On-demand long-context summarization via Gemini 3.5 Flash (1M context, ~6× cheaper than Sonnet). Triggers when founder asks to "summarize", "digest", "обзорни", "что в логах", "что в этом PR", or when lead encounters a large blob (>20K tokens of logs, posts, diffs, specs) and needs a structured digest before further reasoning. Falls back to Sonnet+chunking if Antigravity CLI (`agy`) is not installed. Read plugins/leadv2/docs/GEMINI_INTEGRATION.md for the full invocation contract.
---

# Gemini Long-Context Summarize

Use Gemini 3.5 Flash's 1M context window to digest large input into a structured summary. Cheaper and faster than chunked Sonnet calls when the input is just text.

## When to fire

- Founder pastes / references a large blob (log, batch of posts, PR diff, multi-file spec)
- Lead's own context approaches budget and a digest is needed before continuing
- Phase 1 broad discovery on a system area with 30+ files
- Phase 8 lead-reflect aggregation over 50+ signatures
- Pre-`/compact` resume note generation

**Do not fire** for:
- Single function / single file (Sonnet handles it cheaper)
- Content that includes secrets or proprietary business logic (check `<repo>/.claude/leadv2-overrides/gemini-policy.yaml`)
- Decisions that need strong reasoning (use Opus)

## Invocation

```bash
GEMINI_OK=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/leadv2-gemini-check.sh" >/dev/null 2>&1 && echo 1 || echo 0)

if [[ "$GEMINI_OK" == "1" ]]; then
  bash "${CLAUDE_PLUGIN_ROOT}/scripts/leadv2-gemini-task.sh" summarize \
    --input-file /path/to/big-blob.txt \
    --prompt "Summarize this <thing>. Output sections: 1) Key facts (<=10 bullets). 2) Risks/anomalies. 3) Recommended next action." \
    --out "/tmp/leadv2-gemini-summary-$(date +%s).out" \
    --timeout 180
  # Read the output file, extract section bodies
else
  # Fall back: chunked Sonnet summarize via Agent(Explore, haiku) with narrow mission
fi
```

The wrapper reads `--input-file` and embeds it inline in the prompt before sending. No external file refs (agy 1.0.1 doesn't honor `@file` in --print).

## Prompt template

Lead with the structure you want back, not flowery instructions:

```
You are summarizing <content type> for an engineering lead. Output ONLY these sections, no preamble:

## Key Facts
(up to 10 bullets, factual, scannable)

## Risks / Anomalies
(any signal of regression, error patterns, drift, deadline pressure — empty if none)

## Recommended Next Action
(one sentence)

Source:
<INLINE CONTENT HERE>
```

For different domains, tweak section names:
- Posts batch: "Themes" / "Repetitions/AI-tells" / "Voice drift signal"
- Log digest: "Events timeline" / "Error patterns" / "Suspected root cause"
- PR diff: "Surface touched" / "Risky changes" / "Test coverage gap"

## Output handling

Output is unstructured markdown (no Findings contract). Read with `Read` on `--out` path. Extract sections via simple grep or pass through to caller.

If output is `# exit=124` or empty → Gemini hung. Don't retry; fall back to chunked Sonnet.

## Gotchas

- **Input size**: Gemini 3.5 Flash supports 1M tokens in. We're nowhere near that; even 500K should be safe. But `agy --print` may struggle past 200K of inlined content. Chunk if input >500KB raw.
- **Russian/multilingual content** — Gemini handles fine; output language follows input language by default. Add "Respond in English" if you need normalized output.
- **Code-heavy content** — wrap in fenced code blocks in the prompt so Gemini doesn't try to execute or "fix" it.
- **Secrets** — scan input file for `API_KEY`, `password`, `SUPABASE_*`, etc. Redact before sending if found.
