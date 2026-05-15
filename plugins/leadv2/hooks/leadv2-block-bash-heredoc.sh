#!/usr/bin/env bash
# PreToolUse:Bash — block large heredoc bodies in Bash commands.
# Heredocs >2KB in bash live in transcript forever. Force Write tool instead.
set -euo pipefail
trap 'echo "[$(basename "$0")] error at line $LINENO" >&2; exit 0' ERR

INPUT="$(cat 2>/dev/null || true)"
[[ -z "$INPUT" ]] && exit 0

CMD=$(printf '%s' "$INPUT" | python3 -c "
import sys, json
try:
    r = json.loads(sys.stdin.read())
    print(r.get('tool_input', {}).get('command', ''))
except Exception:
    pass
" 2>/dev/null || true)

[[ -z "$CMD" ]] && exit 0

# Allow explicit override
if printf '%s' "$CMD" | grep -q '# bash-guard: allow'; then exit 0; fi

LEN=${#CMD}
[[ $LEN -lt 2048 ]] && exit 0

# Detect heredoc patterns
if printf '%s' "$CMD" | grep -Eq "<<-? *['\"\\\\]?[A-Za-z_][A-Za-z0-9_]*"; then
  cat <<MSG >&2
[leadv2-block-bash-heredoc] Bash command is ${LEN} bytes with a heredoc body.
Heredocs in Bash live in the transcript forever (~${LEN} chars × every future turn).

Use the Write tool instead:
  Write({ file_path: "/abs/path/file.md", content: "..." })

To override (rare): append "# bash-guard: allow" to the command.
MSG
  exit 2
fi

exit 0
