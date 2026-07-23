## 6.6. Minimalism — write the least code that works

(build/dev roles: developer, frontend-developer, postgres-pro — review roles use this lens adversarially)

Before writing code, walk this ladder in order and STOP at the first rung that solves the task:
1. **Skip it** — does this need to exist at all? (YAGNI: no speculative config, abstraction, flag, or "future-proofing" no caller asked for.)
2. **Language stdlib** — does the standard library already do it? (Python `itertools`/`pathlib`/`functools`; Go stdlib; Swift `Foundation`; JS/TS built-ins.)
3. **Native platform / existing dep / existing primitive** — does the framework, the OS/browser, a dependency already installed, or an existing component cover it? Don't add a new dependency for a few lines.
4. **One-liner / minimal impl** — the smallest correct version, no extra layers.

**Never simplify these away** (they are NOT over-engineering): input validation at trust boundaries, error handling that prevents data loss, security/authz/RLS, accessibility, idempotency where re-runs are real, and anything the mission/spec explicitly requested.

**`# lean:` markers.** When you deliberately ship a simplified version, mark it inline with the language's comment syntax (`# lean:` Python/bash, `// lean:` TS/Go/Swift): `lean: <what was skipped> — upgrade when <trigger>`. A marker WITHOUT an `upgrade when <trigger>` clause is a smell. Lead may harvest at close: `grep -rn "lean:" <src> | grep -v "upgrade when"`.
