# Causal critique (GEPA-style, gated) — full reference

Referenced from `SKILL.md` §4.5. This is the full invocation snippet, gate logic, and safety
rationale for the `LEADV2_CAUSAL_CRITIQUE`-gated step that runs BEFORE §5a (reflect-history.yaml
write) so its output can be folded into the entry.

Default OFF — flag unset or `0`, OR task_class is Trivial/Light -> skip entirely: do not invoke
the Workflow tool, no tempfile is written, and the §5a entry is byte-identical to today.
Never blocks close: any error/exception/unavailable-tool result is treated as skip.

```bash
critique_flag="${LEADV2_CAUSAL_CRITIQUE:-0}"
task_class_cc="${task_class:-Standard}"   # from context.yaml .class (§2)
cc_tmp_path="docs/handoff/${LEADV2_TASK_ID}/.causal-critique.json.tmp"  # read by §5a below
```

If `critique_flag != "0"` AND `task_class_cc` is NOT `Trivial`/`Light`:

```
Workflow({name:"leadv2-causal-critique", args:{task_id: LEADV2_TASK_ID, task_class: task_class_cc}})
```

- If the Workflow tool is unavailable, throws, or returns null: log one pulse line
  `causal-critique: skipped (<reason>)` and leave `cc_tmp_path` unwritten -- continue to §5a, which
  treats a missing file identically to the flag being off.
- On success: write `JSON.stringify(result.causal_critique)` to `cc_tmp_path` using the **Write
  tool** (`Write({file_path: cc_tmp_path, content: JSON.stringify(result.causal_critique)})`) --
  **NEVER** a shell redirect, `printf`, or heredoc splice. This is the fix for
  REFLECT-CAUSAL-CRITIQUE-01 fix-round-2 C1: `causal_critique` is LLM-derived text quoting raw
  digest content (git-diff/ledger/review-signature excerpts) and MUST NOT be embedded as literal
  source text inside any shell/Python command string -- a triple-quote or backtick/`$(...)`
  sequence inside that text would otherwise break the enclosing quoting and either corrupt the
  whole reflect-history write or execute as code. The `Write` tool takes `content` as inert data,
  never interpolated into a command line, so this is safe regardless of what the critique text
  contains. A critique that filtered out every driver (`root_drivers: []`) is still a valid
  result -- write it as-is, it is not the same as a skip.
- If `result.freeform_insight` is non-null it has ALREADY been appended to
  `docs/leadv2/freeform-insights.jsonl` by the workflow (atomic line-append, `status:"candidate"`)
  -- nothing further to do here; do not duplicate the write.

If `critique_flag == "0"` or `task_class_cc` is Trivial/Light: skip entirely -- no tempfile is
written and §5a's entry omits the `causal_critique:` key exactly as it does today.

## Why reading from a file is safe (fold-in contract for §5a)

`SKILL.md` §5a reads `cc_tmp_path` back from disk (not from an in-memory variable) specifically
so that `causal_critique` content — which is LLM-derived text quoting raw digest content — is
never spliced as literal source text into the Python heredoc. The read is wrapped in
`try/except FileNotFoundError` (missing file -> empty string -> key omitted) and the whole
fold-in block is additionally wrapped in a broader `try/except Exception` so a malformed or
unreadable tempfile can NEVER abort the reflect-history write — this matches the "never blocks
close" guarantee that applies to every other step in this skill.
