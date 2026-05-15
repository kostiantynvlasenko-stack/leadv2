#!/usr/bin/env bash
# leadv2-history-primer.sh [--limit N] [--exclude PATTERN] [--project-slug SLUG]
# Builds a compact digest of past Claude Code sessions for the current project.
# Reads JSONL transcripts, extracts: first user prompt, branches, top files touched, outcome.
# Output: memory/project_history_digest.md (per-session) + project_history_index.yaml (searchable).
#
# Ported from m3-market/.claude/scripts/leadv2-history-primer.sh
# Sanitized for persona-engine conventions:
#   - project slug auto-detected from git remote or CWD name
#   - no m3/MythicalGames path hardcoding
#   - stripped mp-api.yaml api-contract-change detection (m3-specific)
# Linear integration intentionally omitted in PE port.
set -euo pipefail

LIMIT=50
EXCLUDE=""
PROJECT_SLUG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --limit)         LIMIT="$2"; shift 2 ;;
    --exclude)       EXCLUDE="$2"; shift 2 ;;
    --project-slug)  PROJECT_SLUG="$2"; shift 2 ;;
    --help)
      echo "usage: $(basename "$0") [--limit N] [--exclude PATTERN] [--project-slug SLUG]"
      echo "  --limit N          max sessions to scan (default: 50)"
      echo "  --exclude PATTERN  regex to exclude sessions matching PATTERN"
      echo "  --project-slug     override auto-detected project slug"
      exit 0
      ;;
    *) echo "unknown arg: $1" >&2; exit 64 ;;
  esac
done

# Auto-detect project slug from git remote or CWD name
if [[ -z "$PROJECT_SLUG" ]]; then
  GIT_REMOTE="$(git remote get-url origin 2>/dev/null || echo '')"
  if [[ -n "$GIT_REMOTE" ]]; then
    PROJECT_SLUG="$(basename "$GIT_REMOTE" .git)"
  else
    PROJECT_SLUG="$(basename "$(pwd)")"
  fi
fi

# Build the ~/.claude/projects/ directory name (mirrors how Claude Code names it)
# Format: -<path-with-slashes-as-dashes>
CWD_NORM="$(pwd | tr '/' '-')"
PROJ_DIR="$HOME/.claude/projects/$CWD_NORM"

MEM_DIR="$PROJ_DIR/memory"
DIGEST="$MEM_DIR/project_history_digest.md"
INDEX="$MEM_DIR/project_history_index.yaml"

if [[ ! -d "$PROJ_DIR" ]]; then
  # Fallback: try scanning all project dirs for one matching the slug
  PROJ_DIR="$(find "$HOME/.claude/projects" -maxdepth 1 -type d -name "*${PROJECT_SLUG}*" 2>/dev/null | head -1 || echo '')"
  if [[ -z "$PROJ_DIR" ]]; then
    echo "ERR: no project dir found for '$PROJECT_SLUG' under ~/.claude/projects/" >&2
    echo "tip: pass --project-slug to override auto-detection" >&2
    exit 65
  fi
  MEM_DIR="$PROJ_DIR/memory"
  DIGEST="$MEM_DIR/project_history_digest.md"
  INDEX="$MEM_DIR/project_history_index.yaml"
fi

mkdir -p "$MEM_DIR"

# Top N JSONL by mtime
mapfile -t FILES < <(find "$PROJ_DIR" -maxdepth 1 -name '*.jsonl' -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -n "$LIMIT" | awk '{print $2}')
[[ ${#FILES[@]} -eq 0 ]] && { echo "no transcripts found in $PROJ_DIR" >&2; exit 1; }

echo "Scanning ${#FILES[@]} sessions (limit=$LIMIT, exclude='${EXCLUDE:-none}', project=$PROJECT_SLUG)..."

python3 - "$DIGEST" "$INDEX" "$EXCLUDE" "$PROJECT_SLUG" "${FILES[@]}" <<'PY'
import sys, json, os, re, datetime, collections, pathlib

digest_path  = sys.argv[1]
index_path   = sys.argv[2]
exclude_pat  = sys.argv[3]
project_slug = sys.argv[4]
files        = sys.argv[5:]

EXCL_RE = re.compile(exclude_pat, re.I) if exclude_pat else None

sessions = []
all_files_touched = collections.Counter()
all_branches = collections.Counter()
all_keywords = collections.Counter()
KEYWORD_STOP = set('the a an is are was were to from with for and or but if then in on at by of as it its this that we i you он она оно как что при для или это так уже но если то еще ещё надо нужно мне тебе да нет ну я там тут вот эту этот эта эти такой такая такие чтобы быть была было были был будет будут просто очень оч может можно нельзя'.split())

for fp in files:
    try:
        st = os.stat(fp)
        size = st.st_size
        mtime = datetime.datetime.fromtimestamp(st.st_mtime).strftime('%Y-%m-%d %H:%M')
    except Exception:
        continue

    first_user = ''
    last_assistant = ''
    branches = set()
    files_touched = set()
    sess_id = pathlib.Path(fp).stem

    try:
        with open(fp, 'r', encoding='utf-8') as f:
            for line in f:
                try:
                    rec = json.loads(line)
                except Exception:
                    continue
                msg = rec.get('message') or {}
                role = msg.get('role') or rec.get('type') or ''
                content = msg.get('content')

                # Extract text from various content formats
                text = ''
                if isinstance(content, str):
                    text = content
                elif isinstance(content, list):
                    parts = []
                    for c in content:
                        if isinstance(c, dict):
                            if c.get('type') == 'text':
                                parts.append(c.get('text',''))
                            elif c.get('type') == 'tool_use':
                                tname = c.get('name','')
                                tinput = c.get('input',{}) or {}
                                if tname == 'Bash':
                                    cmd = tinput.get('command','')
                                    m = re.search(r'git\s+checkout\s+(?:-b\s+)?(\S+)', cmd)
                                    if m: branches.add(m.group(1))
                                elif tname in ('Edit','Write','MultiEdit','NotebookEdit'):
                                    fpath = tinput.get('file_path','')
                                    if fpath:
                                        # Normalize: strip leading /Users/.../Projects/<slug>/ prefix
                                        norm = re.sub(r'^/Users/[^/]+/[^/]+/' + re.escape(project_slug) + '/', '', fpath)
                                        files_touched.add(norm)
                    text = ' '.join(parts)

                if role == 'user' and not first_user and text:
                    snippet = re.sub(r'\s+', ' ', text)[:300]
                    if not snippet.startswith('<'):  # skip system reminders
                        first_user = snippet
                if role == 'assistant' and text:
                    last_assistant = re.sub(r'\s+', ' ', text)[:200]
    except Exception:
        continue

    if EXCL_RE and (EXCL_RE.search(first_user) or any(EXCL_RE.search(b) for b in branches) or any(EXCL_RE.search(f) for f in files_touched)):
        continue

    if not first_user:
        continue  # skip empty/aborted sessions

    # Keywords from first_user
    for w in re.findall(r'[A-Za-zА-Яа-я][A-Za-zА-Яа-я0-9_-]{3,}', first_user.lower()):
        if w not in KEYWORD_STOP and len(w) >= 4:
            all_keywords[w] += 1

    for f in files_touched: all_files_touched[f] += 1
    for b in branches: all_branches[b] += 1

    sessions.append({
        'session_id': sess_id,
        'date': mtime,
        'size_bytes': size,
        'first_user': first_user,
        'last_assistant': last_assistant,
        'branches': sorted(branches)[:5],
        'files_touched_n': len(files_touched),
        'top_files': sorted(files_touched)[:5],
    })

# Sort by date desc
sessions.sort(key=lambda s: s['date'], reverse=True)

# === DIGEST (markdown, human-readable) ===
import yaml
out = []
out.append(f'# {project_slug} — session history digest')
out.append('')
out.append(f'> Auto-generated by `leadv2-history-primer.sh`. {len(sessions)} sessions kept after filter.')
if sessions:
    out.append(f'> Date range: {sessions[-1]["date"]} … {sessions[0]["date"]}')
out.append('')

out.append('## Top files touched (across all sessions)')
out.append('')
for f, n in all_files_touched.most_common(20):
    out.append(f'- `{f}` — {n}x')
out.append('')

out.append('## Top branches (across all sessions)')
out.append('')
for b, n in all_branches.most_common(15):
    out.append(f'- `{b}` — {n}x')
out.append('')

out.append('## Top keywords in user prompts')
out.append('')
out.append(', '.join(f'**{w}**({n})' for w, n in all_keywords.most_common(25)))
out.append('')

out.append('## Sessions (newest first)')
out.append('')
for s in sessions:
    head = s['first_user'][:160].replace('\n',' ')
    out.append(f'### {s["date"]} — {head}')
    if s['branches']:
        out.append(f'- branches: `{", ".join(s["branches"])}`')
    if s['top_files']:
        out.append(f'- files ({s["files_touched_n"]} total): {", ".join("`"+f+"`" for f in s["top_files"])}')
    if s['last_assistant']:
        out.append(f'- outcome: {s["last_assistant"]}')
    out.append('')

pathlib.Path(digest_path).write_text('\n'.join(out))

# === INDEX (yaml, machine-readable for /leadv2 prior-art lookup) ===
idx = {
    'meta': {
        'generated_at': datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ'),
        'project': project_slug,
        'session_count': len(sessions),
    },
    'top_files': [{'path': f, 'count': n} for f, n in all_files_touched.most_common(30)],
    'top_branches': [{'name': b, 'count': n} for b, n in all_branches.most_common(20)],
    'top_keywords': [{'word': w, 'count': n} for w, n in all_keywords.most_common(50)],
    'sessions': sessions,
}
pathlib.Path(index_path).write_text(yaml.safe_dump(idx, sort_keys=False, allow_unicode=True))

print(f'digest:  {digest_path}')
print(f'index:   {index_path}')
print(f'kept:    {len(sessions)} sessions')
PY
