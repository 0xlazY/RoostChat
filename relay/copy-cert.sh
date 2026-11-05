#!/bin/sh
# Certbot deploy hook. Copies the certificate where Prosody can read it, because
# the container's user can't read /etc/letsencrypt. Install with:
#   sudo certbot renew --deploy-hook /path/to/relay/copy-cert.sh
set -eu
RELAY_DIR=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
cd "$RELAY_DIR"
. ./.env
LIVE="/etc/letsencrypt/live/$PUSH_DOMAIN"
PROSODY_UID=$(docker compose run --rm --no-deps --entrypoint id prosody -u prosody)
install -m 644 "$LIVE/fullchain.pem" "certs/$PUSH_DOMAIN.crt"
install -m 640 -o "$PROSODY_UID" -g root "$LIVE/privkey.pem" "certs/$PUSH_DOMAIN.key"
docker compose restart prosody
