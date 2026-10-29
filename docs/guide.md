# Let's Encrypt certificate for FileMaker Server via DNS-01

End-to-end guide. Written for FMS on macOS with DNS hosted at IONOS;
adapt the provider-specific bits if your DNS lives elsewhere.

## Problem

FileMaker Server requires HTTPS (it does not serve OData/Data API over
plain HTTP, and FM client connections on port 5003 use TLS too). On a
private network, getting a trusted SSL certificate is hard because:

- The FMS machine is not reachable from the internet on port 80, so the
  standard Let's Encrypt **HTTP-01** challenge (which requires serving a
  token over `http://<domain>/.well-known/acme-challenge/...`) does not
  work.
- Ports 80 and 443 on the public-facing router are reserved for another
  web server, so they cannot be forwarded to FMS.
- A self-signed certificate requires manual trust installation in
  Keychain on every client Mac, and breaks `fetch()` inside Web Viewers
  unless the cert is trusted at the OS level.

> **Do NOT use the Admin Console's built-in Let's Encrypt request/verify
> button.** It uses **HTTP-01**, which can never work on this setup —
> LE cannot reach the host from the internet. Every attempt lands in
> `Admin/FAC/logs/fac.log` as `Let's Encrypt Request failed: Failure /
> timeout verifying challenge passed`, and repeated clicks burn LE's
> failed-validation rate limit (5 per hostname per hour). Only the
> DNS-01 flow below works here.

## Solution

Use Let's Encrypt's **DNS-01** challenge with the **IONOS Developer DNS
API** and the `certbot-dns-ionos` plugin. The plugin automates the whole
challenge: it creates the `_acme-challenge` TXT record via the IONOS
API, waits for propagation, lets LE verify it, and deletes the record —
all unattended. `certbot renew` repeats the cycle automatically.

The result is a normal, publicly-trusted LE cert. Install it on FMS and
serve everything from the same hostname, and you get:

- **Same origin** for a web app + OData (no CORS needed).
- **Valid LE cert** → no client-side cert installation, no `fetch()`
  trust errors on any client (FileMaker Pro, Go, WebDirect).
- **No port 80/443 forwarding** to FMS — DNS-01 only checks a TXT
  record; LE never connects to the server.
- **Fully automated renewal** via a macOS launchd daemon.

> **Key insight**: DNS-01 validation only checks the TXT record, not
> whether the domain resolves to a reachable IP. The A record can point
> at a private IP — LE only cares about the TXT record.

## Parameters — fill these in first

Every command below uses these placeholders. Decide your values once
and substitute throughout (or export them in your shell).

| Parameter | Placeholder | Your value |
| --------- | ----------- | ---------- |
| Hostname (cert CN/SAN) | `fms.example.com` | |
| FMS internal IP | `192.168.x.x` | |
| DNS zone (root domain) | `example.com` | |
| LE account email | `admin@example.com` | |
| DNS provider | IONOS Developer DNS API | |
| IONOS API portal | `https://developer.hosting.ionos.es/keys` | |
| IONOS API base URL | `https://api.hosting.ionos.com` | |
| FMS Admin Console user | `admin` | |

> **Hostname vs IP**: clients must connect to the FMS by **hostname**,
> not IP. The cert only covers `fms.example.com`; connecting via
> `192.168.x.x` (or a Bonjour name) shows the red "certificate does not
> match" lock in FileMaker clients. LE cannot issue certs for
> private-IP SANs, so the IP can never match. If your LAN DNS does not
> resolve the hostname to the private IP, add an internal DNS record
> (split-horizon also lets you keep the private IP out of public DNS).

## Prerequisites

- The DNS zone for `example.com` is managed where the DNS provider's
  API can write TXT records (IONOS Control Panel for this guide).
- An **IONOS API key** (prefix + secret) — see Step 2.
- `certbot` + `certbot-dns-ionos` installed on the **FMS machine**
  (Step 1).
- OData enabled if you need it: `sudo fmsadmin start odata`, plus the
  `fmodata` extended privilege in the database's privilege set.

## Step 1 — Install certbot and the IONOS plugin (on FMS)

certbot and the IONOS plugin go together in a dedicated venv at
`/opt/certbot-venv`. This is the **primary** install path: Homebrew's
`certbot` runs in its own isolated venv that blocks system `pip`
installs (PEP 668), and a plugin installed into Homebrew's venv is wiped
on every `brew upgrade certbot`. The standalone venv is independent and
survives upgrades.

```bash
./scripts/install-certbot-venv.sh
```

or by hand:

```bash
# /opt is root-owned: create the venv dir with sudo, then hand it to your
# user so future pip upgrades don't need sudo:
sudo mkdir -p /opt/certbot-venv
sudo chown "$(stat -f '%u:%g' "$HOME")" /opt/certbot-venv

python3 -m venv /opt/certbot-venv
/opt/certbot-venv/bin/pip install --upgrade pip certbot certbot-dns-ionos
```

Verify the plugin registered:

```bash
/opt/certbot-venv/bin/certbot plugins 2>&1 | grep -A3 dns-ionos
# Expected: * dns-ionos ... Interfaces: Authenticator, Plugin
```

> All `certbot` commands in this doc use `/opt/certbot-venv/bin/certbot`
> (not a bare `certbot`, which would resolve to Homebrew's certbot
> without the plugin).

## Step 2 — Create the DNS API key (IONOS)

1. Go to `https://developer.hosting.ionos.es/keys`
2. Click **Create New Key**, name it e.g. `certbot-dns01`
3. You get **prefix** (public) and **secret** (private). Copy both —
   the secret is shown only once.

> Treat the secret like a password. Never commit it to git, never paste
> it in chat. If it leaks, delete the key in the IONOS portal and make
> a new one.

## Step 3 — Create the certbot credentials file

The plugin reads an INI file with the API key. This is certbot's own
secrets dir — separate from any project `.env`.

```bash
sudo mkdir -p /etc/letsencrypt/.secrets
sudo tee /etc/letsencrypt/.secrets/ionos.ini > /dev/null << 'EOF'
dns_ionos_prefix = YOUR_PREFIX
dns_ionos_secret = YOUR_SECRET
dns_ionos_endpoint = https://api.hosting.ionos.com
EOF
sudo chmod 600 /etc/letsencrypt/.secrets/ionos.ini
sudo chmod 700 /etc/letsencrypt/.secrets
```

(`config/ionos.ini.example` is a copy of this template.)

> **Permissions are mandatory**: certbot warns/refuses if the file is
> world-readable.

Verify the key works:

```bash
curl -sS "https://api.hosting.ionos.com/dns/v1/zones" \
  -H "X-API-Key: YOUR_PREFIX.YOUR_SECRET" | head -c 200
```

You should get JSON listing your DNS zones. `401 Unauthorized` means
the key is wrong or not activated.

## Step 4 — Create the DNS A record

Clients need `fms.example.com` to resolve to the FMS internal IP. In
IONOS DNS:

```bash
# Find the zone ID:
curl -sS "https://api.hosting.ionos.com/dns/v1/zones" \
  -H "X-API-Key: YOUR_PREFIX.YOUR_SECRET" | python3 -m json.tool \
  | grep -B5 "example.com"

# Create the A record:
curl -sS -X POST "https://api.hosting.ionos.com/dns/v1/zones/<zone-id>/records" \
  -H "X-API-Key: YOUR_PREFIX.YOUR_SECRET" \
  -H "Content-Type: application/json" \
  -d '[{
    "name": "fms.example.com",
    "type": "A",
    "content": "192.168.x.x",
    "ttl": 3600,
    "disabled": false,
    "prio": 0
  }]'
```

or via the IONOS Control Panel → DNS settings:

| Type | Name | Value | TTL |
| ---- | ---- | ----- | --- |
| A | `fms` | `192.168.x.x` | 3600 |

> **Private IP in public DNS** is fine — LE never checks the A record.
> If you'd rather not publish the private IP, use split-horizon DNS:
> internal DNS resolves `fms.example.com` → `192.168.x.x`, public DNS
> has no A record. Renewal still works (TXT only).

Verify: `dig fms.example.com +short` → `192.168.x.x`.

## Step 5 — Request the certificate

```bash
sudo /opt/certbot-venv/bin/certbot certonly \
  --authenticator dns-ionos \
  --dns-ionos-credentials /etc/letsencrypt/.secrets/ionos.ini \
  --dns-ionos-propagation-seconds 60 \
  --agree-tos \
  --email admin@example.com \
  --no-eff-email \
  -d fms.example.com
```

The plugin creates `_acme-challenge.fms.example.com` TXT → waits → LE
verifies → deletes the TXT → cert lands in
`/etc/letsencrypt/live/fms.example.com/`
(`fullchain.pem`, `privkey.pem`, `chain.pem`, `cert.pem`).

## Step 6 — Import the cert into FileMaker Server

`fmsadmin` reads cert files as the `fmserver` user, but certbot's
`/etc/letsencrypt/live/` and `archive/` are `drwx------ root root` —
`fmserver` cannot traverse them, so importing directly fails with
`Error: 20405 (File not found or not accessible)`. Copy the files into a
staging dir `fmserver:fmsadmin` can read, then import from there. (This
is also exactly what the automated deploy hook does.)

`fmsadmin` also requires **Admin Console credentials** — interactively
it prompts for them; unattended it needs `-u`/`-p` (see Step 9).

```bash
STAGING="/Library/FileMaker Server/CStore/letsencrypt-staging"
sudo mkdir -p "$STAGING"
sudo cp /etc/letsencrypt/live/fms.example.com/fullchain.pem \
        /etc/letsencrypt/live/fms.example.com/privkey.pem \
        /etc/letsencrypt/live/fms.example.com/chain.pem \
        "$STAGING/"
sudo chown -R fmserver:fmsadmin "$STAGING"
sudo chmod 750 "$STAGING"
sudo chmod 640 "$STAGING"/*.pem

# If a custom cert is already installed, delete it first
# ("no cert to delete" on first install is fine):
sudo fmsadmin certificate delete -y 2>/dev/null

# Import — enter Admin Console user/pass at the prompt:
sudo fmsadmin certificate import \
  "$STAGING/fullchain.pem" \
  --keyfile "$STAGING/privkey.pem" \
  --intermediateCA "$STAGING/chain.pem" -y
```

This creates `/Library/FileMaker Server/CStore/serverCustom.pem`.

> **Always `delete` before `import`** on renewals — otherwise you get
> `Certificate not imported, alias <...> already exists`.
>
> **Leave `$STAGING` in place** — the deploy hook reuses it on every
> renewal.

`./scripts/manual-import.sh` does all of Step 6 + Step 7 in one go.

## Step 7 — Reload the cert into FileMaker Server

Two separate services consume `serverCustom.pem`, and each needs its own
reload (httpd is a **separate** launchd job family — restarting
`com.filemaker.fms` does not touch Apache and vice versa):

```bash
# Apache (port 443 — WebDirect, OData, Data API, hosted web apps).
# Graceful reload picks up the new cert with no connection drops:
sudo launchctl kickstart -k system/com.filemaker.httpd.graceful

# Database server (port 5003 — FileMaker Pro client connections).
# Needs a real restart to load the cert; briefly disconnects clients:
sudo launchctl kickstart -k system/com.filemaker.fms
```

Wait ~10 seconds after the fms kickstart, then confirm the stack is
back:

```bash
nc -vz localhost 5003    # FM clients — must succeed
nc -vz localhost 16001   # Admin Console — must succeed
nc -vz localhost 443     # Apache — must succeed
```

> **Do not use `launchctl stop` + `launchctl start` on
> `com.filemaker.fms`.** Observed in production: `start` silently
> no-op'd and left the whole FMS stack (database server, Admin Console)
> down while Apache kept running. `kickstart -k` performs kill+restart
> atomically and is the reliable way to bounce a LaunchDaemon.
> (`fmsadmin restart wpe` is also not enough — it doesn't reload certs.)

## Step 8 — Verify

`./scripts/verify-cert.sh fms.example.com` runs the checks below (plus
port 5003). Manually:

```bash
# What Apache serves (should show LE issuer, new dates):
openssl s_client -connect localhost:443 -servername fms.example.com \
  </dev/null 2>/dev/null \
  | openssl x509 -noout -subject -issuer -dates -ext subjectAltName
```

Expected: `subject=CN=fms.example.com`, `issuer=... Let's Encrypt ...`,
fresh `notBefore`/`notAfter`, SAN `DNS:fms.example.com`.

```bash
# Strict TLS (no -k) — must succeed:
curl -sS -o /dev/null -w "HTTP %{http_code}\n" https://fms.example.com/

# If your resolver can't see the A record (split-horizon), pin the IP:
curl -sS --resolve fms.example.com:443:192.168.x.x \
  -o /dev/null -w "HTTP %{http_code}\n" https://fms.example.com/
```

Any HTTP response code without an SSL error means the cert is properly
trusted. If you get an SSL error, the chain wasn't imported correctly —
re-check Step 6.

## Step 9 — Automated renewal via launchd

LE certs live 90 days. Run `certbot renew` daily via launchd — certbot
only actually renews inside the last 30 days, so daily checks are safe.

### 9a — Credentials file for the deploy hook

`fmsadmin` requires Admin Console credentials. The hook runs as root
under launchd with **no TTY** — it cannot prompt, so creds come from a
root-readable file:

```bash
sudo tee /etc/letsencrypt/.secrets/fmsadmin.env > /dev/null << 'EOF'
FMSADMIN_USER=admin
FMSADMIN_PASS=YOUR_ADMIN_CONSOLE_PASSWORD
EOF
sudo chmod 600 /etc/letsencrypt/.secrets/fmsadmin.env
```

(`config/fmsadmin.env.example` is a copy of this template.)

### 9b — Install the deploy hook

```bash
sudo cp scripts/install-fms-cert.sh /etc/letsencrypt/renewal-hooks/deploy/install-fms-cert.sh
sudo chmod +x /etc/letsencrypt/renewal-hooks/deploy/install-fms-cert.sh
```

The hook (`scripts/install-fms-cert.sh`): stages the renewed cert,
`fmsadmin -u/-p` delete + import, `httpd.graceful` reload, `fms`
kickstart.

> **Why the creds file is mandatory**: a hook that calls `fmsadmin`
> without `-u`/`-p` fails under launchd — `fmsadmin` tries to prompt,
> gets no TTY, errors out, and `set -e` aborts before the import. That
> exact failure mode left a valid renewed cert sitting in staging while
> the expired cert kept serving (see `docs/lessons-learned.md`).

Test it (briefly bounces FMS — run when a few seconds of client
disconnect is OK):

```bash
sudo /etc/letsencrypt/renewal-hooks/deploy/install-fms-cert.sh && echo HOOK-OK
```

### 9c — Install and load the launchd daemon

```bash
sudo cp config/com.letsencrypt.renew.plist /Library/LaunchDaemons/
sudo launchctl load -w /Library/LaunchDaemons/com.letsencrypt.renew.plist
sudo launchctl list | grep letsencrypt    # expect: com.letsencrypt.renew
```

It runs `certbot renew --quiet` daily at 03:30, logging to
`/var/log/letsencrypt-renew.log`.

> The plist points at `/opt/certbot-venv/bin/certbot` (the Step 1 venv).
> Don't change it to a bare `certbot` — launchd's PATH won't include
> the venv, and Homebrew's certbot lacks the plugin.

### 9d — Dry-run the whole flow

```bash
sudo /opt/certbot-venv/bin/certbot renew --dry-run
```

Should create TXT → verify → delete TXT → report success. On failure,
check `/var/log/letsencrypt/letsencrypt.log`.

## Step 10 — Scheduled verification + email reports

Renewal failures are silent until the cert expires — see
`docs/lessons-learned.md`. `scripts/check-cert-and-report.sh` closes
that gap: a daily check of the cert on ports 443 **and** 5003 (each is
a separate consumer), days-to-expiry, a strict-TLS fetch, and the
service ports, with an email report via curl/SMTPS (no local MTA).

Run from the repo root (the `scripts/` and `config/` paths are relative):

```bash
sudo cp scripts/check-cert-and-report.sh /usr/local/bin/fms-cert-check.sh
sudo chmod +x /usr/local/bin/fms-cert-check.sh
sudo cp config/fms-cert-check.env.example /etc/fms-cert-check.env
sudo chmod 600 /etc/fms-cert-check.env      # then edit DOMAIN + SMTP vars
sudo cp config/com.fms.certcheck.plist /Library/LaunchDaemons/
sudo launchctl load -w /Library/LaunchDaemons/com.fms.certcheck.plist
```

Test it:

```bash
sudo /usr/local/bin/fms-cert-check.sh --dry-run       # print report, no email
sudo /usr/local/bin/fms-cert-check.sh --force-email   # send now regardless
```

The daemon runs at 04:00, right after the 03:30 renewal window, so a
failed renewal+import is reported the same morning. By default it
emails on WARN/FAIL plus a weekly OK heartbeat (Monday) — set
`ALWAYS_SEND=1` for a daily report.

## Troubleshooting

### `Certificate not imported, alias <...> already exists`

You forgot to `fmsadmin certificate delete` first. Run it, then re-run
the import.

### `curl` still shows the old cert / expiry date didn't change

Apache didn't reload. Graceful-reload httpd (and kickstart the DB
server so port 5003 picks it up too):

```bash
sudo launchctl kickstart -k system/com.filemaker.httpd.graceful
sudo launchctl kickstart -k system/com.filemaker.fms
nc -vz localhost 5003    # confirm DB server is back
```

### Admin Console "Request Certificate" fails: "timeout verifying challenge"

Expected — FMS's built-in LE request is HTTP-01 and cannot work here
(see Problem). Renewal is certbot-only; leave that button alone.

### FileMaker client shows red lock / "certificate does not match"

The client connects by IP or Bonjour name. The cert only covers the
hostname — add the server under `fms.example.com` in FileMaker's
Hosts / Open Remote dialog.

### Renewal ran but FMS still serves the expired cert

The deploy hook imported nothing — usually missing `fmsadmin` creds
(no TTY under launchd). Symptom: fresh files in the staging dir at
renewal time but an old `serverCustom.pem` timestamp. Confirm the hook
sources `fmsadmin.env` and passes `-u`/`-p`, and test auth:

```bash
sudo /usr/local/bin/fmsadmin -u admin -p 'YOUR_PASS' server status
```

Fix the password in `fmsadmin.env` if needed, then re-run the hook.

### `launchctl stop com.filemaker.fms` left FMS down / port 5003 refused

`launchctl start` can silently fail to bring the daemon back. Recover:

```bash
sudo launchctl start com.filemaker.fms
# if still down:
sudo launchctl kickstart system/com.filemaker.fms
# or:
sudo launchctl bootstrap system /Library/LaunchDaemons/com.filemaker.fms.plist
```

Verify with `nc -vz localhost 5003`. Prefer `kickstart -k` everywhere.

### `openssl s_client` shows the default FileMaker cert (not LE)

`serverCustom.pem` wasn't created in CStore or isn't readable. Check
`ls -la "/Library/FileMaker Server/CStore/serverCustom.pem"` — if
missing, the import failed; re-run and read the error.

### DNS-01 validation fails ("DNS problem: TXT record not found")

1. Verify the API key works (Step 3 curl).
2. Raise propagation wait: `--dns-ionos-propagation-seconds 120`.
3. Check `/var/log/letsencrypt/letsencrypt.log` for the exact error.

### `certbot renew` fails silently / launchd agent not running

```bash
sudo launchctl list | grep letsencrypt
cat /var/log/letsencrypt-renew.log
sudo tail -50 /var/log/letsencrypt/letsencrypt.log
```

Common causes: rotated/deleted API key, provider API down, wrong
certbot path in the plist.

### `pip3 install certbot-dns-ionos` fails (PEP 668)

Expected on newer macOS — system pip is blocked. The standalone venv in
Step 1 is the supported path. If the venv was lost, re-run
`scripts/install-certbot-venv.sh`.

## Security notes

- The IONOS API secret is as sensitive as the account password.
  `/etc/letsencrypt/.secrets/ionos.ini` must be `chmod 600`. Never
  commit it.
- The Admin Console credentials in
  `/etc/letsencrypt/.secrets/fmsadmin.env` get the same treatment. If
  the admin password is ever rotated, update this file — otherwise
  every renewal fails at the import step.
- `privkey.pem` stays root-only under `/etc/letsencrypt/`.
- The plugin deletes the `_acme-challenge` TXT record automatically
  after issuance.
- Publishing a private IP in public DNS (the A record) is harmless but
  optional — use split-horizon DNS if you prefer not to.
