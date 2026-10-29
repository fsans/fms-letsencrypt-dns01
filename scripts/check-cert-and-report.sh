#!/bin/bash
# check-cert-and-report.sh — daily health check of the FMS LE cert:
# cert served on 443 + 5003 (CN match, days to expiry), strict-TLS fetch,
# and service ports. Emails a status report via curl/SMTPS (no MTA needed).
#
# Install:  sudo cp check-cert-and-report.sh /usr/local/bin/fms-cert-check.sh
#           sudo chmod +x /usr/local/bin/fms-cert-check.sh
#           sudo cp ../config/com.fms.certcheck.plist /Library/LaunchDaemons/
#           sudo launchctl load -w /Library/LaunchDaemons/com.fms.certcheck.plist
#
# Config:   /etc/fms-cert-check.env  (see config/fms-cert-check.env.example)
# Flags:    --dry-run      print report to stdout, don't email
#           --force-email  send email regardless of send policy
set -u

# ---- defaults (override in /etc/fms-cert-check.env) -------------------
DOMAIN=fms.example.com
CONNECT_HOST=localhost        # run on the FMS machine
WARN_DAYS=30                  # warn when fewer days than this remain
ADMIN_EMAIL=admin@example.com
EMAIL_FROM=noreply@example.com
SMTP_USER=
SMTP_PASS=
SMTP_URL=smtps://smtp.example.com:465   # or smtp://host:587 for STARTTLS
ALWAYS_SEND=0                 # 1 = email every run
OK_REPORT_DOW=1               # weekly OK heartbeat on this weekday (1=Mon)
LOG_FILE=/var/log/fms-cert-check.log
CONFIG=/etc/fms-cert-check.env
# ------------------------------------------------------------------------

DRY=0; FORCE=0
for a in "$@"; do
  case "$a" in
    --dry-run)     DRY=1 ;;
    --force-email) FORCE=1 ;;
  esac
done

[ -f "$CONFIG" ] && source "$CONFIG"
touch "$LOG_FILE" 2>/dev/null || LOG_FILE="$(dirname "$0")/fms-cert-check.log"

STATUS=OK
REPORT=$(mktemp /tmp/fms-cert-check.XXXXXX)
{
  echo "FMS certificate check — $(hostname) — $(date '+%Y-%m-%d %H:%M:%S %z')"
  echo "Domain: $DOMAIN   Connect host: $CONNECT_HOST"
  echo "----------------------------------------------------------------"
} >> "$REPORT"

fail() { echo "  FAIL: $1" >> "$REPORT"; STATUS=FAIL; }
warn() { echo "  WARN: $1" >> "$REPORT"; [ "$STATUS" = OK ] && STATUS=WARN; }

days_until() {
  local end epoch
  end=$(echo "$1" | sed 's/notAfter=//')
  epoch=$(date -j -f "%b %d %H:%M:%S %Y" "$end" +%s 2>/dev/null || date -d "$end" +%s 2>/dev/null)
  echo $(( (epoch - $(date +%s)) / 86400 ))
}

# --- cert served on 443 (Apache) and 5003 (database server) ---
for PORT in 443 5003; do
  echo >> "$REPORT"
  echo "Port $PORT cert:" >> "$REPORT"
  OUT=$(openssl s_client -connect "$CONNECT_HOST:$PORT" -servername "$DOMAIN" \
        </dev/null 2>/dev/null | openssl x509 -noout -subject -issuer -dates)
  if [ -z "$OUT" ]; then
    fail "no certificate retrievable on port $PORT (service down or cert missing)"
    continue
  fi
  echo "$OUT" | sed 's/^/  /' >> "$REPORT"
  echo "$OUT" | grep -q "CN *= *$DOMAIN\|CN=$DOMAIN" \
    || fail "port $PORT cert CN does not match $DOMAIN"
  DAYS=$(days_until "$(echo "$OUT" | grep '^notAfter=')")
  if [ "$DAYS" -lt 0 ]; then
    fail "port $PORT cert EXPIRED $((-DAYS)) days ago"
  elif [ "$DAYS" -lt "$WARN_DAYS" ]; then
    warn "port $PORT cert expires in $DAYS days — check renewal/deploy hook"
  else
    echo "  OK: $DAYS days remaining" >> "$REPORT"
  fi
done

# --- strict TLS fetch ---
echo >> "$REPORT"
echo "Strict TLS fetch (no -k) https://$DOMAIN/:" >> "$REPORT"
if curl -sS -m 8 -o /dev/null -w "  HTTP %{http_code} in %{time_total}s\n" \
    "https://$DOMAIN/" >> "$REPORT" 2>&1; then
  echo "  OK: cert trusted by system store" >> "$REPORT"
else
  fail "strict TLS fetch failed (expired cert / wrong chain / hostname mismatch)"
fi

# --- service ports ---
echo >> "$REPORT"
echo "Service ports:" >> "$REPORT"
for P in 5003 443 16001; do
  if nc -vz -G 3 "$CONNECT_HOST" "$P" >> "$REPORT" 2>&1; then :; else
    if [ "$P" = 16001 ]; then
      warn "port $P (Admin Console) refused"
    else
      fail "port $P refused"
    fi
  fi
done

echo >> "$REPORT"
echo "RESULT: $STATUS" >> "$REPORT"
cat "$REPORT" >> "$LOG_FILE"
echo "---" >> "$LOG_FILE"

# --- send decision: always on FAIL/WARN; OK only per policy/heartbeat ---
DOW=$(date +%u)
SEND=0
[ "$STATUS" != "OK" ] && SEND=1
[ "$ALWAYS_SEND" = "1" ] && SEND=1
[ "$STATUS" = "OK" ] && [ "$DOW" = "$OK_REPORT_DOW" ] && SEND=1
[ "$FORCE" = "1" ] && SEND=1

SUBJECT="[FMS cert] $STATUS — $DOMAIN ($(hostname))"
if [ "$DRY" = "1" ]; then
  cat "$REPORT"
  echo "(dry-run: email suppressed; would send=$SEND, subject: $SUBJECT)"
elif [ "$SEND" = "1" ]; then
  {
    echo "From: $EMAIL_FROM"
    echo "To: $ADMIN_EMAIL"
    echo "Subject: $SUBJECT"
    echo "Content-Type: text/plain; charset=utf-8"
    echo
    cat "$REPORT"
  } | curl -sS --ssl-reqd --url "$SMTP_URL" \
      --mail-from "$EMAIL_FROM" --mail-rcpt "$ADMIN_EMAIL" \
      ${SMTP_USER:+--user "$SMTP_USER:$SMTP_PASS"} \
      --upload-file - >> "$LOG_FILE" 2>&1 \
    && echo "$(date '+%F %T') report emailed ($STATUS)" >> "$LOG_FILE" \
    || echo "$(date '+%F %T') EMAIL SEND FAILED" >> "$LOG_FILE"
fi

rm -f "$REPORT"
[ "$STATUS" = FAIL ] && exit 1
exit 0
