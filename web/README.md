# Веб-клиент Maccheri

Удалённый симулятор iOS в браузере: вход, выбор мака и устройства, «Новая сессия», экран
симулятора по WebRTC, касания, клавиатура, Home, блокировка, поворот, установка `.app`.
Работает в актуальных Chrome, Safari и Firefox на любой ОС.

Vite и ванильный TypeScript, без фреймворка и без зависимостей в рантайме. Сборка — один
`index.html` с бандлом (около 30 КБ), без серверного рендеринга и с относительными путями. Так клиент
потом можно встроить в webview VS Code или в нативную обёртку.

| Файл | Что |
|---|---|
| `src/api.ts` | типы и вызовы control plane, повторяют `MaccheriProtocol` |
| `src/protocol.ts` | сообщения SimStream (повторяют `SimStreamProtocol`), сборка кадров из кусков |
| `src/session.ts` | сигнализация с ролью viewer, `RTCPeerConnection`, каналы, статистика |
| `src/video.ts` | показ видео: `<video>` для дорожки, WebCodecs и `<canvas>` для канала данных |
| `src/latency.ts` | задержка клик → кадр (как `LatencyTracker` в Swift) |
| `src/keyboard.ts` | `KeyboardEvent.code` → USB HID usage |
| `src/main.ts` | экраны: вход, маки, ожидание, сессия, оверлей |
| `dev/mock-control-plane.ts` | control plane в памяти внутри dev-сервера Vite |
| `bench/latency.mjs` | замер клик → кадр и проверки в настоящих браузерах |

## Разработка

```sh
npm install
npm run dev          # http://localhost:5173 и мок control plane на том же порту
npm test             # vitest: протокол, задержка, клавиатура, типы API по фикстурам control plane
npm run build        # → dist/, его раздаёт control plane (PUBLIC_DIR)
```

Мок нужен, пока нет настоящего control plane, и для работы без него. Он принимает общий токен
`dev` (`MOCK_SHARED_TOKEN`), любой код приглашения, `enroll`, `heartbeat`, `/agent/v1/work` и
сигнализацию. Хост для него — `simstream-peer` (см. `simstream/README.md`, «Как проверить без агента»).
ICE-серверы мока задаёт `MOCK_ICE="stun:…,turn:user:pass@host:3478"`.

Клиент против настоящего control plane:
- `VITE_API=http://localhost:8080 npm run dev`: dev-сервер проксирует `/v1` и `/agent` туда, мок выключен;
- либо `?api=https://maccheri.example` в адресе открытой страницы: адрес запоминается в `localStorage`,
  а сбрасывается через `?api=`.

Вход: поле принимает код приглашения или общий токен команды. Если `/v1/auth/redeem` отвечает 404
(мини-прод без пользователей), введённое значение считается токеном. Токен хранится в
`localStorage` и уходит в `Authorization: Bearer`.

Другие параметры адреса: `?video=track|dataChannel` — как везти видео, `?invite=…` или `?token=…` —
заполнить поле входа.

## Тесты типов API

`test/api.test.ts` сверяет типы из `src/api.ts` с JSON-фикстурами control plane
(`controlplane/Tests/Fixtures`, их генерирует B из `MaccheriProtocol`). Проверяются обязательные
поля, лишние поля, UUID и даты. Если фикстур рядом нет, тест пропускается. Другой каталог можно
задать через `MACCHERI_FIXTURES=…`.

## Замеры в браузерах

```sh
node bench/latency.mjs --browser chrome --video dataChannel --taps 40     # /Applications/Google Chrome.app
node bench/latency.mjs --browser chromium                                 # headless Chromium из кэша Playwright
safaridriver -p 4444 & node bench/latency.mjs --browser safari            # нужен `safaridriver --enable`
geckodriver -p 4444 & node bench/latency.mjs --browser firefox
```

Скрипт входит, создаёт сессию, кликает мышью браузера в центр экрана (TapProbe меняет цвет) и печатает
`RESULT … p50 … p95`. Параметр `--steps` вместо кликов выполняет проверки по шагам, например
`--steps home,shot:a,rotate:landscapeLeft,type:hi,install:/path/App.zip,button:Блокировка экрана,shot:b`.
Цифры собраны в `bench/simstream/RESULTS.md`.
