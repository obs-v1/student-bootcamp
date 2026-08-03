#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# bankobs continuous load runner
#
# A gentle, always-on background load that exercises EVERY user journey, so the
# dashboards, traces, and SLOs always have live data — even when nobody is
# clicking. Meant to run under systemd (see bankobs-loadrunner.service): it
# waits for the portal to come up, logs in, then loops a light mix of journeys
# at a low rate. Deliberately minimal — a heartbeat, not a stress test.
#
# Journeys exercised: login · balance read · UPI payment · loan application ·
#                     a forced failure (ghost VPA) to keep error views alive.
#
# Tunables (env):
#   PORTAL    portal base URL               (default http://localhost)
#   CUST/PASS login customer id / password  (default CUST-00000001 / Training@123)
#   INTERVAL  seconds between requests       (default 2  -> ~0.5 req/s, minimal)
#   FAIL_PCT  % of requests forced to fail   (default 8)
# ---------------------------------------------------------------------------
set -u

PORTAL="${PORTAL:-http://localhost}"
CUST="${CUST:-CUST-00000001}"
PASS="${PASS:-Training@123}"
INTERVAL="${INTERVAL:-2}"
FAIL_PCT="${FAIL_PCT:-8}"
COOKIE="$(mktemp /tmp/bankobs-lr.XXXXXX)"
trap 'rm -f "$COOKIE"' EXIT

log() { printf '%s loadrunner: %s\n' "$(date -u +%FT%TZ)" "$*"; }

# a random seeded customer VPA (the app seeds custNNNNNNNN@bankobs)
vpa() { printf 'cust%08d@bankobs' "$(( (RANDOM % 5) + 1 ))"; }

login() {
  curl -s -m 8 -c "$COOKIE" -X POST "$PORTAL/api/auth/login" \
    -H 'Content-Type: application/json' \
    -d "{\"customer_id\":\"$CUST\",\"password\":\"$PASS\"}" >/dev/null 2>&1
}

# --- the journeys (each is best-effort; errors are swallowed) ---
j_balance() { curl -s -m 10 -b "$COOKIE" "$PORTAL/api/balance/" >/dev/null 2>&1; }

j_upi() {
  local a b amt; a="$(vpa)"; b="$(vpa)"; amt=$(( (RANDOM % 20000) + 100 ))
  curl -s -m 15 -b "$COOKIE" -X POST "$PORTAL/api/upi/pay" \
    -H 'Content-Type: application/json' \
    -d "{\"from_vpa\":\"$a\",\"to_vpa\":\"$b\",\"amount\":$amt,\"remarks\":\"loadrunner\"}" >/dev/null 2>&1
}

j_loan() {
  local amt; amt=$(( (RANDOM % 300000) + 50000 ))
  curl -s -m 20 -b "$COOKIE" -X POST "$PORTAL/api/loans/apply" \
    -H 'Content-Type: application/json' \
    -d "{\"amount\":$amt,\"tenure_months\":24,\"purpose\":\"PERSONAL\"}" >/dev/null 2>&1
}

# ghost VPA -> insufficient funds -> keeps the error dashboards / SLO burn alive
j_fail() {
  curl -s -m 15 -b "$COOKIE" -X POST "$PORTAL/api/upi/pay" \
    -H 'Content-Type: application/json' \
    -d "{\"from_vpa\":\"ghost9999@bankobs\",\"to_vpa\":\"$(vpa)\",\"amount\":500,\"remarks\":\"loadrunner-fail\"}" >/dev/null 2>&1
}

# --- wait for the stack, then loop forever ---
log "waiting for portal $PORTAL/api/health ..."
until curl -sf -m 5 "$PORTAL/api/health" >/dev/null 2>&1; do sleep 10; done
log "portal healthy — starting (interval=${INTERVAL}s, fail=${FAIL_PCT}%)"
login

i=0
while true; do
  i=$(( i + 1 ))
  # refresh the session + emit a heartbeat every ~120 requests
  [ $(( i % 120 )) -eq 0 ] && { login; log "heartbeat: ${i} requests sent"; }

  r=$(( RANDOM % 100 ))
  if   [ "$r" -lt "$FAIL_PCT" ];            then j_fail        # forced failures
  elif [ "$r" -lt $(( FAIL_PCT + 40 )) ];   then j_upi         # ~40% payments
  elif [ "$r" -lt $(( FAIL_PCT + 70 )) ];   then j_balance     # ~30% reads
  else                                            j_loan        # the rest: loans
  fi
  sleep "$INTERVAL"
done
