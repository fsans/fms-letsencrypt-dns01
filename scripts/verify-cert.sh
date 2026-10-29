#!/bin/bash
# verify-cert.sh — checks the LE cert health on the FMS host.
#
# Usage:  ./verify-cert.sh [hostname] [connect-host]
#   hostname      cert CN/SAN to check      (default fms.example.com)
#   connect-host  where to connect          (default localhost — run on FMS)
#
# No sudo needed. Exit 0 if everything looks OK.
DOMAIN="${1:-fms.example.com}"
HOST="${2:-localhost}"
FAIL=0

days_until() {  # $1 = notAfter string
  local end epoch now
  end=$(echo "$1" | sed 's/notAfter=//')
  epoch=$(date -j -f "%b %d %H:%M:%S %Y" "$end" +%s 2>/dev/null || \
          date -d "$end" +%s 2>/dev/null)
  now=$(date +%s)
  echo $(( (epoch - now) / 86400 ))
}

for PORT in 443 5003; do
  echo "=== port $PORT ==="
  OUT=$(openssl s_client -connect "$HOST:$PORT" -servername "$DOMAIN" \
        </dev/null 2>/dev/null | openssl x509 -noout -subject -issuer -dates)
  if [ -z "$OUT" ]; then
    echo "  !! could not retrieve cert on port $PORT"
    FAIL=1; continue
  fi
  echo "$OUT" | sed 's/^/  /'
  SUBJ=$(echo "$OUT" | grep '^subject=')
  [[ "$SUBJ" == *"$DOMAIN"* ]] || { echo "  !! CN does not match $DOMAIN"; FAIL=1; }
  DAYS=$(days_until "$(echo "$OUT" | grep '^notAfter=')")
  if [ "$DAYS" -lt 0 ]; then
    echo "  !! EXPIRED $((-DAYS)) days ago"; FAIL=1
  elif [ "$DAYS" -lt 14 ]; then
    echo "  !! expires in $DAYS days — renewal/import problem?"
  else
    echo "  OK: $DAYS days remaining"
  fi
done

echo "=== strict TLS fetch (no -k) ==="
if curl -sS -m 8 -o /dev/null -w "  HTTP %{http_code} in %{time_total}s\n" \
    "https://$DOMAIN/"; then
  echo "  OK: cert trusted by system store"
else
  echo "  !! strict TLS failed"; FAIL=1
fi

echo "=== ports ==="
for P in 5003 16001 443; do
  nc -vz -G 3 "$HOST" "$P" 2>&1 | sed 's/^/  /' || FAIL=1
done

exit $FAIL
