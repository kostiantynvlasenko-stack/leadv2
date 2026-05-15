#!/usr/bin/env bash
# Classify a founder question into one of: status | judgment | explanation | action_request | chat
# Pure regex. No LLM. Russian + English keywords.
#
# Usage: leadv2-founder-question-classify.sh "<question text>"
# Output: one line — class name + suggested action

set -euo pipefail
trap 'exit 0' ERR

Q="${1:-}"
[[ -z "$Q" ]] && { echo "chat"; exit 0; }

# Lowercase + strip punctuation for matching
Q_NORM="$(echo "$Q" | tr '[:upper:]' '[:lower:]' | tr -d '?!.,;:')"

# Action request — most specific, check first
if echo "$Q_NORM" | grep -Eq '\b(сделай|делай|сделать|поменяй|измени|переделай|добавь|удали|почини|fix|change|add|remove|implement|do +it|let.+do|переключ)\b'; then
  echo "action_request: register as new task or amend current plan"
  exit 0
fi

# Status / progress query
if echo "$Q_NORM" | grep -Eq '\b(где (мы|стенд)|статус|status|progress|прогресс|какая фаза|на какой|что сейчас|where are|еще долго|сколько осталось|how long|еще не|done already|закончил|готово)\b'; then
  echo "status: tail active.yaml + STATE.md tail"
  exit 0
fi

# Explanation request
if echo "$Q_NORM" | grep -Eq '\b(почему|зачем|как (работает|устроен|настроен)|объясни|расскажи|why|how does|explain|what is|откуда|where (does|is)|как ты)\b'; then
  echo "explanation: spawn Agent(subagent_type=Explore, model=haiku)"
  exit 0
fi

# Judgment question — risk / safety / correctness
if echo "$Q_NORM" | grep -Eq '\b(стоит ли|стоит сейчас|safe|risky|правильно|верно|ок|окей|норм|good idea|should (i|we|you)|лучше ли|хорошая идея|плохая идея|опасно|рискованно|может быть лучше|стоит делать|нужно ли|надо ли|есть смысл)\b'; then
  echo "judgment: spawn Skill(leadv2-judge) mode=question with Opus"
  exit 0
fi

# Default — chat
echo "chat: one-line ack, offer to register as task if needed"
