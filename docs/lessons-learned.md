# Lessons learned — real incident write-up

A write-up of an actual cert-expiry incident on a production FMS host
(dates anonymized but real). Each failure mode maps to a fix that is now
baked into this repo's scripts and guide.

## Timeline

- **T-90d**: LE cert issued via certbot DNS-01 (IONOS), manually
  imported into FMS. Worked fine.
- **T-30d**: The launchd `certbot renew` job successfully renewed the
  cert at 03:31. The deploy hook copied the files into the FMS staging
  dir… and then called `fmsadmin certificate delete` / `import`
  **without credentials**. Under launchd there is no TTY, so `fmsadmin`
  tried to prompt, failed, and `set -e` aborted the hook before the
  restart commands. The new cert sat in staging; `serverCustom.pem`
  kept the old cert. Nobody noticed — there was no alerting.
- **T-1d**: Cert expired overnight. Web Viewer fetches, OData, and FM
  client connections all started failing TLS validation.
- **Day 0**: Operator saw the expired cert, opened Admin Console, and
  clicked the built-in **"Request Let's Encrypt Certificate"** button.
  It failed with `Let's Encrypt Request failed: Failure / timeout
  verifying challenge passed` — twice more over the following days.
- **Fix**: manual `fmsadmin certificate import` of the staged cert
  (valid for ~60 more days), then service reloads.

## Failure modes observed

### 1. Deploy hook with no `fmsadmin` credentials

`fmsadmin` always needs Admin Console credentials. Interactively it
prompts; under launchd the prompt has no TTY and the command fails.
With `set -e`, everything after it (the service reloads) never ran.

**Fix baked in**: the hook sources
`/etc/letsencrypt/.secrets/fmsadmin.env` and passes `-u`/`-p`.

### 2. Admin Console built-in LE request = HTTP-01

FMS's native "Request Let's Encrypt Certificate" uses HTTP-01 — it
requires LE to reach `http://<host>/.well-known/...` over the public
internet. On a host with a private-IP A record and no port 80/443
forwarding, it can *only* time out. Worse, each click consumes LE's
failed-validation rate limit (5 per hostname per hour).

**Fix baked in**: warning callout at the top of `guide.md` +
troubleshooting entry.

### 3. `launchctl stop` + `start` on `com.filemaker.fms` is unreliable

During the fix, `sudo launchctl stop com.filemaker.fms` took the whole
FMS stack down, but `sudo launchctl start` silently no-op'd — launchd
reported the job `not running` while Apache (a *separate* job family,
`com.filemaker.httpd.*`) kept serving the stale cert. The database
server stayed down until a second `start` eventually took.

**Fix baked in**: everything uses `launchctl kickstart -k` (atomic
kill+restart) — `system/com.filemaker.httpd.graceful` for Apache,
`system/com.filemaker.fms` for the DB server.

### 4. Two cert consumers, two reload mechanisms

`serverCustom.pem` is used by **both** Apache (port 443) and the
database server (port 5003). Restarting one does nothing for the other:

- Apache: `kickstart -k system/com.filemaker.httpd.graceful` — reloads
  config + cert, no drops.
- DB server: `kickstart -k system/com.filemaker.fms` — brief client
  disconnect, unavoidable (the cert is read at process start).

`fmsadmin restart wpe` touches neither.

### 5. FM clients connecting by IP → "certificate does not match"

After the new cert was live, a FileMaker Pro client still showed a red
lock. Cause: the host was saved as the IP address, and the cert SAN
only covers the hostname. Connecting via `fms.example.com` fixed it —
same machine, same route, matching name.

**Fix baked in**: prerequisite note in `guide.md` + troubleshooting
entry. (LE cannot issue certs for private-IP SANs anyway.)

## What would have prevented the incident

- The creds'd deploy hook (this repo).
- A hook test right after setup:
  `sudo /etc/letsencrypt/renewal-hooks/deploy/install-fms-cert.sh`
- Cert monitoring — even a cron'd `verify-cert.sh` that warns when
  `notAfter` is < 14 days out on either port 443 or 5003.
