#!/bin/sh
# Checks coturn with credentials made the way the control plane makes them (TURN REST API).
#     ./turn-check.sh                 # UDP and TCP on 3478, TLS on 443, against TURN_DOMAIN from .env
#     ./turn-check.sh turn.example.com
set -eu
cd "$(dirname "$0")"
. ./.env
host="${1:-$TURN_DOMAIN}"
username="$(( $(date +%s) + 600 )):turn-check"
password="$(printf '%s' "$username" | openssl dgst -sha1 -hmac "$TURN_SECRET" -binary | base64)"
uclient() {
    docker run --rm --network host --entrypoint turnutils_uclient coturn/coturn:4.7 \
        -y -c -n 5 -m 1 -u "$username" -w "$password" "$@" "$host"
}
echo "== UDP 3478";  uclient -p 3478
echo "== TCP 3478";  uclient -t -p 3478
echo "== TLS 443";   uclient -t -S -p 443
echo "ok"
