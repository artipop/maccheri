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

На маке с Docker Desktop: имена `localhost` и `turn.localhost` Caddy обслуживает своим внутренним CA.

```sh
cd deploy
cp .env.example .env    # DOMAIN=localhost, TURN_DOMAIN=turn.localhost, TURN_SECRET=<любой>
docker compose -f docker-compose.yml -f docker-compose.local.yml up --build
curl -k https://localhost/healthz
```

`docker-compose.local.yml` переводит coturn из сети хоста в обычную сеть compose с узким диапазоном
relay-портов и разрешает relay в частные сети: в локальной сети все пиры в них.

## Логи

`docker compose logs -f controlplane caddy coturn`. Токены сигнализации из URL WebSocket в логи
не попадают: control plane пишет только путь, Caddy заменяет параметр `token` на `REDACTED`.
Заголовок `Authorization` Caddy не пишет по умолчанию.
