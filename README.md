# fms-letsencrypt-dns01

A practical, battle-tested guide for getting a **trusted Let's Encrypt
certificate onto a FileMaker Server that is not reachable from the
internet on ports 80/443** — plus the scripts and launchd config to keep
it renewing unattended.

## The scenario

- FileMaker Server requires HTTPS (OData, Data API, WebDirect, TLS for
  FM client connections).
- The standard Let's Encrypt **HTTP-01** challenge is impossible: the
  FMS host sits on a private IP and ports 80/443 on the public router
  are taken by another web server (or simply not forwarded).
- FMS's own Admin Console "Request Let's Encrypt Certificate" button
  uses HTTP-01 → it will **always fail** on this setup.
- A self-signed cert means manually trusting it on every client, and
  breaks `fetch()` inside Web Viewers.

The answer is **DNS-01**: Let's Encrypt validates a TXT record in your
DNS zone instead of connecting to your server. Your host never needs an
inbound port.

This repo uses **IONOS** as the concrete DNS provider (via the
`certbot-dns-ionos` plugin), but the approach works with any certbot DNS
plugin — swap the credentials/authenticator flags accordingly.

## Contents

| Path | What |
| ---- | ---- |
| `docs/guide.md` | The full step-by-step guide (read this first) |
| `docs/lessons-learned.md` | Real incident write-up — the failure modes this setup prevents |
| `scripts/install-certbot-venv.sh` | Installs certbot + the IONOS plugin into `/opt/certbot-venv` |
| `scripts/install-fms-cert.sh` | The certbot **deploy hook**: imports the renewed cert into FMS and reloads services |
| `scripts/manual-import.sh` | Interactive version of the hook (for first-time install or recovery) |
| `scripts/verify-cert.sh` | Checks the cert on ports 443 + 5003, expiry, and strict-TLS reachability |
| `config/com.letsencrypt.renew.plist` | launchd daemon that runs `certbot renew` daily at 03:30 |
| `config/ionos.ini.example` | IONOS API credentials template for the DNS plugin |
| `config/fmsadmin.env.example` | FMS Admin Console credentials template for the deploy hook |

## Quick start

1. Read `docs/guide.md` — it walks through everything end to end.
2. Fill in the two `config/*.example` files with your values and install
   them under `/etc/letsencrypt/.secrets/` (root-only, `chmod 600`).
3. Install the scripts/plist where the guide says, run
   `scripts/verify-cert.sh` to confirm.

## Requirements

- FileMaker Server on **macOS** (paths like
  `/Library/FileMaker Server/...` are macOS-specific; the concepts
  transfer to Windows/Linux FMS but the scripts don't).
- A domain whose DNS zone is hosted at IONOS (or adapt the plugin).
- `sudo` on the FMS machine, and the FMS Admin Console credentials.
- OData / whatever HTTPS services you intend to serve, already working
  over plain HTTPS once the cert exists.
