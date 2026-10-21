# Control plane: данные, состояния, правила

Как устроен control plane внутри. Контракт API — в `protocol/Sources/MaccheriProtocol`, примеры JSON —
в `Tests/Fixtures` (генератор: `swift run --package-path Tools/fixtures generate-fixtures`). Здесь то,
что от фреймворка не зависит: таблицы, переходы состояний, подбор хоста, фоновые проверки.

Один процесс, одна база SQLite на томе (`DATABASE_PATH`, по умолчанию `/data/maccheri.sqlite`, режим WAL).
Состояние, которое не переживает перезапуск, — только открытые WebSocket сигнализации и ждущие long-poll;
клиенты переподключаются сами.

## Доступ

Мини-прод (`docs/contracts.md`, «Доступ в мини-проде»): все `/v1/*`, включая `enroll`, принимают
`Authorization: Bearer <MACCHERI_SHARED_TOKEN>`. Такой запрос выполняется от встроенного пользователя-админа
`team` (id `00000000-0000-0000-0000-000000000001`, создаётся при старте). Личные токены из инвайтов
тоже работают, но необязательны. `/agent/v1/*` принимает только токен хоста из `enroll`: он определяет хост.

## Таблицы

Все `id` — UUID, время — UTC. Токены генерируются как `<префикс>_<32 случайных байта в base64url>`,
в базе лежит только `sha256(token)` в hex. Префикс нужен, чтобы токен было видно в логах и сканерах секретов.

| Префикс | Что |
|---|---|
| `mci_` | код инвайта |
| `mcu_` | токен пользователя |
| `mca_` | токен агента (хоста) |
| `mcs_` | токен сигнализации (на сессию и роль) |

### `users`
| Поле | Тип | |
|---|---|---|
| id | uuid PK | |
| name | text | отображаемое имя из `RedeemInviteRequest.name` |
| is_admin | bool | |
| created_at | timestamp | |

### `user_tokens`
| Поле | Тип | |
|---|---|---|
| id | uuid PK | |
| user_id | uuid FK → users, cascade | |
| token_hash | text unique | sha256 |
| created_at, last_used_at | timestamp | `last_used_at` обновляется не чаще раза в минуту |

Отзыв — удаление строки. Срока жизни нет (M1).

### `invites`
| Поле | Тип | |
|---|---|---|
| id | uuid PK | |
| code_hash | text unique | sha256 кода |
| is_admin | bool | пользователь, который его обменяет, станет админом |
| created_by | uuid FK → users, null | null — создан командой `create-invite` или из env |
| expires_at | timestamp | по умолчанию +7 дней (`INVITE_TTL_HOURS`) |
| used_at | timestamp null | |
| used_by | uuid FK → users, null | |

Обмен: в одной транзакции `UPDATE invites SET used_at=… WHERE code_hash=? AND used_at IS NULL AND expires_at>now`;
если затронута 0 строк — `404` (не различаем «нет», «использован» и «истёк»). Создавать инвайты могут
только админы (`403` остальным). Первый админ: команда `controlplane create-invite --admin` печатает код,
либо env `ADMIN_INVITE=<код>` при старте создаёт такой инвайт, если в базе ещё нет ни одного админа.

### `hosts`
| Поле | Тип | |
|---|---|---|
| id | uuid PK | `HostEnrollment.hostID` |
| owner_id | uuid FK → users | кто регистрировал |
| name | text | |
| hardware | json | `HostHardware` |
| agent_token_hash | text unique | sha256 |
| agent_version | text null | из heartbeat |
| capacity | json null | `HostCapacity` из последнего heartbeat |
| last_seen_at | timestamp null | heartbeat или любой запрос `/agent/v1/...` |
| created_at | timestamp | |

`online = last_seen_at != null && now - last_seen_at <= offlineAfterSeconds` (45 с), вычисляется, не хранится.
Повторная регистрация того же мака создаёт новый хост; старый можно удалить (в M1 — вручную).

### `sessions`
| Поле | Тип | |
|---|---|---|
| id | uuid PK | |
| user_id | uuid FK → users | |
| state | text | `SessionState` |
| requested_device | json null | из `CreateSessionRequest.device` |
| requested_host_id | uuid null | из `CreateSessionRequest.hostID` |
| device | json null | выбранное устройство, с `starting` |
| host_id | uuid FK → hosts, null | с `starting` |
| image | text null | с `starting` |
| viewer_token, host_token | text | `mcs_…`, создаются сразу |
| created_at | timestamp | |
| leased_at, ready_at, ended_at | timestamp null | |
| expires_at | timestamp | `created_at + SESSION_MINUTES` (60) |
| message | text null | причина `ended` / `failed` |
| host_notified | bool | агент знает о завершении (410 или свой отчёт `ended`/`failed`) |

Токены сигнализации хранятся открыто: они живут не дольше сессии, их нужно отдавать в каждом
`GET /v1/sessions/{id}` и они бесполезны после её завершения. Индекс: `(state, created_at)`, `(host_id, state)`.

### `ci_jobs`
| Поле | Тип | |
|---|---|---|
| id | uuid PK | `JobLease.jobID` |
| github_job_id | int64 unique | `workflow_job.id` |
| repository | text | |
| installation_id | int64 | |
| labels | json | `[String]` в нижнем регистре |
| state | text | `pending` → `leased` → `done` |
| host_id | uuid null | |
| enqueued_at, leased_at, done_at | timestamp | |
| outcome | text null | `JobOutcome` из `complete` |

Очередь CI теперь в базе и переживает перезапуск. Правило сопоставления то же, что в `JobQueue`:
JIT-раннер может взять любое задание с подходящими метками, поэтому считаем, сколько раннеров нужно,
а не точные пары.

## Машина состояний сессии

```
            POST /v1/sessions
                   │
                   ▼
   ┌──────────── queued ───────────────┐
   │  хост взял /agent/v1/work         │ нет хоста за SESSION_QUEUE_SECONDS → failed
   │                                   │ DELETE → ended
   ▼                                   ▼
starting ──отчёт ready──▶ ready ──▶ ended / failed
   │                        │
   └────────────┬───────────┘
                ├─ DELETE пользователя                → ended  "ended by user"
                ├─ истёк expires_at                   → ended  "expired"
                ├─ отчёт агента ended                 → ended  (message агента)
                ├─ отчёт агента failed                → failed (message агента)
                └─ хост офлайн (нет heartbeat 45 с)   → failed "host went offline"
```

- Переход в `starting` делает control plane в момент выдачи `WorkLease.simulator`, не дожидаясь отчёта
  агента. Отчёт `starting` от агента подтверждает и ничего не меняет.
- Отчёт `ready` принимается только из `starting`. Отчёт со сессии, которая уже `ended`/`failed`, —
  `410 Gone`. Отчёт от чужого хоста — `404`.
- `ended` и `failed` конечные. В любом переходе в конечное состояние:
  1. `ended_at = now`, `message`;
  2. в оба канала сигнализации уходит `{"bye":{"reason":…}}`, затем сокеты закрываются;
  3. сессия попадает в каждый `HeartbeatResponse.endedSessions` этого хоста, пока агент не подтвердит,
     что знает о завершении (`host_notified`): сам отчитался `ended`/`failed` или получил 410. Не дольше
     10 минут после `ended_at`.
- Ограничение: у пользователя не больше `MAX_SESSIONS_PER_USER` (по умолчанию 2) сессий в `queued`,
  `starting` или `ready`, иначе `POST` отвечает `429`.
- `GET`/`DELETE` чужой сессии — `404` (админу можно). `DELETE` завершённой — `204`.
- `SessionInfo.signaling` (роль viewer) есть только в `starting` и `ready`.

## Подбор хоста

Работа раздаётся только через long-poll агента: хост приходит с `LeaseRequest` и получает самую
подходящую ему работу или ждёт до `longPollSeconds` (25 с). Подбор идёт под одной блокировкой
(актор) — одна работа не уйдёт двум хостам.

Хост может взять работу, если он онлайн, `LeaseRequest.freeSlots > 0` и (для симулятора) у него есть
`capacity` из heartbeat.

1. **Сначала симулятор** — пользователь ждёт перед экраном. Сессии `queued` по `created_at`:
   - `requested_host_id` пуст или равен этому хосту;
   - устройство: если `requested_device` задан, он должен быть в `capacity.devices`; иначе берётся
     `iPhone17Pro`, если он есть, иначе первое устройство хоста. Хост без устройств сессию не получает;
   - образ: `DEFAULT_IMAGE`, если он есть в `capacity.images`, иначе первый;
   - **прогретый лучше:** если у этого хоста `warmVMs == 0`, а сессии меньше `WARM_PREFERENCE_SECONDS`
     (5 с) и есть другой онлайн-хост с `warmVMs > 0`, который может её взять, сессия ждёт его.
     По истечении 5 с её берёт кто угодно.
2. **Потом CI.** Задания `pending` по `enqueued_at`, метки задания без стандартных меток GitHub
   (`self-hosted`, `macos`, `arm64`) ⊆ `LeaseRequest.labels`. JIT-конфиг запрашивается у GitHub
   в момент выдачи; если GitHub ответил ошибкой, задание возвращается в `pending`, агент получает `502`.

Ожидание: после неудачной попытки long-poll ждёт сигнала «появилась работа» (новая сессия или задание)
или 1 с — и пробует снова, пока не выйдет время. Тогда `204`.

Старый `/agent/v1/lease` работает как раньше (только CI), принимает и токены хостов, и `AGENT_TOKENS`
из env. Уберём, когда A перейдёт на `/agent/v1/work`.

## Фоновая проверка

Раз в `SWEEP_SECONDS` (5 с), время берётся из инжектируемых часов (в тестах — фейковые):

| Условие | Действие |
|---|---|
| `queued` дольше `SESSION_QUEUE_SECONDS` (120 с) | `failed` "no host available" |
| `starting`/`ready`, хост офлайн | `failed` "host went offline" |
| не конечная и `expires_at < now` | `ended` "expired" |
| `starting` дольше `SESSION_START_SECONDS` (300 с) | `failed` "host did not start the session" |
| CI `leased`, хост офлайн | обратно в `pending` |
| CI `pending` дольше 24 ч | `done` (GitHub к этому времени сам отменит задание) |

## Сигнализация

`GET /v1/sessions/{id}/signal?role=viewer|host&token=mcs_…` — WebSocket.

- До апгрейда, обычным HTTP-ответом: нет сессии — `404`, токен не той роли — `403`, сессия ещё `queued` —
  `409`, уже завершена — `410`. Сравнение токенов — за постоянное время.
- Комната на сессию: по одному сокету на роль. Новое подключение той же роли вытесняет старое
  (закрытие с кодом 4000 "replaced") — так работает перезагрузка вкладки.
- Каждый текстовый кадр пересылается другой стороне без изменений. Если её нет, кадр ждёт в очереди
  (до 256 кадров на роль, кадр до 64 КБ, старые выбрасываются) и уходит сразу после её подключения.
  Бинарные кадры закрывают сокет (1003).
- Отключение одной стороны не завершает сессию: её завершает агент, пользователь или таймер.
- **Токен в query не попадает в логи:** сервер пишет только путь; в access-логе Caddy параметр `token`
  заменяется на `REDACTED` (`deploy/Caddyfile`).
- Ping каждые 20 с, чтобы прокси и NAT не закрывали простаивающий сокет.

## TURN

coturn с `use-auth-secret` и общим секретом `TURN_SECRET` (TURN REST API):

```
username   = "<unix-время истечения>:<session id>"     # истекает вместе с сессией (expires_at)
credential = base64(HMAC-SHA1(TURN_SECRET, username))
```

`iceServers` в `SignalingInfo` для обеих ролей:

```
[{ urls: ["stun:<TURN_HOST>:3478"] },
 { urls: ["turn:<TURN_HOST>:3478?transport=udp",
          "turn:<TURN_HOST>:3478?transport=tcp",
          "turns:<TURN_HOST>:443?transport=tcp"],
   username, credential }]
```

Если `TURN_SECRET` не задан (локальная разработка), остаётся только STUN из `STUN_URLS` или пустой список.
Тестовый вектор — в фикстурах: секрет `fixture-turn-secret`, `session-ready.json`.

## Настройки (env)

| Переменная | По умолчанию | |
|---|---|---|
| `PUBLIC_URL` | `http://localhost:8080` | из него строится `wss://…/signal` |
| `MACCHERI_SHARED_TOKEN` | — | общий bearer команды, см. «Доступ» |
| `DATABASE_PATH` | `/data/maccheri.sqlite` | |
| `PUBLIC_DIR` | `/app/public` | `web/dist`; SPA-fallback на `index.html` для всего, что не `/v1`, `/agent`, `/github`, `/healthz` |
| `ADMIN_INVITE` | — | см. `invites` |
| `INVITE_TTL_HOURS` | 168 | |
| `SESSION_MINUTES` | 60 | |
| `MAX_SESSIONS_PER_USER` | 2 | |
| `SESSION_QUEUE_SECONDS` | 120 | |
| `SESSION_START_SECONDS` | 300 | |
| `WARM_PREFERENCE_SECONDS` | 5 | |
| `TURN_HOST`, `TURN_SECRET` | — | |
| `TURN_TLS_PORT` | 443 | |
| `STUN_URLS` | — | через запятую, если TURN нет |
| `GITHUB_WEBHOOK_SECRET`, `GITHUB_APP_ID`, `GITHUB_APP_PRIVATE_KEY` | — | без них CI выключен |
| `RUNNER_LABEL` | `maccheri` | |
| `DEFAULT_IMAGE` | `macos-27-xcode-27.2` | |
| `JOB_TIMEOUT_SECONDS` | 3600 | |
| `AGENT_TOKENS` | — | только для старого `/agent/v1/lease` |

## Бэкап

`VACUUM INTO '<файл>'` даёт целостную копию работающей базы без остановки. Обёртка — команда сервера
`controlplane backup <путь>` и `deploy/backup.sh` (по cron, хранит 14 последних копий).
