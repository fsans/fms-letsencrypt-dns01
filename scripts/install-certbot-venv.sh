#!/bin/bash
# install-certbot-venv.sh — installs certbot + certbot-dns-ionos into
# /opt/certbot-venv (guide Step 1). The standalone venv survives Homebrew
# upgrades; installing the plugin into brew's certbot venv does not.
set -euo pipefail

VENV=/opt/certbot-venv

# /opt is root-owned: create with sudo, then hand to the current user so
# future pip upgrades don't need sudo.
sudo mkdir -p "$VENV"
sudo chown "$(stat -f '%u:%g' "$HOME")" "$VENV"

python3 -m venv "$VENV"
"$VENV/bin/pip" install --upgrade pip certbot certbot-dns-ionos

echo
echo "Verifying plugin registration:"
"$VENV/bin/certbot" plugins 2>&1 | grep -A3 dns-ionos
echo
echo "Done. Use $VENV/bin/certbot for all certbot commands."
