#!/bin/sh
# Consistent copy of the live SQLite database into deploy/backups, keeping the newest 14.
# Cron on the server, e.g.:  15 3 * * *  cd /opt/maccheri/deploy && ./backup.sh >> backups/backup.log 2>&1
set -eu
cd "$(dirname "$0")"
name="maccheri-$(date -u +%Y%m%dT%H%M%SZ).sqlite"
docker compose exec -T controlplane /app/controlplane backup "/backups/$name"
gzip "backups/$name"
ls -1t backups/maccheri-*.sqlite.gz | tail -n +15 | xargs -r rm --
echo "backup: backups/$name.gz"
