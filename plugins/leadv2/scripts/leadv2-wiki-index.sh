#!/usr/bin/env bash
# leadv2-wiki-index.sh — SQLite FTS5 incremental indexer for the leadv2 wiki
# DB: ~/.claude/leadv2-wiki/wiki.db
# Sources: docs/handoff/*/findings.md | docs/specs/*.md | docs/leadv2/tasks/*/solution.md
#
# Usage:
#   leadv2-wiki-index.sh               — incremental: index any changed source files
#   leadv2-wiki-index.sh --rebuild     — full rebuild: drop + recreate index from scratch
#   leadv2-wiki-index.sh --path <file> — re-index a single file (used by PostToolUse:Write hook)
#
# Idempotent: running twice on the same file is safe (DELETE + INSERT on primary key).

set -euo pipefail

# ── constants ──────────────────────────────────────────────────────────────────
readonly WIKI_DB="${HOME}/.claude/leadv2-wiki/wiki.db"
readonly PROJECT_ROOT="${LEADV2_PROJECT_ROOT:-${HOME}/Projects/persona-engine}"

log() { printf -- '[wiki-index] %s\n' "$*" >&2; }

# ── ensure DB + FTS5 table ─────────────────────────────────────────────────────
init_db() {
  mkdir -p "$(dirname "$WIKI_DB")"
  sqlite3 "$WIKI_DB" <<'SQL'
CREATE TABLE IF NOT EXISTS wiki_files (
  path     TEXT PRIMARY KEY,
  mtime    INTEGER NOT NULL,
  indexed_at INTEGER NOT NULL
);
CREATE VIRTUAL TABLE IF NOT EXISTS wiki_fts USING fts5(
  path UNINDEXED,
  content,
  tokenize = 'porter unicode61'
);
SQL
}

# ── index a single file ────────────────────────────────────────────────────────
index_file() {
  local filepath="$1"
  [[ -f "$filepath" ]] || return 0

  local mtime
  mtime=$(python3 -c "import os; print(int(os.path.getmtime('$filepath')))")

  # skip if mtime unchanged (incremental fast-path)
  if [[ "${FORCE_REBUILD:-0}" != "1" ]]; then
    local stored_mtime
    stored_mtime=$(sqlite3 "$WIKI_DB" "SELECT mtime FROM wiki_files WHERE path='$filepath';" 2>/dev/null || true)
    if [[ "$stored_mtime" == "$mtime" ]]; then
      return 0
    fi
  fi

  # upsert: delete old FTS row then insert fresh (python3 reads file directly)
  python3 - "$filepath" "$mtime" <<'PYEOF'
import sys, sqlite3, os, datetime

filepath = sys.argv[1]
mtime    = int(sys.argv[2])
db_path  = os.path.expanduser("~/.claude/leadv2-wiki/wiki.db")

try:
    with open(filepath, "r", encoding="utf-8", errors="replace") as f:
        content = f.read()
except Exception:
    content = ""

con = sqlite3.connect(db_path)
cur = con.cursor()
now = int(datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None).timestamp())

# remove old FTS entry
cur.execute("DELETE FROM wiki_fts WHERE path = ?", (filepath,))
# insert fresh FTS entry
cur.execute("INSERT INTO wiki_fts(path, content) VALUES (?, ?)", (filepath, content))
# upsert mtime tracker
cur.execute(
    "INSERT INTO wiki_files(path, mtime, indexed_at) VALUES(?,?,?) "
    "ON CONFLICT(path) DO UPDATE SET mtime=excluded.mtime, indexed_at=excluded.indexed_at",
    (filepath, mtime, now)
)
con.commit()
con.close()
PYEOF

  log "indexed: $filepath"
}

# ── collect source globs ───────────────────────────────────────────────────────
collect_sources() {
  # findings.md under any handoff dir
  find "$PROJECT_ROOT/docs/handoff" -maxdepth 2 -name "findings.md" 2>/dev/null || true
  # all spec markdown
  find "$PROJECT_ROOT/docs/specs" -maxdepth 1 -name "*.md" 2>/dev/null || true
  # solution.md under any leadv2 task dir
  find "$PROJECT_ROOT/docs/leadv2/tasks" -maxdepth 2 -name "solution.md" 2>/dev/null || true
}

# ── full rebuild ───────────────────────────────────────────────────────────────
full_rebuild() {
  log "full rebuild — dropping existing index"
  rm -f "$WIKI_DB"
  init_db
  FORCE_REBUILD=1
  local count=0
  while IFS= read -r fpath; do
    index_file "$fpath"
    (( count++ )) || true
  done < <(collect_sources)
  log "rebuild complete: $count files indexed"
}

# ── incremental update ─────────────────────────────────────────────────────────
incremental_update() {
  init_db
  local count=0
  while IFS= read -r fpath; do
    index_file "$fpath"
    (( count++ )) || true
  done < <(collect_sources)
  log "incremental done: checked $count source files"
}

# ── path filter: does this path match our source globs? ───────────────────────
path_matches_sources() {
  local p="$1"
  [[ "$p" == */docs/handoff/*/findings.md ]] && return 0
  [[ "$p" == */docs/specs/*.md ]]            && return 0
  [[ "$p" == */docs/leadv2/tasks/*/solution.md ]] && return 0
  return 1
}

# ── main ───────────────────────────────────────────────────────────────────────
main() {
  local mode="incremental"
  local single_path=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --rebuild) mode="rebuild" ;;
      --path)
        mode="single"
        shift
        single_path="$1"
        ;;
      *) log "unknown arg: $1"; exit 1 ;;
    esac
    shift
  done

  case "$mode" in
    rebuild)
      full_rebuild
      ;;
    single)
      if [[ -z "$single_path" ]]; then
        log "--path requires a file argument"; exit 1
      fi
      if path_matches_sources "$single_path"; then
        init_db
        index_file "$single_path"
      else
        log "path does not match source globs, skipping: $single_path"
      fi
      ;;
    incremental)
      incremental_update
      ;;
  esac
}

main "$@"
