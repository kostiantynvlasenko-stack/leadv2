# Hack Detection Signal Catalog

Detection patterns scanned by leadv2-hack-detection. Applied to `+` lines only (stripped of leading `+`).

| Pattern | Type | Severity | Detection |
|---|---|---|---|
| `# TODO` / `# FIXME` / `# HACK` / `# XXX` without a linked ticket or justification | `todo-no-ticket` | warn |
| Magic number: bare integer/float literal not assigned to a named constant, in a context that implies policy (e.g. `sleep(17)`, `retry_count = 3`, `timeout = 30`) | `magic-number` | warn |
| Broad `except Exception:` or `except:` with body that is `pass` or only a `log` call — no re-raise | `broad-except` | warn |
| `@pytest.mark.skip` without a `reason=` argument, OR `test_*.py` file deleted with no replacement | `disabled-test` | **block** |
| Persona/entity-specific hardcoded branch: `if <id_var> == "<specific_value>":` where value looks like an ID/name rather than a config key | `special-case` | warn |
| Block of consecutive commented-out code lines (≥3 `# ` lines that look like code, not prose) | `commented-code` | warn |
| Hardcoded credential, URL, token, or API key pattern in new code (distinct from security-auditor scope — here as quality signal) | `hardcoded` | warn |

## Notes

- **todo-no-ticket**: The pattern matches TODO/FIXME/HACK/XXX comments that do not contain a link (http://, https://) or a ticket reference (e.g., PE-42, TASK-7, issue#123). A comment like `# TODO: see PE-42` or `# FIXME: https://github.com/...` will not trigger.
- **magic-number**: Targets numeric literals in specific contexts (sleep, timeout, retry_count, limit, max_attempts, interval) that signal policy rather than iteration or data. A literal in a loop bound or data definition is not flagged.
- **broad-except**: A bare `except:` or `except Exception:` is only flagged if the body is empty or contains only logging/pass with no re-raise. A proper error handler that logs AND re-raises is acceptable.
- **disabled-test**: The hardest trigger. Any skipped test or deleted test file without a clear replacement is a blocker.
- **special-case**: Heuristic pattern that flags branches like `if persona_id == "respiro-brand":` — persona/user/entity IDs hardcoded in logic rather than config. Normal conditionals (e.g., `if status == "active"`) are not flagged.
- **commented-code**: Looks for consecutive comment lines (≥3) that start with `# def `, `# class `, `# import `, `# return `, `# if `, `# for `, `# while ` — indicating dead code, not prose comments.
- **hardcoded**: Regex targets patterns like `api_key="..."`, `secret="..."`, `password="..."`, `token="..."`, `credential="..."` with 16+ character values (excludes short config strings).
