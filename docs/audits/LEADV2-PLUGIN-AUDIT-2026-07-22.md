# Аудит плагина leadv2

Дата: 2026-07-22  
Проверенный commit: `57209a3` (`main`, совпадает с `origin/main`)  
Объект аудита: canonical repository, установленный Claude Code plugin cache и установленный Codex skill.

## Executive summary

Архитектурная идея правильная и уже в основном реализована: обычная lead-сессия и supervisor-сессия разделены; supervisor не владеет задачей, phase state или worktree, а запускает независимые Claude/Codex child-сессии; каждый child должен пройти полный Phase 0..8 и подтвердить завершение canonical Phase 8 receipt.

Но текущая версия **не готова к полностью unattended production-run**. Главный блокер — воспроизводимый macOS concurrency-баг в `mktemp`: тест mode isolation сейчас красный, а аналогичный небезопасный шаблон найден ещё в 24 runtime-местах. Второй блокер — Claude и Codex children по умолчанию запускаются с полным обходом permissions/sandbox. Третий системный пробел — plugin заявляет token-aware routing, но provider receipts не содержат фактических token/cache/credit counters, поэтому экономия пока не измеряется и routing не может учиться на реальной стоимости.

Итоговая оценка:

| Область | Оценка | Вердикт |
|---|---:|---|
| Архитектура lead/supervisor | 8/10 | Правильная модель владения и изоляции |
| Phase 0..8 completion contract | 8/10 | Хороший fail-closed receipt и merge gate |
| Provider routing | 7/10 | Разумные defaults и live quota fallback, но нет cost/outcome learning |
| Token economy | 5/10 | Есть полезные guards, но нет достоверного per-child учета и остаются противоречивые эвристики |
| Runtime safety | 4/10 | `mktemp` collision и unsafe permission defaults |
| Тестирование | 6/10 | Сильные offline suites, но aggregate run сейчас RED и не полностью герметичен |
| Packaging/release | 3/10 | Версия и cache paths hardcoded на `0.1.0`, документация устарела, runtime dependencies не проверяются |

**Release verdict: NO-GO для unattended supervisor до закрытия P0.** Для контролируемых запусков с человеком рядом архитектура уже пригодна после локального исправления `mktemp` и явного включения safe permission mode.

## Что проверялось

- `claude plugin validate plugins/leadv2`
- `claude plugin details leadv2`
- parity canonical/runtime через `leadv2-drift-guard.sh`
- наличие и byte parity Codex skill
- provider router, Codex runner, spawner, supervisor reconciliation, PID isolation и Phase 8/merge suites
- hooks, session runners, state/receipt flow, sync/release paths
- token/cache instrumentation и фактический live quota snapshot
- macOS/runtime portability и declared dependencies
- актуальность README/installation/architecture docs

Полный платный Claude/Codex production task намеренно не запускался: это потратило бы quota и могло бы пройти deploy phase. Offline runners используют fake provider CLIs и хорошо проверяют orchestration contract, но не доказывают реальную auth/model/CLI compatibility. Поэтому live canary остаётся обязательным release gate.

## Что работает

### 1. Plugin установлен и синхронизирован

Доказательства:

- Native validation: `Validation passed`.
- Installed inventory: 38 skills, 3 agents, 10 hook event types, 0 MCP, 0 LSP.
- Projected always-on context: около 1,873 tokens/session.
- `leadv2-drift-guard.sh --quiet --json`: `{"drift":false,"entries":[]}`.
- Codex skill присутствует в `~/.codex/skills/source-command-leadv2/SKILL.md` и byte-identical canonical copy.

Это доказывает, что merged code дошёл до установленного runtime и Codex skill не остался только в repository.

### 2. Lead и supervisor действительно разделены

В `plugins/leadv2/hooks/leadv2-mode-isolation.sh:26-75` task определяется только через явный `LEADV2_TASK_ID` или PID ancestry. Fallback на `sessions[0]` отсутствует. Supervisor marker проверяется до task resolution.

`plugins/leadv2/hooks/leadv2-supervise-fanout-guard.sh:153-176` применяет supervisor guard только к точному owning PID. Чужая обычная lead-сессия в том же repository не блокируется.

Тесты:

- supervisor/lead PID isolation: **12/12 PASS**;
- supervisor reconciliation: **17/17 PASS**;
- parallel leads выбирают собственную PID row, а не первую shared row.

Это соответствует требуемой модели:

```text
Supervisor session
  owns: registry observation, routing, questions, completion receipts
  does not own: task, worktree, phase, child context

Independent child lead session
  owns: one task, one worktree, Phase 0..8, deploy/verify/close evidence
```

### 3. Child — полноценная leadv2-сессия, а не one-shot worker

`plugins/leadv2/scripts/leadv2-fanout.sh:737-739` запрещает fallback на raw one-shot CLI. Claude и Codex направляются в provider-neutral full-cycle runners.

`plugins/leadv2/scripts/leadv2-session-runner.sh:173-193` и `plugins/leadv2/scripts/leadv2-codex-session-runner.sh:57-78` признают task завершённой только при наличии local `phase8-passed.flag` либо валидного shared completion receipt со schema/status/task/assertions `7/7`.

Положительные тесты:

- routing: **8/8 PASS**;
- Codex full-cycle runner: **6/6 PASS**;
- autonomous spawner: **4/4 PASS**;
- Phase 8 merge/completion: **26/26 PASS**.

Особенно хорошо, что успешный model turn без Phase 8 proof возвращает `INCOMPLETE`, а два turns без phase/git/handoff progress останавливают resume-loop до полного six-attempt budget.

### 4. Routing policy в целом разумная

Текущая policy в `plugins/leadv2/config/session-routing.yaml`:

- Light → Codex Luna / low;
- Standard → Codex Terra / medium;
- Heavy/Strategic → Claude Opus / high;
- `auth, rls, safety, publish, security, arch` принудительно остаются на Claude;
- при отсутствии Codex CLI/skill/auth либо при превышении quota threshold есть Claude fallback.

Это согласуется с текущей официальной рекомендацией OpenAI: Luna — для лёгких/high-volume задач, Terra — everyday balance, Sol/top reasoning — для сложных задач. См. [Codex pricing and model guidance](https://learn.chatgpt.com/docs/pricing).

### 5. Сильный Phase 8 и merge safety

`plugins/leadv2/scripts/leadv2-phase8-assert.sh:354-437`:

- требует 7 hard assertions;
- пишет local flag;
- атомарно пишет shared completion receipt;
- fail-closed, если shared receipt не записан;
- публикует `closed` bus event как wake-up optimization, но receipt остаётся source of truth.

Merge tests доказали conflict blocker, ff-only race protection, queue lock ownership и release lock before deploy.

### 6. Некоторые token fixes уже правильные

- Fake standalone cache warmer теперь default no-op: отдельный API call не может прогреть точный Claude Code prefix.
- Child model/effort выбирается до старта и остаётся стабильным внутри session.
- Session runners используют stable Claude session ID / Codex thread ID и resume, а не создают новую cold session на каждый turn.
- Resume-loop имеет no-progress circuit breaker.
- Auto-status работает раз в 30 tool calls и ограничен 12 строками.
- Task anchor задуман как full first injection + compact repeat.

Это согласуется с официальной механикой Claude prompt caching: cache — exact prefix, model и effort имеют отдельные caches, а разные worktree directories не делят prefix. См. [Claude Code prompt caching](https://code.claude.com/docs/en/prompt-caching).

## Что не работает или работает ненадёжно

### P0 — macOS-небезопасные `mktemp` templates

Воспроизводимый failure:

```text
mktemp: mkstemp failed on /tmp/leadv2-task-anchor-XXXXXX.json: File exists
```

В `/tmp` уже существует literal zero-byte file `/tmp/leadv2-task-anchor-XXXXXX.json`. На BSD/macOS run из `X` должен завершать template; suffix `.json` после `XXXXXX` приводит к literal/fixed target и collision.

Текущий тест:

```text
test-hook-token-mode-isolation.sh: PASS=6 FAIL=2
- supervisor/child prompt contexts leaked
- task anchor token cap failed
```

Причина находится в `plugins/leadv2/hooks/leadv2-task-anchor.sh:40`:

```bash
mktemp /tmp/leadv2-task-anchor-XXXXXX.json
```

Статический аудит нашёл **25 unsafe suffixed templates** в runtime: 7 hooks и 18 scripts. Среди критичных путей:

- task anchor;
- pre/post compact state;
- truth-card injection;
- background watchdog gate/enforce;
- auto-status;
- judge, premortem, cost flush, coverage, state atomic writes.

Риск не только в тесте. Hooks часто имеют `trap 'exit 0' ERR`, поэтому collision превращается в тихий fail-open: prompt проходит без anchor/guard context.

Требуемое исправление: единый portable helper на `mktemp -d "${TMPDIR:-/tmp}/leadv2.XXXXXX"` + fixed filenames внутри директории, либо Python `tempfile.mkstemp(suffix=...)`. После этого — parallel stress test не менее 100 concurrent invocations.

### P0 — children по умолчанию обходят sandbox/permissions

Claude default:

- `plugins/leadv2/scripts/leadv2-session-runner.sh:111` → `bypassPermissions`.

Codex default:

- `plugins/leadv2/scripts/leadv2-codex-session-runner.sh:153-165` → `--dangerously-bypass-approvals-and-sandbox` при default `LEADV2_CODEX_BYPASS_APPROVALS=1`.

При этом child проходит deploy и live verification. Hook guardrails полезны, но не заменяют OS/workspace boundary, особенно для Codex child, где Claude plugin hooks не являются полным enforcement layer.

Рекомендуемый default:

- Claude: `acceptEdits`/scoped allow rules;
- Codex: `--sandbox workspace-write`;
- deploy/network/secrets escalation — отдельный short-lived capability только в Phase 6/7;
- unsafe bypass — только явный `LEADV2_UNSAFE_AUTOPILOT=1`, с loud receipt.

### P0 — отсутствует реальный provider canary

Fake-CLI tests хорошо проверяют state machine, но не проверяют:

- реальные OAuth/session quotas;
- актуальные Claude/Codex flags;
- Codex JSONL schema `thread.started`/`turn.completed`;
- реальные model aliases;
- hook behavior внутри headless child;
- end-to-end Phase 8 на обеих provider paths.

До unattended release нужен дешёвый non-deploy canary task для Claude Sonnet и Codex Luna, который создаёт sandbox repo, проходит все phase receipts и не имеет внешних side effects.

### P1 — нет фактического per-child token accounting

Provider receipts в обоих runners содержат provider, model, effort, run_id, status, exit code и attempt, но **не содержат**:

- input/output tokens;
- cache read/cache creation tokens;
- reasoning tokens/credits;
- duration/turn count;
- quota before/after;
- task outcome/quality score.

Codex уже возвращает `turn.completed.usage`, а Claude stream-json содержит usage, но runner их не агрегирует в receipt.

Во время аудита `leadv2-token-watch.sh` показал:

```text
Codex Plus: 44% used, 56% remaining
Anthropic Team: 5h=62%, weekly=7%
Claude telemetry: 0 parseable recent files
```

Это snapshot разных provider windows; сравнивать 44% и 62% как «кто дешевле» нельзя. Более важно, что plugin не смог показать token/cache usage ни для одной child-сессии.

Следствие: route bandit может оптимизировать предполагаемые costs/outcomes, но не доказанную `quality / effective token` эффективность.

### P1 — token discipline содержит недоказанные эвристики

`plugins/leadv2/skills/leadv2-token-discipline/SKILL.md:94-117` всё ещё содержит правила вроде:

- Opus `>30M tokens/24h`;
- один Opus spawn `≈20-50K tokens`;
- compact threshold по `turns × estimated cost` или «по ощущению».

При этом `leadv2-token-watch.sh` справедливо говорит, что subscription limits являются window/model/context dependent и нельзя выдумывать daily token caps. Skill и runtime противоречат друг другу.

Нужно удалить абсолютные эвристики и принимать решения только по provider-owned quota, фактическому usage receipt, cache read/write ratio и measured task-class percentiles.

### P1 — nested-spawn cap документирован, но не исполняется как написано

`nested-spawn-policy.yaml` задаёт `max_per_task: 3`, а skill также обещает максимум 3 nested spawns per task. Однако runtime hook реально ограничивает `max_subruns_per_parent: 8`; поле `max_per_task` разбирается для allowlist, но не используется при подсчёте.

Итого один caller может сделать до 8 nested sub-runs, а несколько callers — ещё больше. Это прямой multiplicative token risk. Официальные docs обоих providers подтверждают, что каждый subagent имеет собственный context/tool work и увеличивает usage: [Codex subagents](https://learn.chatgpt.com/docs/agent-configuration/subagents), [Claude cost guidance](https://code.claude.com/docs/en/costs).

Нужно иметь один исполняемый лимит: default `max_nested_per_task=3`, `max_depth=1`, write-capable nested roles denied. Счётчик должен быть per task, а не per caller.

### P1 — concurrency defaults слишком высоки для экономичного supervisor

Supervisor UI позволяет выбрать до 5 tasks, а `leadv2-fanout.sh` имеет default `hard_limit=20`. Каждый child — отдельное полное context window, а затем может запускать собственные phase helpers.

Для token-first режима разумный default:

- 2 concurrent write/full-cycle children;
- до 3 read-only probes;
- hard maximum 4 без explicit override;
- новый child стартует только если live quota headroom и measured remaining budget достаточны.

### P1 — runtime portability не соответствует README

README называет mandatory только Claude Code и subscription/API key. Реальный runtime использует:

- PyYAML: около 130 `import yaml` sites;
- `flock(1)` в обоих session runners и ряде state/cost scripts;
- GNU `timeout` в Phase 8 и других paths;
- `readlink -f` и Bash `mapfile`, которых нет в default macOS toolchain.

На этой машине всё работает только потому, что установлены Homebrew `flock`, modern Bash/coreutils и user-site PyYAML. SessionStart installer лишь копирует `lv2` dispatcher и silent fail-open; doctor/preflight отсутствует.

Это вероятная причина класса «Claude ругается, что что-то не так» на другой машине или clean environment.

### P1 — tests не полностью герметичны

`run-core-offline.sh` заявлен как reproducible/no-network suite, но:

- aggregate suite сейчас RED из-за `mktemp` collision;
- во время аудита запуск component suites изменил 9 tracked control-plane symlinks в `docs/leadv2/`; изменения были восстановлены;
- `HEAD` уже содержит tracked symlinks, указывающие на удалённый `/var/folders/.../tmp.../state-lock`, то есть clean git status не означает healthy runtime links.

Acceptance criterion для core suite должен включать не только exit 0, но и `git status --porcelain` byte-identical до/после. Каждый suite должен иметь собственный `TMPDIR`, `LEADV2_STATE_ROOT`, HOME и cleanup trap.

### P1 — release/version path hardcoded на `0.1.0`

Manifest всё ещё `0.1.0`, хотя supervisor-v2 является существенным architecture change. `leadv2-plugin-sync.sh`, `leadv2-drift-guard.sh`, `leadv2-outcome-watch.sh` и tests содержат literal cache path `.../0.1.0`.

Следующее обычное version bump легко сломает sync/drift detection. Version должна читаться из manifest/installed registry единожды. Нужны immutable artifact, release hash и rollback pointer.

### P1 — документация описывает старый plugin

Примеры противоречий:

- README и installation говорят только о Codex GPT-5.5 «2nd brain» в Plan/Review;
- current runtime использует GPT-5.6 Luna/Terra как полноценного lead child;
- Architecture говорит main lead=Sonnet и не описывает distinct supervisor;
- command doc говорит Opus main и уже описывает full-cycle supervisor;
- examples всё ещё pin `gpt-5.5`;
- README заявляет 40+ guards и 25+ skills, installed inventory фактически 76 hook commands и 38 skills.

Документация сейчас может привести к неправильной установке, model policy и ожиданиям по расходу quota.

### P2 — слишком много hook processes

В `hooks.json` зарегистрировано 76 command hooks:

- один Bash tool call может запустить до 9 PreToolUse + 8 PostToolUse processes;
- один Agent call — до 12 pre + 8 post processes.

Это не обязательно прямой token cost, но это latency, повторный parse state/YAML, больше race surfaces и больше stderr, который затем попадает в context. Следующий уровень — один dispatcher process на event, который один раз читает payload/state и применяет все rules in-process.

### P2 — package содержит dev/runtime ballast

Plugin tree около 25 MB; основная масса — `scripts/node_modules` и `.mypy_cache`. Dev caches не должны попадать в plugin artifact/sync. Playwright runtime лучше оформить как отдельную optional dependency либо минимальный pinned bundle.

## Реальная экономика токенов

### Codex не обязательно «тратит меньше токенов»

Корректная формулировка:

1. Codex и Claude имеют разные subscription buckets и model-specific limits.
2. Luna/Terra могут давать больше полезной работы на единицу включённого allowance для лёгких/routine задач.
3. Это не доказывает, что Codex генерирует меньше raw tokens на одинаковую задачу.
4. API key mode оплачивается per token; subscription mode ограничивается provider-specific windows/credits.
5. Поэтому преимущество supervisor routing — использование независимых quota pools и подходящей модели, а не магическое уменьшение token count.

OpenAI прямо позиционирует Luna как higher-usage модель для lighter/high-volume workloads и Terra как everyday balance. Anthropic рекомендует Sonnet для большинства coding tasks и Opus только для сложной архитектуры/многошагового reasoning, потому что Opus расходует существенно больше quota: [Claude model guidance](https://support.claude.com/en/articles/14552983-models-usage-and-limits-in-claude-code).

### Где сейчас основной расход

По степени влияния:

1. **Число независимых full child sessions.** Каждая имеет свой system prompt, tools, plugin context и Phase 0..8 history.
2. **Nested phase agents.** Каждый строит отдельный context и cache.
3. **Длина child session.** Полная история повторно отправляется каждый turn; cache снижает цену обработки, но context всё равно растёт.
4. **Opus/high effort на routine work.** Thinking tokens оплачиваются/учитываются как output usage; Anthropic указывает, что budget может достигать десятков тысяч tokens на request.
5. **Большие phase skills.** Installed projection даёт примерно 38K on-invoke instructions только для типичного backbone `leadv2 + plan + premortem + build + review + deploy + verify + close + reflect`, до task/code/tool context.
6. **Cache misses из-за worktrees.** Claude cache effectively scoped к machine+directory; разные worktrees одного repo не делят prefix.
7. **Повторные resume attempts без прогресса.** Здесь уже есть полезный circuit breaker.

### Что экономит tokens реально

Рекомендуемый порядок:

1. **Supervisor на Sonnet/medium, Opus только как escalation judge.** Supervisor не должен читать код или решать implementation; Opus нужен для конфликтов routing, architecture/high-risk decisions.
2. **Сохранить все Phase 0..8 states, но сделать LLM gates conditional.** Light task всё равно получает receipt каждого phase, однако History/Premortem/Review могут быть deterministic no-op или одним Luna/Terra pass. Heavy/high-risk остаётся полным dual-model flow.
3. **Default concurrency=2.** Параллелизм экономит wall time, но почти линейно умножает independent context usage.
4. **Фактически enforce nested cap=3 per task.** Не 8 per caller.
5. **Не менять model/effort внутри child.** Это уже сделано правильно: model/effort switch ломает Claude cache.
6. **Compact только на естественной границе phase/task.** `/compact` перестраивает conversation cache, но уменьшает дальнейшую историю; для unrelated task нужен новый child/clear.
7. **Сжать phase skill bodies.** Оставить короткий executable contract, а редкие recovery/reference детали загружать только по trigger.
8. **Передавать paths, не contents.** Логи фильтровать hooks/scripts до model context; returns из subagents ограничить structured summary + artifact path.
9. **Worktree только для write child.** Read-only scout/reviewer может работать как fork/same-directory session и использовать общий prefix cache; write tasks сохраняют isolation.
10. **Routing по measured efficiency.** Накапливать `successful_phase8 / effective_usage` отдельно по task class, provider, model, effort и risk tag.

Официальные основания: [Claude prompt caching](https://code.claude.com/docs/en/prompt-caching), [Claude cost reduction](https://code.claude.com/docs/en/costs), [Codex subagents](https://learn.chatgpt.com/docs/agent-configuration/subagents).

## Предлагаемый step-up: leadv2 0.2

### Milestone 0 — Make it safe and green

1. Исправить все 25 unsafe `mktemp` templates.
2. Safe permission/sandbox defaults; explicit unsafe escalation only.
3. Изолировать каждый test через TMPDIR/HOME/state root.
4. Core suite должен проходить два раза подряд и parallel x10 без dirty worktree.
5. Удалить tracked ephemeral symlinks; генерировать runtime links при install/init и игнорировать их в git.

Release gate:

```text
claude plugin validate: PASS
run-core-offline.sh: all suites PASS
parallel hook isolation x100: PASS
git status before == git status after
unsafe mktemp scan: 0
default bypass permission scan: 0
```

### Milestone 1 — Measured token control

Ввести единый `provider_receipt.v2`:

```yaml
provider: claude|codex
model: ...
effort: ...
task_class: ...
risk_tags: [...]
attempts: 1
turns: 12
duration_ms: ...
usage:
  input_tokens: ...
  output_tokens: ...
  cache_read_input_tokens: ...
  cache_creation_input_tokens: ...
  reasoning_tokens: ...
  credits: ...
quota_before: ...
quota_after: ...
phase8_passed: true|false
quality_score: ...
```

Claude runner должен агрегировать usage из stream-json, Codex runner — из `turn.completed.usage`. Missing telemetry допустима как `null`, но никогда как `0`.

После 20+ реальных tasks считать p50/p90 по class/provider/model и только затем менять routing thresholds. Цели экономии должны быть относительными к baseline, а не выдуманными absolute token caps.

### Milestone 2 — Lifecycle profiles без потери guards

Добавить profile resolver:

| Profile | Phase state | Expensive model gates |
|---|---|---|
| Light | Все 0..8 | Luna/Terra, single plan/review, deterministic premortem, no Opus unless risk trigger |
| Standard | Все 0..8 | Terra/Sonnet, one independent reviewer, Opus on disagreement |
| Heavy/Strategic | Все 0..8 | Full Opus plan, dual-provider review, security/risk specialists |

Каждый skipped expensive action должен оставлять structured `phase_receipt: skipped_by_policy`, поэтому guard chain и auditability сохраняются.

### Milestone 3 — Runtime simplification

1. Один hook dispatcher на event вместо 76 independent commands.
2. Один stdlib control-plane runtime или versioned plugin venv в `${CLAUDE_PLUGIN_DATA}`.
3. Убрать обязательность GNU `flock/timeout/readlink -f` либо проверять их через `lv2 doctor`.
4. Уменьшить artifact: исключить `.mypy_cache`, `.pytest_cache`, `__pycache__`, `.pyc`; Playwright оформить отдельно.
5. Свести пять copies scripts к canonical artifact + installed immutable cache; project repos должны иметь только tiny dispatcher/overrides.

### Milestone 4 — Release engineering and live canary

1. Bump manifest на `0.2.0`.
2. Все cache paths вычислять из manifest/installed registry, без literals.
3. Обновить README, installation, architecture, model matrix и examples.
4. Добавить `lv2 doctor --json`:
   - Claude/Codex versions and auth;
   - model availability;
   - Python/PyYAML/Bash/tool compatibility;
   - plugin/Codex skill drift;
   - permission mode;
   - writable control plane;
   - quota readers.
5. Два real canaries на sandbox repo:
   - Claude Sonnet child → Phase 8 receipt;
   - Codex Luna child → Phase 8 receipt;
   - no deploy/network side effects;
   - usage receipt non-null;
   - second run proves resume/idempotency.

## Приоритетный backlog

| Priority | Работа | Почему сейчас |
|---|---|---|
| P0 | Portable temp API + concurrency stress | Текущий smoke RED; hooks fail-open |
| P0 | Safe permission defaults | Unattended child имеет слишком широкие права |
| P0 | Real Claude/Codex sandbox canaries | Offline tests не доказывают provider compatibility |
| P1 | Provider receipt v2 с actual usage/cache | Без этого token optimization недоказуема |
| P1 | Enforce 3 nested runs per task | Убирает прямой multiplicative burn |
| P1 | Concurrency default 2 | Самый простой контроль independent contexts |
| P1 | Hermetic tests + clean-worktree assertion | Сейчас suite может менять canonical state links |
| P1 | Runtime doctor/dependency contract | Устраняет machine-specific «что-то не так» |
| P1 | Version-derived cache paths | Следующий release иначе хрупкий |
| P1 | Docs/model policy update | Текущие инструкции ведут к старому GPT-5.5 flow |
| P2 | Phase profiles | Большая экономия на Light/Standard без снятия guards |
| P2 | Hook dispatcher | Меньше процессов, races и noisy context |
| P2 | Compact skill contracts | Уменьшение on-invoke context |
| P2 | Artifact slimming | Быстрее install/sync, меньше drift surface |

## Финальный ответ на главный вопрос

Да, желаемая схема реализуема и базово уже реализована правильно:

- основная Claude Code session остаётся supervisor;
- supervisor не проходит phases за children и не забирает их task state;
- каждый child — отдельная полноценная leadv2 lead session;
- provider/model выбирается по class, risk и live quota;
- завершение подтверждается общим Phase 8 contract.

Главный следующий шаг — не добавлять ещё больше агентов или guards. Нужно превратить текущий сложный prototype в измеряемый runtime: закрыть portable temp/permission P0, собирать actual usage receipts, снизить concurrency/nested fanout, сделать conditional phase profiles и подтвердить обе provider paths реальными sandbox canaries. После этого можно честно оптимизировать tokens по данным, а не по ощущениям.

