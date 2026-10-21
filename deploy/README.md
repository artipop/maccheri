# Деплой control plane

Один сервер (VPS с публичным IPv4), Docker Compose:

| Сервис | Что | Порты |
|---|---|---|
| `controlplane` | API, сигнализация, веб-клиент (`web/dist` внутри образа), SQLite на томе | 8080 внутри сети compose |
| `caddy` | HTTPS (Let's Encrypt), прокси к `controlplane`; TLS для TURN на том же 443 по SNI (caddy-l4) | 80, 443/tcp, 443/udp |
| `coturn` | STUN/TURN, учётные данные через общий секрет (`use-auth-secret`) | 3478/udp+tcp, relay `TURN_MIN_PORT`–`TURN_MAX_PORT`/udp, сеть хоста |

Как устроено внутри — `controlplane/DESIGN.md`.

## Что нужно от владельца сервера

- VPS: Linux x86_64 или arm64, 1 vCPU, 1 ГБ RAM, Docker с плагином compose.
- Два DNS-имени, A-записи на IP сервера: `DOMAIN` (например `maccheri.example.com`)
  и `TURN_DOMAIN` (`turn.maccheri.example.com`). Отдельное имя нужно, чтобы Caddy отличил TURN по SNI.
- Файрвол: 80/tcp, 443/tcp, 443/udp, 3478/tcp, 3478/udp, `TURN_MIN_PORT`–`TURN_MAX_PORT`/udp (по умолчанию 49160–49999).

## Первый запуск

```sh
git clone <repo> /opt/maccheri && cd /opt/maccheri/deploy
cp .env.example .env
# DOMAIN, TURN_DOMAIN, ACME_EMAIL; секреты:
sed -i "s/^TURN_SECRET=.*/TURN_SECRET=$(openssl rand -hex 32)/" .env
sed -i "s/^MACCHERI_SHARED_TOKEN=.*/MACCHERI_SHARED_TOKEN=$(openssl rand -hex 32)/" .env
docker compose up -d --build
curl https://$DOMAIN/healthz          # ok
```

Доступ команды — `MACCHERI_SHARED_TOKEN`: его вводят в веб-клиенте и в Maccheri.app при регистрации мака.
Личные аккаунты необязательны: код первого админа задаётся в `ADMIN_INVITE` или выдаётся командой

```sh
docker compose exec controlplane /app/controlplane create-invite --admin
```

## Проверка TURN

```sh
./turn-check.sh                       # UDP и TCP на 3478, TLS на 443
```

Скрипт делает учётные данные так же, как control plane (`username = <expiry>:<id>`,
`credential = base64(HMAC-SHA1(TURN_SECRET, username))`) и запускает `turnutils_uclient` из образа coturn.
Из браузера: https://webrtc.github.io/samples/src/content/peerconnection/trickle-ice/ с теми же
`username`/`credential`, в выводе должны быть кандидаты `relay`.

## Обновление

```sh
git pull && docker compose up -d --build
```

База мигрирует при старте. Long-poll агентов и WebSocket сигнализации переподключаются сами.

## Бэкап

```sh
./backup.sh                           # deploy/backups/maccheri-<время>.sqlite.gz, хранятся 14 последних
```

Копия целостная, сервер не останавливается (`VACUUM INTO`). В cron:
`15 3 * * * cd /opt/maccheri/deploy && ./backup.sh >> backups/backup.log 2>&1`. Каталог `backups/`
стоит дополнительно копировать с сервера.

Восстановление:

```sh
docker compose stop controlplane
gunzip -c backups/maccheri-<время>.sqlite.gz > /tmp/maccheri.sqlite
docker compose cp /tmp/maccheri.sqlite controlplane:/data/maccheri.sqlite
docker compose start controlplane
```

## Локально

Весь стек на маке разработки, доступный с других машин в LAN по HTTPS. HTTPS нужен и здесь:
браузер даёт WebCodecs и прочие API secure context только на `https://` (или `localhost`).
Сертификаты выдаёт собственный CA Caddy, без ACME и интернета.

```sh
cd deploy
cp .env.local.example .env.local
# DOMAIN: имя мака в Bonjour — `scutil --get LocalHostName` + `.local`
# LAN_IP: `ipconfig getifaddr en0`
# MACCHERI_SHARED_TOKEN: `openssl rand -hex 32`
docker compose -f docker-compose.yml -f compose.local.yml --env-file .env.local up -d --build
curl -k https://$LAN_IP/healthz       # ok
```

Что меняет `compose.local.yml`:
- Caddy берёт `Caddyfile.local`: `local_certs`, сертификаты на `DOMAIN` и `LAN_IP`;
- порты только на `LAN_IP` (и `127.0.0.1`), не на всех интерфейсах; control plane ещё и на `127.0.0.1:8080`;
- переменные из `.env.local`;
- coturn выключен (в одной LAN он не нужен), включается флагом `--profile turn`. Тогда в `.env.local`
  нужны `TURN_DOMAIN=<LAN_IP>` и `TURN_SECRET`; адрес `turns:…:443` локально не работает, остальные работают.

Сборка Swift-образа — самая тяжёлая операция на маке. Перед ней займи замок VM, как для запуска VM
(`docs/contracts.md`): `mkdir /Volumes/Dev/vm/.lock && echo "B: docker build controlplane" > /Volumes/Dev/vm/.lock/owner`,
после сборки `rm -r /Volumes/Dev/vm/.lock`.

### Доверить локальный CA

Корневой сертификат живёт в томе Caddy и не меняется, пока том не удалён (`down -v` его удалит):

```sh
docker compose -f docker-compose.yml -f compose.local.yml --env-file .env.local \
    exec -T caddy cat /data/caddy/pki/authorities/local/root.crt > maccheri-local-ca.crt
```

Файл копируется на каждую машину, которая ходит к стеку, **включая сам мак-хост**: агент Maccheri.app
обращается к `https://DOMAIN` и проверяет сертификат.

- **macOS:** `sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain maccheri-local-ca.crt`.
  Этого хватает Safari, Chrome и URLSession. Firefox: Настройки → Приватность и защита → Сертификаты →
  Импортировать, «доверять для веб-сайтов».
- **Linux (Chrome/Chromium):** `sudo cp maccheri-local-ca.crt /usr/local/share/ca-certificates/ && sudo update-ca-certificates`,
  для Chrome ещё `certutil -d sql:$HOME/.pki/nssdb -A -t C,, -n maccheri-local -i maccheri-local-ca.crt`.
- **Windows:** `certutil -addstore -f Root maccheri-local-ca.crt` из администраторской консоли.

Удалить на macOS: `sudo security delete-certificate -c "Caddy Local Authority - 2026 ECC Root" /Library/Keychains/System.keychain`
(точное имя видно в «Связке ключей»).

Открывать `https://DOMAIN` (имя `.local` резолвится по Bonjour на маках, на Windows и Linux — если есть mDNS)
или `https://LAN_IP`. `PUBLIC_URL` и URL сигнализации строятся из `DOMAIN`; если у второй машины нет mDNS,
поставь в `DOMAIN` сам IP.

## Логи

`docker compose logs -f controlplane caddy coturn`. Токены сигнализации из URL WebSocket в логи
не попадают: control plane пишет только путь, Caddy заменяет параметр `token` на `REDACTED`.
Заголовок `Authorization` Caddy не пишет по умолчанию.
