#!/bin/bash
#
# Publish website/ to the VPS.
#
# The site is served by a plain nginx container behind the Coolify Traefik proxy that was
# already on the box, at https://nib.jaspnerd.dev. It is not on GitHub Pages: a wildcard
# *.jaspnerd.dev A record already points at the server, so this route needed no DNS change
# at the registrar, whereas Pages would have needed a CNAME that overrides that wildcard.
#
# The container mounts this directory read-only, so deploying is just copying files. There
# is nothing to restart.
#
#   ./Tools/deploy-website.sh

set -euo pipefail
cd "$(dirname "$0")/.."

HOST="${NIB_WEB_HOST:-hetzner}"
REMOTE="/opt/nib-website/public"

echo "==> copying website/ to $HOST:$REMOTE"
rsync -az --delete --exclude '_*' website/ "$HOST:$REMOTE/"

echo "==> checking"
for path in / /screenshot.png /robots.txt /sitemap.xml; do
    code=$(curl -s -o /dev/null -w "%{http_code}" "https://nib.jaspnerd.dev$path" --max-time 10)
    printf "    %-16s %s\n" "$path" "$code"
    [ "$code" = "200" ] || { echo "    FAILED"; exit 1; }
done

echo "==> https://nib.jaspnerd.dev is up to date"
