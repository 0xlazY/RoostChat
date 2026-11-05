#!/bin/sh
# Generates .env and settings.json. Run once from this folder, or again to change
# the domain or APNs password. Neither file should ever be committed.
set -eu
umask 077
cd "$(dirname "$0")"

printf 'Push domain (for example push.example.com): '
read -r PUSH_DOMAIN
printf 'APNs .p12 password: '
stty -echo; read -r APNS_P12_PASSWORD; stty echo; echo

COMPONENT_SECRET=$(openssl rand -hex 32)
printf 'PUSH_DOMAIN=%s\nCOMPONENT_SECRET=%s\n' "$PUSH_DOMAIN" "$COMPONENT_SECRET" > .env

PUSH_DOMAIN="$PUSH_DOMAIN" COMPONENT_SECRET="$COMPONENT_SECRET" APNS_P12_PASSWORD="$APNS_P12_PASSWORD" \
python3 -I -c '
import json, os
settings = json.load(open("settings.template.json"))
settings["component"]["componentHostname"] = os.environ["PUSH_DOMAIN"]
settings["component"]["componentKey"] = os.environ["COMPONENT_SECRET"]
settings["pushModules"]["roosterchat"]["apns"]["certPassword"] = os.environ["APNS_P12_PASSWORD"]
json.dump(settings, open("settings.json", "w"), indent=4)
'
mkdir -p certs secrets
echo "Wrote .env and settings.json."
echo "Next: put apns.p12 in secrets/ and the TLS certificate in certs/ (see README.md)."
