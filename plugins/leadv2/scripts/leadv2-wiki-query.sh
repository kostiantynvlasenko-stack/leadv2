#!/usr/bin/env bash
# leadv2-wiki-query.sh — FTS5 BM25 top-3 query for UserPromptSubmit hook
#
# Called by the UserPromptSubmit hook. Reads the hook's JSON payload from stdin,
# extracts the first 200 chars of the user prompt, queries the FTS5 wiki DB,
# and emits an additionalContext block if results found.
#
# Outputs JSON to stdout: { "additionalContext": "## Wiki context...\n..." }
# or {} if LEADV2_WIKI_INJECT != 1 / no DB / no results.
#
# Token budget: 800 tokens hard cap (~3200 chars); truncate if exceeded.
# Disable flag: LEADV2_WIKI_INJECT=0 (default) — no-op unless set to 1.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/leadv2-temp.sh"

readonly WIKI_DB="${HOME}/.claude/leadv2-wiki/wiki.db"
readonly MAX_CHARS=3200   # 800 tokens * ~4 chars/token
readonly TOP_N=3

# ── guard: opt-in flag ─────────────────────────────────────────────────────────
if [[ "${LEADV2_WIKI_INJECT:-0}" != "1" ]]; then
  # no-op: emit empty JSON (hook framework ignores empty additionalContext)
  printf -- '{}\n'
  exit 0
fi

# ── guard: DB must exist ───────────────────────────────────────────────────────
if [[ ! -f "$WIKI_DB" ]]; then
  printf -- '{}\n'
  exit 0
fi

# ── read hook payload via temp file (avoids heredoc quoting issues) ───────────
TMPFILE=$(lv2_mktemp_file "wiki-query" "json")
trap 'rm -f "$TMPFILE"' EXIT

python3 -c "import sys; open('$TMPFILE','w').write(sys.stdin.read())"

# ── extract prompt (first 200 chars) ──────────────────────────────────────────
QUERY=$(python3 - "$TMPFILE" <<'PYEOF'
import json, sys, re

tmpfile = sys.argv[1]
try:
    with open(tmpfile) as f:
        data = json.load(f)
    prompt = data.get("prompt", "")
    snippet = prompt[:200].strip()
    clean = re.sub(r'[^\w\s]', ' ', snippet)
    clean = ' '.join(clean.split()[:30])  # max 30 tokens
    print(clean)
except Exception:
    print("")
PYEOF
)

if [[ -z "$QUERY" ]]; then
  printf -- '{}\n'
  exit 0
fi

# ── guard: topic-relevance — skip DB if prompt has no leadv2/code keyword ─────
# Prevents spurious FTS5 hits for conversational turns (H-2 fix).
TOPIC_PATTERN='[Ll]eadv2|workflow|phase|plan|review|learn|diagnose|persona|migration|schema|hook'
if ! printf -- '%s' "$QUERY" | grep -qEi "$TOPIC_PATTERN" 2>/dev/null; then
  printf -- '{}\n'
  exit 0
fi


# ── FTS5 BM25 query via python3 ────────────────────────────────────────────────
RESULTS=$(python3 - "$WIKI_DB" "$QUERY" "$TOP_N" "$MAX_CHARS" <<'PYEOF'
import sys, sqlite3, os

db_path   = sys.argv[1]
query     = sys.argv[2]
top_n     = int(sys.argv[3])
max_chars = int(sys.argv[4])

if not query.strip():
    sys.exit(0)

try:
    con = sqlite3.connect(db_path)
    cur = con.cursor()
    # FTS5 BM25: rank() returns negative scores; ORDER BY rank ASC = best first
    cur.execute(
        """
        SELECT path,
               snippet(wiki_fts, 1, '**', '**', '...', 20) AS preview,
               rank
        FROM wiki_fts
        WHERE wiki_fts MATCH ?
        ORDER BY rank
        LIMIT ?
        """,
        (query, top_n)
    )
    rows = cur.fetchall()
    con.close()
except Exception:
    sys.exit(0)

if not rows:
    sys.exit(0)

lines = []
for (path, preview, _rank) in rows:
    display_path = path.replace(os.path.expanduser("~"), "~")
    lines.append(f"**{display_path}**\n{preview.strip()}")

block = "\n\n---\n\n".join(lines)
if len(block) > max_chars:
    block = block[:max_chars].rstrip() + "\n\n[truncated at 800-token budget]"

print(block, end="")
PYEOF
)

if [[ -z "$RESULTS" ]]; then
  printf -- '{}\n'
  exit 0
fi

printf '%s|wiki-query|inject hits>0\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> /tmp/leadv2-wiki-query.log 2>/dev/null || true
# ── emit additionalContext + ledger event ─────────────────────────────────────
python3 - "$RESULTS" <<'PYEOF'
import sys, json, os, datetime

results = sys.argv[1]
header  = "## Wiki context (auto-injected)\n\n"
block   = header + results

# emit ledger event (fire-and-forget, never blocks)
try:
    ev = {
        "ts": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "event": "wiki_inject",
        "task_id": os.environ.get("LEADV2_TASK_ID", "unknown"),
        "phase": "UserPromptSubmit",
        "payload": {
            "wiki_inject_tokens": len(results) // 4,
            "hits": results.count("---") + 1
        }
    }
    ledger_path = os.path.join(
        os.environ.get("LEADV2_PROJECT_ROOT",
                       os.path.expanduser("~/Projects/persona-engine")),
        "docs/leadv2/ledger.jsonl"
    )
    os.makedirs(os.path.dirname(ledger_path), exist_ok=True)
    with open(ledger_path, "a") as f:
        f.write(json.dumps(ev, separators=(",", ":")) + "\n")
except Exception:
    pass  # ledger emit never blocks the hook

print(json.dumps({"additionalContext": block}))
PYEOF
