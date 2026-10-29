#!/bin/bash
# manual-import.sh — interactive equivalent of the deploy hook, for the
# first install or for recovering when the hook failed (guide Steps 6+7).
#
# Usage:  sudo ./manual-import.sh [hostname]     (default fms.example.com)
# fmsadmin will prompt for the Admin Console username/password.
set -euo pipefail

DOMAIN="${1:-fms.example.com}"
CERT_DIR="/etc/letsencrypt/live/$DOMAIN"
STAGING="/Library/FileMaker Server/CStore/letsencrypt-staging"

if [ "$(id -u)" -ne 0 ]; then
  echo "error: run with sudo — needs root to read $CERT_DIR" >&2
  exit 1
fi

if [ ! -f "$CERT_DIR/fullchain.pem" ]; then
  echo "error: no cert at $CERT_DIR — has certbot issued one for $DOMAIN?" >&2
  exit 1
fi

echo "== Staging cert files =="
mkdir -p "$STAGING"
cp "$CERT_DIR/fullchain.pem" "$CERT_DIR/privkey.pem" "$CERT_DIR/chain.pem" "$STAGING/"
chown -R fmserver:fmsadmin "$STAGING"
chmod 750 "$STAGING"
chmod 640 "$STAGING"/*.pem

echo "== Deleting existing custom cert (ignore 'nothing to delete') =="
fmsadmin certificate delete -y 2>/dev/null || true

echo "== Importing cert (Admin Console credentials required) =="
fmsadmin certificate import \
  "$STAGING/fullchain.pem" \
  --keyfile "$STAGING/privkey.pem" \
  --intermediateCA "$STAGING/chain.pem" -y

echo "== Reloading Apache (443, graceful) =="
launchctl kickstart -k system/com.filemaker.httpd.graceful

echo "== Restarting database server (5003) — brief client disconnect =="
launchctl kickstart -k system/com.filemaker.fms

sleep 10
echo "== Checking ports =="
nc -vz localhost 5003 || echo "WARNING: port 5003 not up yet — check 'launchctl print system/com.filemaker.fms'"
nc -vz localhost 16001 || true
nc -vz localhost 443 || true

echo
echo "== Cert now served on 443 =="
openssl s_client -connect localhost:443 -servername "$DOMAIN" </dev/null 2>/dev/null \
  | openssl x509 -noout -subject -issuer -dates
