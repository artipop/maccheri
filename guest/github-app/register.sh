#!/bin/bash
# Registers the GitHub App (sign-in and CI) with GitHub's manifest flow, from this Mac:
#
#   guest/github-app/register.sh DOMAIN [--org ORG] [--name NAME]
#
# Opens GitHub in the browser with the manifest filled in; after "Create GitHub App" GitHub
# redirects back to a one-shot listener on localhost, and the script exchanges the code for the
# App's id, private key, webhook secret and OAuth client. They are written to ~/.maccheri/github-app-<slug>.json
# (mode 600) and nowhere else: never into the repository.
set -euo pipefail
cd "$(dirname "$0")"

DOMAIN="${1:?usage: register.sh DOMAIN [--org ORG] [--name NAME]}"; shift
ORG=""
NAME="maccheri-$(id -un)"
while [ $# -gt 0 ]; do
    case "$1" in
        --org) ORG="$2"; shift 2 ;;
        --name) NAME="$2"; shift 2 ;;
        *) echo "unknown option $1" >&2; exit 64 ;;
    esac
done
PORT=8765

MANIFEST="$(jq -c --arg name "$NAME" --arg url "https://$DOMAIN" --arg hook "https://$DOMAIN/github/webhook" \
    --arg redirect "http://localhost:$PORT/callback" \
    --arg callback "https://$DOMAIN/auth/github/callback" --arg setup "https://$DOMAIN/github/setup" \
    '.name = $name | .url = $url | .hook_attributes.url = $hook | .redirect_url = $redirect
     | .callback_urls = [$callback] | .setup_url = $setup' manifest.json)"
if [ -n "$ORG" ]; then
    # Runners for every repository of the organisation, not just the ones the App is installed on.
    MANIFEST="$(echo "$MANIFEST" | jq -c '.default_permissions.organization_self_hosted_runners = "write"')"
    TARGET="https://github.com/organizations/$ORG/settings/apps/new"
else
    TARGET="https://github.com/settings/apps/new"
fi

STATE="$(uuidgen)"
PAGE="$(mktemp -t maccheri-github-app).html"
trap 'rm -f "$PAGE"' EXIT
# The manifest has to be POSTed, so the browser gets a page that submits it.
cat > "$PAGE" <<HTML
<!doctype html><meta charset="utf-8"><title>Maccheri GitHub App</title>
<form id="f" method="post" action="$TARGET?state=$STATE">
<input type="hidden" name="manifest" value='$(echo "$MANIFEST" | sed "s/'/\&#39;/g")'>
<button>Create the GitHub App on GitHub</button></form>
<script>document.getElementById("f").submit()</script>
HTML
echo "Opening GitHub: create the App there ($NAME, webhook https://$DOMAIN/github/webhook)."
open "$PAGE"

echo "Waiting for GitHub to redirect back to localhost:$PORT…"
REQUEST="$(printf 'HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nConnection: close\r\n\r\nGot it, back to the terminal.\n' | nc -l "$PORT" | head -1)"
CODE="$(echo "$REQUEST" | sed -nE 's/.*[?&]code=([^& ]+).*/\1/p')"
GOT_STATE="$(echo "$REQUEST" | sed -nE 's/.*[?&]state=([^& ]+).*/\1/p')"
[ -n "$CODE" ] || { echo "no code in: $REQUEST" >&2; exit 1; }
[ "$GOT_STATE" = "$STATE" ] || { echo "state mismatch: the redirect is not from this run" >&2; exit 1; }

mkdir -p ~/.maccheri && chmod 700 ~/.maccheri
RESULT="$(curl -fsS -X POST -H "Accept: application/vnd.github+json" "https://api.github.com/app-manifests/$CODE/conversions")"
SLUG="$(echo "$RESULT" | jq -r .slug)"
OUT=~/.maccheri/github-app-"$SLUG".json
(umask 077; echo "$RESULT" > "$OUT")

echo
echo "Created $(echo "$RESULT" | jq -r .html_url), saved to $OUT."
echo "Next:"
echo "  1. Give the control plane its environment (deploy/.env on the server, not the repository):"
echo "       GITHUB_APP_ID=$(echo "$RESULT" | jq -r .id)"
echo "       GITHUB_APP_SLUG=$SLUG"
echo "       GITHUB_CLIENT_ID=$(echo "$RESULT" | jq -r .client_id)"
echo "       GITHUB_CLIENT_SECRET=<client_secret from $OUT>"
echo "       GITHUB_WEBHOOK_SECRET=<webhook_secret from $OUT>"
echo "       GITHUB_APP_PRIVATE_KEY=<pem from $OUT>"
echo "     e.g.  jq -r .client_secret $OUT,  jq -r .webhook_secret $OUT,  jq -r .pem $OUT"
echo "  2. Sign in to the web client with GitHub, create a team and install the App from the team's"
echo "     page: the link carries a state that binds the installation to the team. Installing from"
echo "     $(echo "$RESULT" | jq -r .html_url) directly binds it to no team."
