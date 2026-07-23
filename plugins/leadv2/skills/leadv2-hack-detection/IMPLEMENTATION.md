# Implementation Details

## Python regex patterns

Use Python stdlib only (no third-party imports).

```python
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

# Patterns applied to + lines only (stripped of leading +)
PATTERNS = {
    "todo-no-ticket": re.compile(
        r'#\s*(TODO|FIXME|HACK|XXX)\b(?!.*(?:https?://|\w+-\d+|ticket|issue))',
        re.IGNORECASE
    ),
    "broad-except": re.compile(
        r'except\s*(Exception\s*)?:\s*$'  # matched with next-line check for pass/log only
    ),
    "disabled-test": re.compile(
        r'@pytest\.mark\.skip(?!\s*\(.*reason\s*=)'
    ),
    "special-case": re.compile(
        r'if\s+\w+\s*==\s*["\'][a-zA-Z][\w\-]{3,}["\']'  # heuristic: id-looking value
    ),
    "hardcoded": re.compile(
        r'(?:api_key|secret|password|token|credential)\s*=\s*["\'][A-Za-z0-9+/]{16,}["\']',
        re.IGNORECASE
    ),
}

MAGIC_NUMBER = re.compile(
    r'(?:sleep|timeout|retry_count|limit|max_attempts|interval)\s*[=(]\s*(\d{2,})'
)
COMMENTED_CODE = re.compile(r'^#\s+(?:def |class |import |return |if |for |while )')
```

## Parsing instructions

1. Track current file from `diff --git a/<file> b/<file>` lines
2. Track line numbers from `@@` hunk headers  
3. Apply patterns to each `+` line (strip leading `+` before matching)
4. Accumulate 3+ consecutive commented-code lines as one finding
5. For `broad-except`: look ahead 1-2 lines for `pass` or bare logging with no re-raise

## Integration with lead-reflect

After reading hack findings, lead-reflect uses `hack_findings` to compute `fix_quality`:

- `block` findings present → `band-aid`
- `warn` > 3 → `band-aid`
- `warn` 1-3 → `reasonable`
- 0 findings AND test-synthesis coverage ≥ 80% → `durable`
- default (no data) → `reasonable`

This score feeds into the Phase 5 verdict: band-aid diffs are escalated for extra review, while durable diffs pass through.

## Anti-patterns

Do NOT:
- Flag deleted lines (lines starting with `-`) — only additions are in scope.
- Invent new `block`-severity cases beyond the hard-wired `disabled-test` rule.
- Run full AST parsing on source files — diff-only, stdlib regex, fast.
- Emit opinion-based findings ("this function is too long") — pattern catalog only.
