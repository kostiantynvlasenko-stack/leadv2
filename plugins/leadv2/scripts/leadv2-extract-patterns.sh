#!/usr/bin/env bash
# leadv2-extract-patterns.sh <output.md> <file1> [file2] ...
# Lead pre-extracts imports + struct fields + function signatures from existing files,
# writes a single Markdown block the developer agent reads instead of opening each file.
# Goal: subagent reads 1 patterns file → writes code. No exploratory reads.
#
# Ported from m3-market/.claude/scripts/leadv2-extract-patterns.sh
# Sanitized for persona-engine conventions.
set -euo pipefail

[[ $# -lt 2 ]] && { echo "usage: $(basename "$0") <output.md> <file1> [file2 ...]" >&2; exit 64; }

OUT="$1"; shift
mkdir -p "$(dirname "$OUT")"

{
  echo "# Extracted patterns — $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  echo "> Lead-extracted. Developer agent reads THIS file only — do NOT open the originals to re-discover patterns."
  echo

  for F in "$@"; do
    if [[ ! -f "$F" ]]; then
      echo "## WARN: $F"
      echo "_file not found_"
      echo
      continue
    fi

    EXT="${F##*.}"
    REL="${F#"$PWD/"}"
    echo "## $REL"
    echo

    case "$EXT" in
      go)
        # package
        PKG="$(awk '/^package /{print $2; exit}' "$F")"
        echo "**Package:** \`$PKG\`"
        echo

        # imports
        echo "**Imports:**"
        echo '```go'
        awk '/^import \(/,/^\)/' "$F" | head -50
        # single-line imports
        grep -E '^import "' "$F" 2>/dev/null || true
        echo '```'
        echo

        # type definitions (struct + interface)
        echo "**Types (struct/interface):**"
        echo '```go'
        awk '/^type [A-Z][a-zA-Z0-9]+ (struct|interface) \{/{p=1; brace=1; print; next}
             p && /\{/{brace++}
             p && /\}/{brace--; print; if(brace==0){p=0; print ""}; next}
             p {print}' "$F"
        echo '```'
        echo

        # function signatures (one line each)
        echo "**Function signatures:**"
        echo '```go'
        grep -E '^func ' "$F" | sed 's/ {$//' | head -50
        echo '```'
        echo
        ;;

      ts|tsx)
        echo "**Imports:**"
        echo '```ts'
        grep -E '^import ' "$F" | head -30
        echo '```'
        echo
        echo "**Exports + signatures:**"
        echo '```ts'
        grep -E '^(export |type |interface |function |const |class )' "$F" | head -50
        echo '```'
        echo
        ;;

      py)
        echo "**Imports:**"
        echo '```python'
        grep -E '^(import |from )' "$F" | head -30
        echo '```'
        echo
        echo "**Classes + functions:**"
        echo '```python'
        grep -E '^(class |def |async def )' "$F" | head -50
        echo '```'
        echo
        ;;

      yaml|yml)
        echo "**Top-level keys + paths:**"
        echo '```yaml'
        # paths and top-level component names
        awk '/^[a-zA-Z_]/{print}; /^  \/[a-zA-Z]/{print}; /^  [A-Z][a-zA-Z]+:/{print}' "$F" | head -80
        echo '```'
        echo
        ;;

      sql)
        echo "**Statements:**"
        echo '```sql'
        head -50 "$F"
        echo '```'
        echo
        ;;

      *)
        echo "**First 30 lines:**"
        echo '```'
        head -30 "$F"
        echo '```'
        echo
        ;;
    esac
  done
} > "$OUT"

LINES="$(wc -l < "$OUT" | tr -d ' ')"
echo "OK $OUT ${LINES}L" >&2
