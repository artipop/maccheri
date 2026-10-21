# Контракты между частями (M1)

Общие правила для параллельных сессий A–D. Сама задача каждой сессии описана в `docs/tasks/m1-*.md`,
общий план — в `docs/roadmap.md`.

## Цель M1

1. **Симулятор.** Член команды на любом компьютере (Linux, Windows, macOS), в другой сети,
   например с телефонного хотспота:
   - открывает веб-клиент в браузере и входит по инвайту;
   - нажимает «Новая сессия» и через несколько секунд работает с симулятором на маке владельца;
   - видео и касания идут P2P, через сервер только сигнализация и, при необходимости, TURN;
   - после завершения сессии VM удаляется.
2. **CI.** Push в репозиторий с `runs-on: [self-hosted, maccheri]` выполняется в одноразовой VM на маке
   из пула команды.

## Части и владельцы папок

| Сессия | Что | Папки (пишет только владелец) |
|---|---|---|
| A | Maccheri.app (хост), агент, пул VM, сеть гостя | `hostapp/`, `agent/` |
| B | Control plane, деплой (Caddy, coturn) | `controlplane/`, `deploy/` |
| C | Базовый образ, служба в госте, сквозной прогон CI | `images/`, `guest/` |
| D | P2P-транспорт (WebRTC), simstream, веб-клиент, Mac Viewer (инструмент разработки) | `simstream/`, `web/`, `viewer/`, `protocol/Sources/SimStreamProtocol/` |
| Координатор (сессия `maccheri-3c`) | Контракты, слияние в `main` | `protocol/Sources/MaccheriProtocol/`, `docs/` |

Если нужно поменять чужую папку или контракт, напиши владельцу или координатору через `SendMessage`.
Найти адресата можно через `ListAgents`: у каждой сессии своя ветка и worktree. Мелкие правки, без
которых не собирается твоя часть, допустимы, но владельца надо предупредить сразу.

## Ветки и слияние

- Каждая сессия работает в своём worktree: `git worktree add ../maccheri-<a|b|c|d> -b task/<name> main`.
- Коммить часто и регулярно подтягивай `main` (`git rebase main` или `git merge main`).
- Когда этап готов (собирается, тесты зелёные), напиши координатору, что слить. В `main` сливает
  только координатор.
- Коммиты делаются через `git -c user.email=art.shaburov@gmail.com commit`, сообщение заканчивается строкой
  `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Удалённого репозитория нет. Ничего никуда не пушить.

## API (`protocol/Sources/MaccheriProtocol`)

Модели и пути уже лежат в коде, в нём и документация. Это источник правды:

| Файл | Что |
|---|---|
| `Auth.swift` | инвайты и токены пользователей (`/v1/invites`, `/v1/auth/redeem`, `/v1/me`) |
| `Hosts.swift` | регистрация хоста, heartbeat и ёмкость (`/v1/hosts/enroll`, `/agent/v1/heartbeat`) |
| `Sessions.swift` | сессии симулятора для viewer (`/v1/sessions`), `DeviceSpec` |
| `Signaling.swift` | WebSocket-сигнализация `/v1/sessions/{id}/signal`, ICE/TURN, `SignalMessage` |
| `Work.swift` | общий long-poll агента `/agent/v1/work` (CI и симулятор), отчёты о состоянии сессии |
| `Guest.swift` | `session.json` в общей папке гостя: что гость должен сделать |
| `Agent.swift` | старый v1 (`/agent/v1/lease`, только CI). B держит его, пока A не перейдёт на `/agent/v1/work` |

JSON: даты в ISO 8601, перечисления с данными кодируются стандартным синтезом Swift `Codable`
(`{"ci":{"_0":{…}}}`). Swift-клиенты и сервер используют одни и те же типы, руками JSON не пишем.

**Веб-клиент** (TypeScript, `web/`) повторяет нужные ему типы (`Auth`, `Sessions`, `Signaling`)
в `web/src/api.ts` и сверяется с примерами JSON. Их B кладёт в `controlplane/Tests/.../Fixtures/*.json`
и проверяет тестами. Если контракт меняется, обновляются и фикстуры, и `api.ts`.

Особенности браузера, учтённые в контракте:
- токен сигнализации передаётся в query (`SignalingInfo.url` уже содержит `role` и `token`), потому что
  браузер не умеет ставить заголовки WebSocket;
- control plane раздаёт веб-клиент со своего домена: CORS не нужен, токен пользователя лежит
  в `localStorage` и уходит в заголовке `Authorization` для REST.

## Жизненный цикл сессии симулятора

```
web-клиент ──POST /v1/sessions──▶ control plane (queued)
agent  ──POST /agent/v1/work─▶ control plane выбирает хост ──▶ WorkLease.simulator
agent: берёт прогретую VM (или клонирует и загружает новую), пишет session.json в общую папку,
       отчитывается о состоянии starting
guest: служба C читает session.json, загружает устройство, запускает simstream на :7300
agent: дождался, что гость принимает соединения на :7300, отчитывается о состоянии ready
       и запускает host peer (библиотека D), который подключается к signaling с ролью host
web-клиент: видит state=ready и подключается к signaling с ролью viewer
host peer ⇄ браузер: offer, answer, candidates → P2P (стандартный WebRTC), затем видео и касания
конец: пользователь нажимает «Завершить» (DELETE), клиент шлёт bye или закрывает вкладку, либо истекает expiresAt
agent: гасит VM, удаляет клон, отчитывается о состоянии ended
```

### Стыки

- **A ↔ C (хост → гость).** Общая папка `GuestAPI.sharePath` внутри гостя видна только для чтения,
  а на хосте это каталог, куда пишет агент. Агент может записать `session.json` и до загрузки, и после
  (для прогретой VM). Служба гостя ждёт файл, проверяя его раз в 0,5 с. Гость готов, когда принимает
  TCP-соединения на `simstreamPort`. Работу с CI гость заканчивает сам, выключая систему.
- **Метаданные образа (C → A).** Рядом с `config.json` в каталоге образа лежит `maccheri.json`:
  `{"labels": [...], "devices": [DeviceSpec...], "guestVersion": "..."}`. Из него агент заполняет
  `HostCapacity`. Тип описывает C в `images/`, а если он понадобится в Swift, пусть попросит
  координатора добавить его в `MaccheriProtocol`.
- **A ↔ D (host peer).** D даёт библиотеку в пакете `simstream`, примерно такую:
  ```swift
  public final class HostPeer {
      public init(signaling: SignalingInfo, sessionID: UUID,
                  connectToGuest: @escaping @Sendable () async throws -> NWConnection)
      /// Returns when the viewer leaves (bye / disconnect / timeout).
      public func run() async throws
  }
  ```
  A подключает пакет к агенту и вызывает `run()` после `ready`. Как именно открывается соединение
  до гостя (IP гостя из DHCP или vsock), решает A. D получает это соединение через `connectToGuest`.
- **B ↔ D (веб-клиент).** D собирает `web/` в статические файлы (`web/dist`). B раздаёт их с корня
  домена (`PUBLIC_DIR`, в Docker-образ попадают на этапе сборки), API остаётся под `/v1`.
- **B ↔ все.** Вся сигнализация идёт через B. TURN выдаёт B: coturn с `use-auth-secret`, временные
  учётные данные передаются в `SignalingInfo.iceServers`.

## Общие ресурсы на маке разработки

- Хост: M4, 16 ГБ. **Одновременно может работать только одна VM** на 8 ГБ, а одной Apple разрешает
  не больше двух.
- Перед запуском VM займи блокировку: `mkdir /Volumes/Dev/vm/.lock && echo "<сессия>: <зачем>" > /Volumes/Dev/vm/.lock/owner`.
  Если `mkdir` не прошёл, VM занята: прочитай `owner` и договорись с владельцем через `SendMessage`
  или подожди. После работы погаси VM и удали `.lock`. Держи VM столько, сколько нужно, не часами.
- Кому VM нужнее, по убыванию: **C** (сборка образа), **A** (пул и сеть гостя), **D**. D по возможности
  отлаживает simstream на симуляторе хоста, без VM: приватные API там те же. B VM не нужна.
- Образы и клоны лежат на `/Volumes/Dev/vm` (`images/`, `work/`, `tart/`), это внешний SSD, ~250 МБ/с.
  Сборки делай на внутреннем диске.
- Гость: `admin` / `admin`, sudo без пароля. SSH без интерактивного ввода:
  `SSH_ASKPASS=<скрипт, печатающий admin> SSH_ASKPASS_REQUIRE=force ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null admin@<ip>`.
- Без явного разрешения пользователя ничего крупного не скачиваем: образы, IPSW, рантаймы.
  Мелкие зависимости (пакеты SwiftPM, actions-runner на ~200 МБ, бинарь WebRTC) — можно.
- Пользователю пишем по-русски, комментарии в коде — по-английски, в стиле окружающего кода.
  Новые Xcode-проекты делаем в JSON `project.xcproj` (пример — `hostapp/`, `viewer/`). Всё на Swift,
  кроме веб-клиента: он на TypeScript.
- Подпись Developer ID и нотаризация — в самом конце, не в M1. Пока подпись ad-hoc.
