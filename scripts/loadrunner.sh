#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# bankobs continuous load runner
#
# A gentle, always-on background load that exercises EVERY journey and drives
# traffic to EVERY service, so the dashboards, traces, SLOs and per-service RED
# metrics always have live data — even when nobody is clicking. Runs under
# systemd (see bankobs-loadrunner.service).
#
# Two tiers, because they reach different things:
#
#   TIER 1 — portal journeys (every cycle)
#       Real user paths through the web portal's API, with a logged-in session.
#       These produce the multi-span traces the labs are about: e.g. a UPI
#       payment crossing gateway → payment-gateway → upi-service →
#       fraud-detection → account-service → notification-orchestrator.
#
#   TIER 2 — in-cluster service sweep (every SWEEP_EVERY cycles)
#       The portal only fronts ~20 of the 59 services; the rest (fraud/risk
#       tier, audit & compliance, notification channels, legacy sims, the
#       adapters) have no user-facing path at all. Kubernetes publishes only
#       four host ports, so those services are unreachable from this host —
#       the sweep therefore runs a batch of requests from INSIDE the cluster
#       via `kubectl exec`, addressing each service by its own DNS name.
#       Single-span traces, but every service keeps reporting RED metrics.
#       In docker-compose mode it hits localhost:1<port> directly instead.
#
# Without tier 2, ~40 services sit idle and show no http_server_requests_total
# at all — Prometheus client libraries publish nothing for a labelled metric
# family until its first observation, so an idle service looks uninstrumented.
#
# Tunables (env):
#   PORTAL       portal base URL                  (default http://localhost)
#   CUST/PASS    login customer id / password     (default CUST-00000001 / Training@123)
#   INTERVAL     seconds between journeys         (default 2 -> ~0.5 req/s)
#   FAIL_PCT     % of journeys forced to fail     (default 8)
#   SWEEP_EVERY  run the service sweep every N cycles (default 15; 0 disables)
#   NS           kubernetes namespace             (default bankobs)
#   SWEEP_POD    pod to run the sweep from        (default: auto-detect one with curl)
# ---------------------------------------------------------------------------
set -u

PORTAL="${PORTAL:-http://localhost}"
CUST="${CUST:-CUST-00000001}"
PASS="${PASS:-Training@123}"
INTERVAL="${INTERVAL:-2}"
FAIL_PCT="${FAIL_PCT:-8}"
SWEEP_EVERY="${SWEEP_EVERY:-15}"
NS="${NS:-bankobs}"
SWEEP_POD="${SWEEP_POD:-}"
COOKIE="$(mktemp /tmp/bankobs-lr.XXXXXX)"
trap 'rm -f "$COOKIE"' EXIT

log() { printf '%s loadrunner: %s\n' "$(date -u +%FT%TZ)" "$*"; }

# ── seeded test data ───────────────────────────────────────────────────────
ACCT="ACC000000000001"
vpa()  { printf 'cust%08d@bankobs' "$(( (RANDOM % 5) + 1 ))"; }
cust() { printf 'CUST-%08d' "$(( (RANDOM % 5) + 1 ))"; }
amt()  { printf '%d' "$(( (RANDOM % 20000) + 100 ))"; }

# ── portal helpers (tier 1) ────────────────────────────────────────────────
login() {
  curl -s -m 8 -c "$COOKIE" -X POST "$PORTAL/api/auth/login" \
    -H 'Content-Type: application/json' \
    -d "{\"customer_id\":\"$CUST\",\"password\":\"$PASS\"}" >/dev/null 2>&1
}
pget()  { curl -s -m 15 -b "$COOKIE" "$PORTAL$1" >/dev/null 2>&1; }
ppost() { curl -s -m 20 -b "$COOKIE" -X POST "$PORTAL$1" -H 'Content-Type: application/json' -d "$2" >/dev/null 2>&1; }
pput()  { curl -s -m 20 -b "$COOKIE" -X PUT  "$PORTAL$1" -H 'Content-Type: application/json' -d "$2" >/dev/null 2>&1; }

# ── tier 1: the journeys ───────────────────────────────────────────────────
# Each is a small multi-step journey rather than one request, so the traces
# look like real user sessions.

j_upi() {                      # payments: the flagship vertical slice
  local a b; a="$(vpa)"; b="$(vpa)"
  ppost /api/upi/pay "{\"from_vpa\":\"$a\",\"to_vpa\":\"$b\",\"amount\":$(amt),\"remarks\":\"loadrunner\"}"
  pget "/api/balance/$ACCT"
}
j_upi_request() { ppost /api/upi/request "{\"from_vpa\":\"$(vpa)\",\"amount\":$(amt),\"note\":\"collect\"}"; }

j_accounts() {                 # core banking reads
  pget "/api/account/$ACCT"; pget "/api/balance/$ACCT"
  pget "/api/transactions/$ACCT"; pget "/api/statement/$ACCT/mini"
}

j_loan() {                     # retail: eligibility → apply → poll status
  ppost /api/loans/eligibility "{\"customer_id\":\"$(cust)\",\"monthly_income\":95000,\"existing_emi\":12000,\"credit_score\":760}"
  ppost /api/loans/apply "{\"amount\":$(( (RANDOM % 300000) + 50000 )),\"tenure_months\":24,\"purpose\":\"PERSONAL\"}"
  pget /api/loans
}

j_deposits() {                 # fixed + recurring deposits
  ppost /api/fd/create "{\"principal\":$(( (RANDOM % 400000) + 25000 )),\"tenureMonths\":12,\"interestRate\":7.1}"
  pget /api/fd/list
  ppost /api/rd/create "{\"monthlyAmount\":$(( (RANDOM % 9000) + 1000 )),\"tenureMonths\":24,\"interestRate\":6.8}"
  pget /api/rd/list
}

j_cards() {                    # credit cards: read the card, then act on it
  # cardId has to come from the listing — /api/cards/{limit,freeze,unfreeze}
  # need it, and freeze without it answers HTTP 200 with ok:false, which looks
  # like success on a dashboard. grep, not jq: keeps the script dependency-free.
  local cid
  cid=$(curl -s -m 15 -b "$COOKIE" "$PORTAL/api/cards/list" \
        | grep -oE '"(cardId|card_id)":"[^"]+"' | head -1 | cut -d'"' -f4)
  [ -z "$cid" ] && return 0
  pput  /api/cards/limit "{\"cardId\":\"$cid\",\"limit\":$(( (RANDOM % 400000) + 50000 ))}"
  ppost /api/cards/freeze   "{\"cardId\":\"$cid\"}"
  ppost /api/cards/unfreeze "{\"cardId\":\"$cid\"}"
}

j_rails() {                    # the other payment rails
  ppost /api/neft/initiate "{\"toAccount\":\"$ACCT\",\"ifsc\":\"BANK0000001\",\"amount\":$(amt)}"
  ppost /api/imps/initiate "{\"toAccount\":\"$ACCT\",\"ifsc\":\"BANK0000001\",\"amount\":$(amt)}"
  # RTGS has a ₹2,00,000 floor — anything less is a legitimate rejection.
  ppost /api/rtgs/initiate "{\"toAccount\":\"$ACCT\",\"ifsc\":\"BANK0000001\",\"amount\":$(( (RANDOM % 800000) + 200000 ))}"
}

j_crossborder() {              # FX + remittance
  pget /api/fx/rates; pget /api/fx/rates/USD
  pget /api/remittance/corridors
  ppost /api/remittance/initiate "{\"corridor\":\"IN-US\",\"amount\":$(amt),\"currency\":\"USD\"}"
}

j_identity() {                 # KYC status + an upgrade attempt
  pget "/api/kyc/$(cust)/status"
  ppost /api/kyc/upgrade '{"aadhaar":"123412341234","pan":"ABCDE1234F"}'
}

j_compliance() { ppost /api/compliance/check "{\"transaction_type\":\"UPI\",\"amount\":$(amt)}"; }

# ghost VPA -> insufficient funds -> keeps the error dashboards / SLO burn alive
j_fail() {
  ppost /api/upi/pay "{\"from_vpa\":\"ghost9999@bankobs\",\"to_vpa\":\"$(vpa)\",\"amount\":500,\"remarks\":\"loadrunner-fail\"}"
}

# Weighted journey mix: payments dominate, as they do in the real product.
JOURNEYS=(
  j_upi j_upi j_upi j_upi j_upi j_upi        # ~30% payments
  j_accounts j_accounts j_accounts j_accounts # ~20% core reads
  j_loan j_loan j_deposits j_cards            # retail
  j_rails j_rails j_crossborder               # other rails
  j_identity j_compliance j_upi_request       # identity / compliance / collect
)

# ── tier 2: every service, addressed directly ──────────────────────────────
# One line per service: name|port|METHOD|path|body
# Paths use seeded ids where they exist; a few return 404 for an unknown id,
# which is fine — the point is that the service records the request.
SERVICES='
account-service|8001|GET|/api/v1/accounts/ACC000000000001|
ledger-service|8002|GET|/api/v1/ledger/entries?accountId=ACC000000000001|
balance-service|8003|GET|/api/v1/balances/ACC000000000001|
statement-service|8004|GET|/api/v1/statements/ACC000000000001/mini|
interest-engine|8005|GET|/api/v1/interest/rates|
cheque-service|8006|GET|/api/v1/cheques/CHQ-0001/status|
branch-service|8007|GET|/api/v1/branches|
cbs-adapter|8008|GET|/cbs/balance/ACC000000000001|
payment-gateway|8010|GET|/api/v1/payments/rails|
upi-service|8011|GET|/api/v1/upi/vpa/validate/cust00000001@bankobs|
neft-service|8012|GET|/api/v1/neft/batches/pending|
rtgs-service|8013|GET|/api/v1/rtgs/status|
imps-service|8014|GET|/api/v1/imps/transactions/IMPS-0001|
nach-service|8015|GET|/api/v1/nach/mandates/MANDATE-0001|
bharat-qr-service|8016|GET|/api/v1/qr/QR-0001|
fx-service|8017|GET|/api/v1/fx/rates/USD|
remittance-service|8018|GET|/api/v1/remittance/corridors|
payment-router|8019|POST|/api/v1/router/select|{"payment_type":"UPI","amount":2500}
loan-service|8020|GET|/api/v1/loan/loans?customerId=CUST-00000001|
loan-origination|8021|GET|/api/v1/loan/applications/APP-0001/status|
fd-service|8022|GET|/api/v1/fd|
rd-service|8023|GET|/api/v1/rd|
credit-card-service|8024|GET|/api/v1/cards|
insurance-service|8025|GET|/api/v1/insurance/products|
demat-service|8026|GET|/api/v1/demat/DM-0001/holdings|
wealth-service|8027|GET|/api/v1/wealth/funds|
eligibility-engine|8028|POST|/api/v1/eligibility/loan|{"customer_id":"CUST-00000001","monthly_income":95000,"existing_emi":12000,"credit_score":760}
kyc-service|8030|GET|/api/v1/kyc/CUST-00000001/status|
onboarding-service|8031|GET|/api/v1/identity/sessions/SESS-0001|
aadhaar-adapter|8032|POST|/api/v1/aadhaar/verify|{"aadhaar":"123412341234","name":"Test User"}
pan-adapter|8033|GET|/api/v1/pan/ABCDE1234F/status|
ckyc-service|8034|POST|/api/v1/ckyc/search|{"pan":"ABCDE1234F"}
identity-vault|8035|GET|/api/v1/vault/00000000-0000-0000-0000-000000000000/masked|
consent-service|8036|GET|/api/v1/consent?customerId=CUST-00000001|
fraud-detection|8040|GET|/api/v1/fraud/alerts|
rules-engine|8041|GET|/api/v1/rules|
aml-service|8042|GET|/api/v1/aml/cases/CASE-0001|
sanctions-service|8043|POST|/api/v1/sanctions/screen|{"name":"John Doe","country":"IN"}
risk-scoring|8044|GET|/api/v1/risk/CUST-00000001/score|
case-management|8045|GET|/api/v1/cases|
transaction-monitor|8046|GET|/api/v1/monitor/stats|
velocity-checker|8047|POST|/api/v1/velocity/check|{"customer_id":"CUST-00000001","amount":2500}
notification-orchestrator|8050|GET|/api/v1/notifications/NOTIF-0001/status|
sms-gateway|8051|GET|/api/v1/sms/MSG-0001/status|
email-service|8052|GET|/api/v1/email/MSG-0001/status|
push-service|8053|GET|/api/v1/push/MSG-0001/status|
whatsapp-service|8054|GET|/api/v1/whatsapp/MSG-0001/status|
audit-service|8060|GET|/api/v1/audit/events?accountId=ACC000000000001|
rbi-reporter|8061|GET|/api/v1/rbi/reports/types|
pci-logger|8062|GET|/api/v1/pci/audit?date=2026-01-01|
cersai-adapter|8063|GET|/api/v1/cersai/REG-0001|
compliance-checker|8064|GET|/api/v1/compliance/rules|
report-generator|8065|GET|/api/v1/reports/RPT-0001|
weblogic-cbs-simulator|8070|GET|/cbs/status|
tomcat-loan-legacy|8071|GET|/legacy/status|
ibm-mq-bridge|8072|GET|/mq/manager/status|
gateway-service|8000|GET|/api/v1/payments/rails|
auth-service|8080|GET|/api/v1/auth/whoami|
rate-limiter|8082|POST|/api/v1/ratelimit/check|{"customerId":"CUST-00000001","endpoint":"/api/v1/upi/pay"}
'

SWEEP_MODE=""   # k8s | compose | off — decided once, on first sweep

# Find a pod that has curl. The Python service images install it; the portal's
# alpine image only has busybox wget, which cannot POST.
pick_sweep_pod() {
  [ -n "$SWEEP_POD" ] && return 0
  local c
  for c in deploy/kyc-service deploy/fraud-detection deploy/compliance-checker deploy/aml-service; do
    if kubectl -n "$NS" exec "$c" -- curl --version >/dev/null 2>&1; then
      SWEEP_POD="$c"; return 0
    fi
  done
  return 1
}

detect_sweep_mode() {
  if command -v kubectl >/dev/null 2>&1 && kubectl -n "$NS" get pods >/dev/null 2>&1 && pick_sweep_pod; then
    SWEEP_MODE=k8s
    log "sweep: in-cluster via $SWEEP_POD (ns=$NS)"
  elif curl -sf -m 3 "http://localhost:18001/health/live" >/dev/null 2>&1; then
    SWEEP_MODE=compose
    log "sweep: docker-compose mode, services on localhost:1<port>"
  else
    SWEEP_MODE=off
    log "sweep: DISABLED — no reachable cluster or compose stack (portal journeys only)"
  fi
}

# Build one shell command with every request, so the whole sweep costs a single
# `kubectl exec` instead of 59 of them.
sweep_batch_cmd() {
  local host_tmpl="$1" name port method upath body url
  while IFS='|' read -r name port method upath body; do
    [ -z "${name:-}" ] && continue
    url=$(printf "$host_tmpl" "$name" "$port")"$upath"
    if [ "$method" = "POST" ]; then
      printf "curl -s -o /dev/null -m 5 -X POST '%s' -H 'Content-Type: application/json' -d '%s';" "$url" "$body"
    else
      printf "curl -s -o /dev/null -m 5 '%s';" "$url"
    fi
  done <<< "$(printf '%s\n' "$SERVICES" | sed '/^[[:space:]]*$/d')"
}

sweep() {
  [ -z "$SWEEP_MODE" ] && detect_sweep_mode
  case "$SWEEP_MODE" in
    k8s)
      kubectl -n "$NS" exec "$SWEEP_POD" -- sh -c "$(sweep_batch_cmd 'http://%s:%s')" >/dev/null 2>&1 ;;
    compose)
      # host ports are 1<container port>: 8001 -> 18001
      sh -c "$(sweep_batch_cmd 'http://localhost:1%.0s%s')" >/dev/null 2>&1 ;;
    *) : ;;
  esac
}

# ── main loop ──────────────────────────────────────────────────────────────
log "waiting for portal $PORTAL/ ..."
until curl -sf -m 5 "$PORTAL/" >/dev/null 2>&1; do sleep 10; done
log "portal up — starting (interval=${INTERVAL}s, fail=${FAIL_PCT}%, sweep every ${SWEEP_EVERY} cycles)"
login

i=0
while true; do
  i=$(( i + 1 ))
  # refresh the session + emit a heartbeat every ~120 journeys
  [ $(( i % 120 )) -eq 0 ] && { login; log "heartbeat: ${i} journeys run"; }

  if [ $(( RANDOM % 100 )) -lt "$FAIL_PCT" ]; then
    j_fail
  else
    "${JOURNEYS[$(( RANDOM % ${#JOURNEYS[@]} ))]}"
  fi

  # keep every service reporting, not just the ones the portal fronts
  if [ "$SWEEP_EVERY" -gt 0 ] && [ $(( i % SWEEP_EVERY )) -eq 0 ]; then
    sweep
  fi

  sleep "$INTERVAL"
done
