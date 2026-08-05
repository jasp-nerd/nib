#!/bin/bash
#
# Publish website/ to its host.
#
# The site is static: one HTML file, one screenshot, and a couple of SVGs, with no build step. So
# deploying is a file copy and there is nothing to restart. Any host that serves a directory over
# HTTPS will do; the default target is an nginx container behind a reverse proxy.
#
# Set NIB_WEB_HOST to an SSH host, and NIB_WEB_PATH to the directory it serves.
#
#   ./Tools/deploy-website.sh

set -euo pipefail
cd "$(dirname "$0")/.."

HOST="${NIB_WEB_HOST:-hetzner}"
REMOTE="${NIB_WEB_PATH:-/opt/nib-website/public}"

echo "==> copying website/ to $HOST:$REMOTE"
rsync -az --delete --exclude '_*' website/ "$HOST:$REMOTE/"

echo "==> checking"
SITE="${NIB_WEB_URL:-https://nib.jaspnerd.dev}"
for path in / /screenshot.png /robots.txt /sitemap.xml; do
    code=$(curl -s -o /dev/null -w "%{http_code}" "$SITE$path" --max-time 10)
    printf "    %-16s %s\n" "$path" "$code"
    [ "$code" = "200" ] || { echo "    FAILED"; exit 1; }
done

echo "==> $SITE is up to date"
