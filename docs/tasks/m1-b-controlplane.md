# M1 / B: control plane и деплой

Сначала прочитай `docs/contracts.md` (общие правила, владельцы папок) и `docs/roadmap.md`.
Твои папки: `controlplane/`, `deploy/`. Worktree: `../maccheri-b`, ветка `task/controlplane`.

## Цель

Публичный control plane команды. Он принимает вебхуки GitHub, раздаёт работу маковым хостам, выдаёт
сессии симулятора, передаёт сигнализацию WebRTC и выдаёт учётные данные TURN. Разворачивается
на сервере пользователя: VPS и домен у него есть.

## Что есть

- Vapor 4 (`controlplane/`): вебхук GitHub `workflow_job` с проверкой HMAC, `JobQueue` в памяти,
  `GitHubAppProvisioner` (JWT RS256, installation tokens, `generate-jitconfig`),
  `/agent/v1/lease` и `complete` с токенами агента из env. 8 тестов XCTVapor.
- Контракты — в `protocol/Sources/MaccheriProtocol` (`Auth`, `Hosts`, `Sessions`, `Signaling`, `Work`).

## Что сделать

1. **Хранилище.** Fluent на SQLite (один файл на томе): пользователи, инвайты, токены (храни хеши),
   хосты, сессии, CI-задания. Очередь CI переведи с памяти на БД, чтобы она переживала перезапуск.
2. **Аутентификация** (`Auth.swift`):
   - первый админ создаётся командой Vapor, например `controlplane create-invite --admin`, или через env;
   - инвайты одноразовые и с истечением срока, обмениваются на bearer-токен.
3. **Хосты** (`Hosts.swift`):
   - регистрация с токеном пользователя (хост принадлежит ему), выдача токена агента;
   - heartbeat хранит `HostCapacity` и `lastSeen`; хост без heartbeat дольше `offlineAfterSeconds` — офлайн;
   - `GET /v1/hosts`.
4. **Работа** (`Work.swift`):
   - long-poll `/agent/v1/work` до `longPollSeconds`, отдаёт `WorkLease.ci` или `.simulator`;
   - подбор хоста: онлайн, есть ёмкость, подходят метки и устройство, для симулятора лучше прогретый;
   - отчёты о состоянии сессии, `complete` для CI;
   - старый `/agent/v1/lease` держи, пока A не скажет, что перешёл.
5. **Сессии** (`Sessions.swift`):
   - create, get, delete, машина состояний queued → starting → ready → ended/failed;
   - `expiresAt` по умолчанию 60 мин, ограничение по сессиям на пользователя;
   - если хост пропал во время сессии, сессия переходит в `failed`.
6. **Сигнализация** (`Signaling.swift`):
   - WebSocket `/v1/sessions/{id}/signal?role=&token=`, отдельный токен на каждую роль. Токен
     в query, потому что основной клиент — браузер; в логах его маскировать;
   - пересылка кадров другой стороне как есть, очередь до подключения второй стороны;
   - закрытие при завершении сессии.
7. **TURN:** coturn с `use-auth-secret`, временные учётные данные в `iceServers` (STUN + TURN UDP/TCP + TLS 443).
8. **Веб-клиент.** Раздавай `web/dist` (D) с корня домена через `FileMiddleware` или Caddy,
   SPA-fallback на `index.html`. Положи примеры JSON всех ответов и запросов из контрактов
   в фикстуры тестов (`controlplane/Tests/.../Fixtures/*.json`) и проверяй, что сервер кодирует ровно
   так. По ним D сверяет TypeScript-типы.
9. **Деплой** (`deploy/`):
   - Dockerfile (многоэтапная сборка Swift на Linux);
   - docker-compose: controlplane, Caddy (автоматический HTTPS), coturn;
   - `.env.example`, бэкап SQLite, README.

   **Разворачивай только с пользователем.** Попроси у него сервер, домен, DNS и доступ. Секреты
   не коммить. Сначала всё проверь локально через `docker compose up`.
10. **Тесты XCTVapor:**
   - аутентификация, хосты, подбор хоста;
   - сессия от начала до конца с фейковым агентом;
   - пересылка сигнализации через два WebSocket-клиента;
   - истечение сессий, офлайн хостов.

## Готово, когда

- Локально через `docker compose up` весь сценарий из `docs/contracts.md` проходит с фейковым агентом
  и фейковым viewer (тесты или скрипт).
- Сервис развёрнут на сервере пользователя по HTTPS, `GET /healthz` отвечает, TURN проверен
  через `turnutils_uclient` или trickle-ice.
- Отправь A, C и D публичный URL и способ получить инвайт.

## Не делать

Оплату, публичную регистрацию, сам веб-клиент (его пишет D; от тебя — раздача и фикстуры).
GitHub App регистрирует C вместе с пользователем: от тебя нужна поддержка вебхука и настроек приложения
через env.
