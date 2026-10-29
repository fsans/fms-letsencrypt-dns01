#!/bin/bash
# install-fms-cert.sh — certbot deploy hook: imports the renewed LE cert
# into FileMaker Server and reloads the services that consume it.
#
# Install:  sudo cp install-fms-cert.sh /etc/letsencrypt/renewal-hooks/deploy/
#           sudo chmod +x /etc/letsencrypt/renewal-hooks/deploy/install-fms-cert.sh
# Requires: /etc/letsencrypt/.secrets/fmsadmin.env  (FMSADMIN_USER/FMSADMIN_PASS)
# Runs as root under launchd — no TTY, so fmsadmin must get -u/-p.
set -e

# certbot sets RENEWED_LINEAGE to the live dir of the cert just renewed;
# fall back to the default domain dir for manual runs.
CERT_DIR="${RENEWED_LINEAGE:-/etc/letsencrypt/live/fms.example.com}"
STAGING="/Library/FileMaker Server/CStore/letsencrypt-staging"

source /etc/letsencrypt/.secrets/fmsadmin.env

# Stage where fmserver can read (live/ is root-only — see guide Step 6).
mkdir -p "$STAGING"
cp "$CERT_DIR/fullchain.pem" "$CERT_DIR/privkey.pem" "$CERT_DIR/chain.pem" "$STAGING/"
chown -R fmserver:fmsadmin "$STAGING"
chmod 750 "$STAGING"
chmod 640 "$STAGING"/*.pem

/usr/local/bin/fmsadmin -u "$FMSADMIN_USER" -p "$FMSADMIN_PASS" certificate delete -y
/usr/local/bin/fmsadmin -u "$FMSADMIN_USER" -p "$FMSADMIN_PASS" certificate import \
  "$STAGING/fullchain.pem" --keyfile "$STAGING/privkey.pem" \
  --intermediateCA "$STAGING/chain.pem" -y

# Apache (443): graceful reload picks up the cert with no drops.
/bin/launchctl kickstart -k system/com.filemaker.httpd.graceful
# Database server (5003): real restart loads the cert; brief client
# disconnect — fine at the 03:30 renewal time.
/bin/launchctl kickstart -k system/com.filemaker.fms
