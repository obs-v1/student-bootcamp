# ──────────────────────────────────────────────────────────────────────────────
#  BankObserve360 — Makefile
#  All routine ops, debugging, and smoke tests in one place. Run `make help`.
# ──────────────────────────────────────────────────────────────────────────────

SHELL          := /bin/bash
.DEFAULT_GOAL  := help

COMPOSE        := docker compose
COMPOSE_FILES  := -f docker-compose.yml

# Host hardware identifiers used by the license check. Computed once per
# make invocation and exported so the license-checker container sees them.
# On macOS we use IOPlatformUUID; on Linux /etc/machine-id; on Windows WMIC.
HOST_MACHINE_ID := $(shell \
  if [ -f /etc/machine-id ]; then cat /etc/machine-id; \
  elif command -v ioreg >/dev/null 2>&1; then ioreg -rd1 -c IOPlatformExpertDevice 2>/dev/null | awk -F'"' '/IOPlatformUUID/{print $$4}'; \
  elif command -v wmic >/dev/null 2>&1; then wmic csproduct get UUID | awk 'NR==2{print $$1}'; \
  else echo unknown; fi)
HOST_MAC        := $(shell \
  if command -v ifconfig >/dev/null 2>&1; then ifconfig en0 2>/dev/null | awk '/ether/{print $$2}'; \
  elif command -v ip >/dev/null 2>&1; then ip -o link show 2>/dev/null | awk -F'link/ether ' 'NR==2{print $$2}' | awk '{print $$1}'; \
  fi)
HOST_HOSTNAME   := $(shell hostname)
export HOST_MACHINE_ID HOST_MAC HOST_HOSTNAME

# Endpoints
PORTAL         := http://localhost
GRAFANA        := http://localhost:13000
JAEGER         := http://localhost:16686
PROM           := http://localhost:9090
LOKI           := http://localhost:3100
GATEWAY        := http://localhost:18000
AUTH_API       := http://localhost:18080
KYC_API        := http://localhost:18030
UPI_API        := http://localhost:18011
LOAN_API       := http://localhost:18021

# Default training credentials
CUST           := CUST-00000001
PASS           := Training@123
COOKIE         := /tmp/bankobs-cookies.txt

# Service groups
JAVA_SVCS      := account-service ledger-service balance-service statement-service \
                  branch-service cheque-service interest-engine cbs-adapter \
                  loan-service loan-origination fd-service rd-service credit-card-service \
                  ckyc-service rules-engine case-management audit-service rbi-reporter \
                  cersai-adapter neft-service imps-service nach-service rtgs-service \
                  auth-service

GO_SVCS        := gateway-service rate-limiter payment-gateway upi-service payment-router \
                  identity-vault sanctions-service transaction-monitor velocity-checker \
                  pci-logger ibm-mq-bridge

PY_SVCS        := bharat-qr-service fx-service eligibility-engine insurance-service \
                  demat-service kyc-service aadhaar-adapter pan-adapter \
                  fraud-detection aml-service risk-scoring email-service \
                  compliance-checker report-generator

NODE_SVCS      := remittance-service onboarding-service consent-service wealth-service \
                  notification-orchestrator sms-gateway push-service whatsapp-service

ALL_APP_SVCS   := $(JAVA_SVCS) $(GO_SVCS) $(PY_SVCS) $(NODE_SVCS)

# ──────────────────────────────────────────────────────────────────────────────
#  LIFECYCLE
# ──────────────────────────────────────────────────────────────────────────────

.PHONY: up down restart reset stop nuke fix-cassandra

up:                  ## Bring up the FULL stack (infra + observability + services + portal)
	@$(MAKE) -s _check-license
	@echo "🔐 Starting license-checker…"
	@$(COMPOSE) $(COMPOSE_FILES) up -d license-checker 2>&1 | tail -3 || true
	@$(MAKE) -s _wait-license
	@echo "🚀 Starting infra + application services…"
	@$(COMPOSE) $(COMPOSE_FILES) up -d \
	  oracle postgres mongodb redis cassandra elasticsearch kafka rabbitmq transit-gateway-proxy \
	  $(ALL_APP_SVCS) 2>&1 | grep -vE 'Running|Recreate|Recreated' | tail -25 || true
	@echo "🌐 Starting web portal…"
	@$(COMPOSE) $(COMPOSE_FILES) up -d --no-deps web-portal 2>&1 | tail -3 || true
	@$(MAKE) -s _wait-cassandra
	@$(MAKE) -s _wait-portal
	@echo ""
	@echo "✓ Stack is up. Run 'make status' to verify or 'make smoke' to test."
	@$(MAKE) -s urls

_check-license:
	@if [ -z "$$LICENSE_KEY" ] && [ -f .env ]; then \
	  set -a; . ./.env; set +a; \
	fi; \
	if [ -z "$$LICENSE_KEY" ]; then \
	  echo ""; \
	  echo "  ✗ LICENSE_KEY is not set."; \
	  echo ""; \
	  echo "  This is a licensed product. To obtain a license:"; \
	  echo "    1. make fingerprint                     # prints YOUR machine's fingerprint"; \
	  echo "    2. email that fingerprint to the trainer"; \
	  echo "    3. paste the JWT you receive into .env:  LICENSE_KEY=eyJhbGc..."; \
	  echo ""; \
	  exit 1; \
	fi

_wait-license:
	@for i in 1 2 3 4 5 6 7 8 9 10; do \
	  state=$$(docker inspect --format='{{.State.Status}}' bankobs-license-checker 2>/dev/null); \
	  if [ "$$state" = "running" ]; then \
	    sleep 1; \
	    echo "  ✓ license OK"; exit 0; \
	  elif [ "$$state" = "exited" ]; then \
	    echo ""; \
	    echo "  ✗ License check FAILED. Container exited. Last 10 log lines:"; \
	    docker logs --tail 10 bankobs-license-checker 2>&1 | sed 's/^/    /'; \
	    echo ""; \
	    exit 1; \
	  fi; \
	  sleep 1; \
	done; \
	echo "  ⚠️  license-checker did not become ready in time"; exit 1

# After a Docker Desktop restart on macOS the host port-forwarder can stall
# even though containers are up. If the portal isn't reachable from the host
# within ~30s, bounce the key user-facing containers to re-bind ports.
_wait-portal:
	@for i in 1 2 3 4 5 6; do \
	  curl -sf -m 2 http://localhost:8200/ >/dev/null && exit 0; \
	  sleep 5; \
	done; \
	echo "  Portal not reachable from host yet — restarting key containers to re-bind ports…"; \
	docker restart bankobs-web-portal bankobs-auth-service bankobs-gateway-service \
	               bankobs-grafana bankobs-jaeger bankobs-prometheus >/dev/null 2>&1; \
	for i in 1 2 3 4 5 6 7 8; do \
	  curl -sf -m 2 http://localhost:8200/ >/dev/null && { echo "  ✓ portal back"; exit 0; }; \
	  sleep 5; \
	done; \
	echo "  ⚠️  portal still not reachable — run 'make health' to diagnose"

# Oracle XE cold-starts in 2-10 min (slower on EC2 gp3); seeding before it is
# ready fails SILENTLY (sqlplus exits 0 on connect errors) — hence a real probe.
_wait-oracle:
	@for i in $$(seq 1 120); do \
	  state=$$(docker inspect --format='{{.State.Health.Status}}' bankobs-oracle 2>/dev/null || echo missing); \
	  if [ "$$state" = "healthy" ]; then \
	    docker exec bankobs-oracle bash -c 'echo "SELECT 1 FROM dual;" | sqlplus -s "sys/Training123!@//localhost:1521/XEPDB1" as sysdba' 2>/dev/null \
	      | grep -qE '^[[:space:]]*1$$' && { echo "✓ Oracle ready"; exit 0; }; \
	  fi; \
	  printf "  Oracle: %s (try %d/120)…\r" "$$state" "$$i"; sleep 5; \
	done; \
	echo ""; echo "✗ Oracle not ready after 10 min — check: docker logs bankobs-oracle"; exit 1

_wait-postgres:
	@for i in $$(seq 1 36); do \
	  docker exec bankobs-postgres pg_isready -U bankobs >/dev/null 2>&1 && { echo "✓ Postgres ready"; exit 0; }; \
	  printf "  Postgres: waiting (try %d/36)…\r" "$$i"; sleep 5; \
	done; \
	echo ""; echo "✗ Postgres not ready — check: docker logs bankobs-postgres"; exit 1

_wait-kafka:
	@for i in $$(seq 1 36); do \
	  state=$$(docker inspect --format='{{.State.Health.Status}}' bankobs-kafka 2>/dev/null || echo missing); \
	  [ "$$state" = "healthy" ] && { echo "✓ Kafka healthy"; exit 0; }; \
	  printf "  Kafka: %s (try %d/36)…\r" "$$state" "$$i"; sleep 5; \
	done; \
	echo ""; echo "✗ Kafka not healthy — check: docker logs bankobs-kafka"; exit 1

# Cassandra often takes 40-60s to become healthy; tolerate that without failing.
_wait-cassandra:
	@for i in $$(seq 1 36); do \
	  state=$$(docker inspect --format='{{.State.Health.Status}}' bankobs-cassandra 2>/dev/null || echo missing); \
	  case "$$state" in \
	    healthy) echo "✓ Cassandra healthy"; exit 0;; \
	    starting|unhealthy) printf "  Cassandra: %s (try %d/36)…\r" "$$state" "$$i"; sleep 5;; \
	    *) echo "✗ Cassandra not running (status=$$state). Try: make fix-cassandra"; exit 0;; \
	  esac; \
	done; \
	echo ""; echo "⚠️  Cassandra still not healthy. Try: make fix-cassandra"

fix-cassandra:       ## Wipe corrupted Cassandra commit-log and restart (known recovery)
	@echo "→ Stopping and removing Cassandra…"
	@docker stop bankobs-cassandra 2>/dev/null || true
	@docker rm   bankobs-cassandra 2>/dev/null || true
	@echo "→ Wiping the data volume…"
	@docker volume rm bankobserve360_cassandra-data 2>/dev/null || true
	@echo "→ Restarting…"
	@$(COMPOSE) $(COMPOSE_FILES) up -d --no-deps cassandra
	@$(MAKE) -s _wait-cassandra
	@$(MAKE) -s seed-cassandra

down:                ## Stop everything (keep volumes)
	@$(COMPOSE) $(COMPOSE_FILES) down

stop: down           ## Alias for `down`

restart:             ## Restart everything (preserves volumes)
	@$(MAKE) down
	@$(MAKE) up

reset:               ## Full reset — destroys all volumes and data (with confirmation)
	@printf "⚠️  This will DESTROY all volumes and data. Continue? [y/N] "; \
	  read ans; [ "$$ans" = "y" ] || { echo "aborted"; exit 1; }
	@$(COMPOSE) $(COMPOSE_FILES) down -v
	@$(MAKE) up
	@echo "⏳ Waiting 60s for services to settle…"
	@sleep 60
	@$(MAKE) seed

nuke:                ## Same as `reset` but skips the prompt (DANGEROUS)
	@$(COMPOSE) $(COMPOSE_FILES) down -v
	@$(MAKE) up
	@sleep 60
	@$(MAKE) seed

# ──────────────────────────────────────────────────────────────────────────────
#  TIERED BRING-UP (when you only want part of the stack)
# ──────────────────────────────────────────────────────────────────────────────

# ──────────────────────────────────────────────────────────────────────────────
#  BUILD
# ──────────────────────────────────────────────────────────────────────────────

# ──────────────────────────────────────────────────────────────────────────────
#  RESTART INDIVIDUAL SERVICES
# ──────────────────────────────────────────────────────────────────────────────

.PHONY: restart-portal restart-upi restart-loan restart-account restart-ledger restart-svc

restart-portal:      ## Restart the web portal
	@$(COMPOSE) $(COMPOSE_FILES) up -d --force-recreate --no-deps web-portal

restart-upi:         ## Restart upi-service
	@$(COMPOSE) $(COMPOSE_FILES) up -d --force-recreate --no-deps upi-service

restart-loan:        ## Restart loan-origination
	@$(COMPOSE) $(COMPOSE_FILES) up -d --force-recreate --no-deps loan-origination

restart-account:     ## Restart account-service
	@$(COMPOSE) $(COMPOSE_FILES) up -d --force-recreate --no-deps account-service

restart-ledger:      ## Restart ledger-service
	@$(COMPOSE) $(COMPOSE_FILES) up -d --force-recreate --no-deps ledger-service

restart-svc:         ## Restart a single service:  make restart-svc S=upi-service
	@[ -n "$(S)" ] || { echo "usage: make restart-svc S=<service-name>"; exit 1; }
	@$(COMPOSE) $(COMPOSE_FILES) up -d --force-recreate --no-deps $(S)

# ──────────────────────────────────────────────────────────────────────────────
#  STATUS / HEALTH
# ──────────────────────────────────────────────────────────────────────────────

.PHONY: status ps health smoke urls

status:              ## Show count of healthy/unhealthy containers
	@docker ps --filter "name=bankobs-" --format '{{.Status}}' | awk ' \
	  /Up.*healthy/{h++} /Up.*unhealthy/{u++} /Up [^(]/{s++} /Exit/{e++} \
	  END{print "  healthy:        "h+0"\n  no-healthcheck: "s+0"\n  unhealthy*:     "u+0"\n  exited:         "e+0"\n  total:          "h+s+u+e}'
	@echo "  (* often scratch images without wget — endpoints respond fine)"

ps:                  ## List all bankobs containers with status
	@docker ps --filter "name=bankobs-" --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' | sed 's/0\.0\.0\.0://g'

health:              ## Probe critical /health endpoints
	@printf "  %-40s %s\n" "URL" "Status"
	@printf "  %-40s %s\n" "───────────────────────────────────────" "──────"
	@for url in \
	  $(PORTAL)/ \
	  $(GATEWAY)/health/live \
	  $(AUTH_API)/health/live \
	  http://localhost:18001/health/live \
	  http://localhost:18002/health/live \
	  $(UPI_API)/health/live \
	  $(KYC_API)/health/live \
	  $(LOAN_API)/health/live \
	  $(GRAFANA)/api/health \
	  $(JAEGER)/ \
	  $(PROM)/-/healthy \
	  $(LOKI)/ready ; do \
	  code=$$(curl -s -o /dev/null -m 3 -w '%{http_code}' "$$url"); \
	  printf "  %-40s %s\n" "$$url" "$$code"; \
	done

smoke:               ## End-to-end smoke (login → balance → UPI pay → loan apply)
	@$(MAKE) -s _login
	@echo "→ balance"
	@curl -s -m 5 -b $(COOKIE) $(PORTAL)/api/balance/ACC000000000001 | jq -c '{balance, cacheHit, traceId}'
	@echo "→ UPI pay ₹250"
	@curl -s -m 10 -b $(COOKIE) -X POST $(PORTAL)/api/upi/pay \
	  -H 'Content-Type: application/json' \
	  -d '{"from_vpa":"cust00000001@bankobs","to_vpa":"cust00000002@bankobs","amount":250,"remarks":"smoke"}' \
	  | jq -c '{ok, paymentId, status, traceId}'
	@echo "→ loan apply ₹50k"
	@curl -s -m 30 -b $(COOKIE) -X POST $(PORTAL)/api/loans/apply \
	  -H 'Content-Type: application/json' \
	  -d '{"amount":50000,"tenure_months":12,"purpose":"PERSONAL"}' \
	  | jq -c '{ok, applicationId, status, traceId}'

urls:                ## Print all useful URLs
	@echo "  🏦  Portal    : $(PORTAL)        (login: $(CUST) / $(PASS))"
	

# ──────────────────────────────────────────────────────────────────────────────
#  LOGS
# ──────────────────────────────────────────────────────────────────────────────

.PHONY: logs logs-portal logs-upi logs-loan logs-account logs-ledger logs-otel logs-svc logs-tail

logs:                ## Follow logs for all services
	@$(COMPOSE) $(COMPOSE_FILES) logs -f --tail=50

logs-portal:         ## Tail web portal logs
	@docker logs -f --tail=100 bankobs-web-portal

logs-upi:            ## Tail upi-service logs
	@docker logs -f --tail=100 bankobs-upi-service

logs-loan:           ## Tail loan-origination logs
	@docker logs -f --tail=100 bankobs-loan-origination

logs-account:        ## Tail account-service logs
	@docker logs -f --tail=100 bankobs-account-service

logs-ledger:         ## Tail ledger-service logs
	@docker logs -f --tail=100 bankobs-ledger-service

logs-otel:           ## Tail OTel collector logs
	@docker logs -f --tail=100 bankobs-otel

logs-svc:            ## Tail a single service:  make logs-svc S=fraud-detection
	@[ -n "$(S)" ] || { echo "usage: make logs-svc S=<service-name>"; exit 1; }
	@docker logs -f --tail=100 bankobs-$(S)

logs-tail:           ## Last 50 lines from a service (no follow):  make logs-tail S=upi-service
	@[ -n "$(S)" ] || { echo "usage: make logs-tail S=<service-name>"; exit 1; }
	@docker logs --tail=50 bankobs-$(S)

# ──────────────────────────────────────────────────────────────────────────────
#  SEEDING
# ──────────────────────────────────────────────────────────────────────────────

.PHONY: seed seed-oracle seed-postgres seed-cards seed-cassandra seed-kafka seed-verify _wait-oracle _wait-postgres _wait-kafka

seed:                ## Seed everything (Oracle + Postgres + Cassandra + Kafka topics)
	@$(MAKE) seed-oracle
	@$(MAKE) seed-postgres
	@$(MAKE) seed-cards
	@$(MAKE) seed-cassandra
	@$(MAKE) seed-kafka
	@$(MAKE) -s seed-verify
	@echo "✓ all seeds done and verified"

seed-verify:         ## Check every seed actually landed (Oracle rows, Cassandra keyspace, Kafka topics)
	@ok=1; \
	n=$$(docker exec bankobs-oracle bash -c 'echo "SELECT COUNT(*) FROM accounts;" | sqlplus -s "BANKOBS_CORE/Training123!@//localhost:1521/XEPDB1"' 2>/dev/null | grep -oE '[0-9]+' | tail -1); \
	if [ "$${n:-0}" -gt 0 ] 2>/dev/null; then echo "✓ Oracle: $$n accounts"; \
	else echo "✗ Oracle: no accounts — run: make seed-oracle"; ok=0; fi; \
	if docker exec bankobs-cassandra cqlsh -e 'DESCRIBE KEYSPACES' 2>/dev/null | grep -q bankobs_payments; \
	then echo "✓ Cassandra: keyspace bankobs_payments present"; \
	else echo "✗ Cassandra: keyspace missing — run: make seed-cassandra"; ok=0; fi; \
	if docker exec bankobs-kafka /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --list 2>/dev/null | grep -q banking.payments.upi.initiated; \
	then echo "✓ Kafka: banking topics present"; \
	else echo "✗ Kafka: topics missing — run: make seed-kafka"; ok=0; fi; \
	[ $$ok -eq 1 ] || { echo "✗ seed incomplete — run the target(s) above, then: make seed-verify"; exit 1; }

seed-kafka:          ## Create all 12 banking Kafka topics (idempotent)
	@$(MAKE) -s _wait-kafka
	@docker exec bankobs-kafka bash -c 'cd /opt/kafka/bin && \
	  for t in banking.payments.upi.initiated banking.payments.upi.completed \
	           banking.payments.neft.batch banking.payments.rtgs.initiated \
	           banking.fraud.alerts banking.fraud.velocity \
	           banking.kyc.events banking.audit.events \
	           banking.notifications.dispatch banking.cbs.events \
	           banking.compliance.events banking.loadrunner.metrics; do \
	    ./kafka-topics.sh --create --if-not-exists --topic $$t \
	      --partitions 4 --replication-factor 1 \
	      --bootstrap-server localhost:9092 2>&1 | tail -1; \
	  done'
	@echo "→ bouncing Kafka producers/consumers so they discover the topics…"
	@docker restart bankobs-account-service bankobs-ledger-service bankobs-upi-service >/dev/null
	@echo "✓ Kafka topics ready"

seed-oracle:         ## Seed Oracle XE — schema + accounts + transactions
	@$(MAKE) -s _wait-oracle
	@echo "→ copying init scripts into Oracle container…"
	@for f in 01-schema.sql 02-seed.sql 03-seed-txns.sql; do \
	  docker cp infrastructure/databases/oracle/init-scripts/$$f bankobs-oracle:/tmp/$$f; \
	done
	@echo "→ running 01-schema.sql (as SYS)…"
	@docker exec bankobs-oracle bash -c \
	  "sqlplus -s sys/Training123!@//localhost:1521/XEPDB1 as sysdba @/tmp/01-schema.sql" | tail -5
	@echo "→ running 02-seed.sql (as BANKOBS_CORE)…"
	@docker exec bankobs-oracle bash -c \
	  "sqlplus -s BANKOBS_CORE/Training123!@//localhost:1521/XEPDB1 @/tmp/02-seed.sql" | tail -3
	@echo "→ running 03-seed-txns.sql…"
	@docker exec bankobs-oracle bash -c \
	  "sqlplus -s BANKOBS_CORE/Training123!@//localhost:1521/XEPDB1 @/tmp/03-seed-txns.sql" | tail -3
	@$(MAKE) -s restart-account restart-ledger >/dev/null

seed-postgres:       ## Bump fd/rd column widths (run after a fresh reset)
	@$(MAKE) -s _wait-postgres
	@docker exec bankobs-postgres psql -U bankobs -d bankobs_retail -c \
	  "ALTER TABLE fixed_deposits     ALTER COLUMN fd_id TYPE VARCHAR(40); \
	   ALTER TABLE recurring_deposits ALTER COLUMN rd_id TYPE VARCHAR(40);" 2>&1 | tail -5

seed-cards:          ## Seed 500 credit cards
	@$(MAKE) -s _wait-postgres
	@printf "INSERT INTO credit_cards (card_id, customer_id, card_number_masked, credit_limit, current_balance, status)\nSELECT 'CC-CUST' || lpad(g::text, 3, '0') || '-0001', 'CUST-' || lpad(g::text, 8, '0'), 'XXXX XXXX XXXX ' || lpad((1000 + g)::text, 4, '0'), (CASE WHEN g %% 5 = 0 THEN 500000 WHEN g %% 3 = 0 THEN 300000 WHEN g %% 2 = 0 THEN 150000 ELSE 75000 END)::numeric, ((g %% 11) * 5000)::numeric, CASE WHEN g %% 50 = 0 THEN 'BLOCKED' ELSE 'ACTIVE' END FROM generate_series(1, 500) g ON CONFLICT (card_id) DO NOTHING;\n" > /tmp/seed-cards.sql
	@docker cp /tmp/seed-cards.sql bankobs-postgres:/tmp/seed-cards.sql
	@docker exec bankobs-postgres psql -U bankobs -d bankobs_retail -f /tmp/seed-cards.sql 2>&1 | tail -3

seed-cassandra:      ## Seed Cassandra (VPA registry + UPI history)
	@$(MAKE) -s _wait-cassandra
	@for f in 01-init.cql 02-seed.cql; do \
	  if [ -f infrastructure/databases/cassandra/init-scripts/$$f ]; then \
	    docker cp infrastructure/databases/cassandra/init-scripts/$$f bankobs-cassandra:/tmp/$$f; \
	    docker exec bankobs-cassandra cqlsh -f /tmp/$$f 2>&1 | tail -3; \
	  fi; \
	done

# ──────────────────────────────────────────────────────────────────────────────
#  DATABASE SHELLS
# ──────────────────────────────────────────────────────────────────────────────

.PHONY: shell-oracle shell-pg shell-mongo shell-redis shell-cassandra shell-kafka

shell-oracle:        ## Open SQL*Plus on Oracle XE
	@docker exec -it bankobs-oracle bash -c \
	  "sqlplus BANKOBS_CORE/Training123!@//localhost:1521/XEPDB1"

shell-pg:            ## Open psql on Postgres (DB=bankobs_retail by default; override with DB=)
	@docker exec -it bankobs-postgres psql -U bankobs -d $${DB:-bankobs_retail}

shell-mongo:         ## Open mongosh
	@docker exec -it bankobs-mongodb mongosh -u bankobs -p Training123! --authenticationDatabase admin bankobs

shell-redis:         ## Open redis-cli
	@docker exec -it bankobs-redis redis-cli

shell-cassandra:     ## Open cqlsh
	@docker exec -it bankobs-cassandra cqlsh

shell-kafka:         ## List Kafka topics
	@docker exec -it bankobs-kafka kafka-topics.sh --list --bootstrap-server localhost:9092

# ──────────────────────────────────────────────────────────────────────────────
#  OPEN URLs IN BROWSER
# ──────────────────────────────────────────────────────────────────────────────

.PHONY: open open-portal open-grafana open-jaeger open-prom open-upi-dash open-loans-dash

open: open-portal    ## Open the portal in your browser

open-portal:         ## Open the BankObserve360 portal
	@open $(PORTAL) 2>/dev/null || xdg-open $(PORTAL)

open-grafana:        ## Open Grafana
	@open $(GRAFANA) 2>/dev/null || xdg-open $(GRAFANA)

open-jaeger:         ## Open Jaeger
	@open $(JAEGER) 2>/dev/null || xdg-open $(JAEGER)

open-prom:           ## Open Prometheus
	@open $(PROM) 2>/dev/null || xdg-open $(PROM)

open-upi-dash:       ## Open the UPI Transactions dashboard
	@open "$(GRAFANA)/d/upi-transactions/upi-transactions" 2>/dev/null || \
	  xdg-open "$(GRAFANA)/d/upi-transactions/upi-transactions"

open-loans-dash:     ## Open the Loans Pipeline dashboard
	@open "$(GRAFANA)/d/loans-pipeline/loans-pipeline" 2>/dev/null || \
	  xdg-open "$(GRAFANA)/d/loans-pipeline/loans-pipeline"

# ──────────────────────────────────────────────────────────────────────────────
#  LOAD GENERATION (quick traffic, no full LoadRunner needed)
# ──────────────────────────────────────────────────────────────────────────────

.PHONY: gen-traffic gen-upi gen-loan gen-fail

gen-traffic:         ## Fire 20 mixed UPI payments + 3 loans (good for dashboards)
	@$(MAKE) -s _login
	@for amt in 250 1500 750 5000 12000 350 8000 100 25000 4500 600 900 3200 6700 1100 450 18000 750 250 2200; do \
	  curl -s -m 30 -b $(COOKIE) -X POST $(PORTAL)/api/upi/pay \
	    -H 'Content-Type: application/json' \
	    -d "{\"from_vpa\":\"cust00000001@bankobs\",\"to_vpa\":\"cust00000002@bankobs\",\"amount\":$$amt,\"remarks\":\"traffic\"}" \
	    > /dev/null; sleep 0.2; \
	done
	@for amt in 75000 150000 250000; do \
	  curl -s -m 30 -b $(COOKIE) -X POST $(PORTAL)/api/loans/apply \
	    -H 'Content-Type: application/json' \
	    -d "{\"amount\":$$amt,\"tenure_months\":24,\"purpose\":\"PERSONAL\"}" \
	    > /dev/null; sleep 0.5; \
	done
	@echo "✓ traffic generated. Open the dashboards to see it land."

gen-upi:             ## Fire one UPI payment:  make gen-upi AMT=500 TO=cust00000002@bankobs
	@$(MAKE) -s _login
	@curl -s -m 30 -b $(COOKIE) -X POST $(PORTAL)/api/upi/pay \
	  -H 'Content-Type: application/json' \
	  -d '{"from_vpa":"cust00000001@bankobs","to_vpa":"$(or $(TO),cust00000002@bankobs)","amount":$(or $(AMT),500),"remarks":"manual"}' \
	  | jq '{ok, paymentId, status, traceId}'

gen-loan:            ## Apply for one loan:  make gen-loan AMT=200000 TENURE=24
	@$(MAKE) -s _login
	@curl -s -m 30 -b $(COOKIE) -X POST $(PORTAL)/api/loans/apply \
	  -H 'Content-Type: application/json' \
	  -d '{"amount":$(or $(AMT),100000),"tenure_months":$(or $(TENURE),24),"purpose":"PERSONAL"}' \
	  | jq '{ok, applicationId, status, traceId}'

gen-fail:            ## Force a UPI debit failure (insufficient funds → red dashboard row)
	@TOKEN=$$(curl -s -m 5 -X POST $(AUTH_API)/api/v1/auth/login \
	  -H 'Content-Type: application/json' \
	  -d '{"customer_id":"$(CUST)","password":"$(PASS)"}' | jq -r .data.token); \
	  curl -s -m 30 -X POST $(UPI_API)/api/v1/upi/pay \
	    -H "Authorization: Bearer $$TOKEN" \
	    -H 'Content-Type: application/json' \
	    -d '{"from_vpa":"ghost9999@bankobs","to_vpa":"cust00000002@bankobs","amount":500,"customer_id":"$(CUST)"}' \
	    | jq '{ok: (.success // false), error: .error.code, traceId: .meta.traceId}'

# Internal: login + save cookie
_login:
	@curl -s -m 5 -c $(COOKIE) -X POST $(PORTAL)/api/auth/login \
	  -H 'Content-Type: application/json' \
	  -d '{"customer_id":"$(CUST)","password":"$(PASS)"}' > /dev/null

# ──────────────────────────────────────────────────────────────────────────────
#  TRACE INSPECTION
# ──────────────────────────────────────────────────────────────────────────────

.PHONY: trace

trace:               ## Show span tree for a trace ID:  make trace TID=<hex>
	@[ -n "$(TID)" ] || { echo "usage: make trace TID=<traceId>"; exit 1; }
	@echo "Jaeger: $(JAEGER)/trace/$(TID)"
	@echo ""
	@curl -s "$(JAEGER)/api/traces/$(TID)" | python3 -c "import json,sys; d=json.load(sys.stdin); data=d.get('data') or []; sys.exit(print('not found yet')) if not data else None; t=data[0]; procs={pid:p['serviceName'] for pid,p in t['processes'].items()}; spans=sorted(t['spans'], key=lambda s: s['startTime']); t0=spans[0]['startTime']; print(f'Services: {sorted(set(procs.values()))}'); print(f'Spans   : {len(spans)}'); print(); [print(f'  {i+1:>2}. [{procs.get(s[\"processID\"],\"?\"):<20}] {s[\"operationName\"][:55]:<55}  +{(s[\"startTime\"]-t0)/1000:>7.1f}ms  ({s[\"duration\"]/1000:.1f}ms)') for i,s in enumerate(spans)]"

# ──────────────────────────────────────────────────────────────────────────────
#  KAFKA UTILITIES
# ──────────────────────────────────────────────────────────────────────────────

.PHONY: kafka-topics kafka-consume kafka-lag

kafka-topics:        ## List all Kafka topics
	@docker exec bankobs-kafka kafka-topics.sh --list --bootstrap-server localhost:9092

kafka-consume:       ## Consume a topic from the start:  make kafka-consume T=banking.cbs.events
	@[ -n "$(T)" ] || { echo "usage: make kafka-consume T=<topic>"; exit 1; }
	@docker exec -it bankobs-kafka kafka-console-consumer.sh \
	  --bootstrap-server localhost:9092 --topic $(T) --from-beginning --max-messages 20

kafka-lag:           ## Show consumer-group lag for ledger-service
	@docker exec bankobs-kafka kafka-consumer-groups.sh \
	  --bootstrap-server localhost:9092 --describe --group ledger-service

# ──────────────────────────────────────────────────────────────────────────────
#  CLEANUP
# ──────────────────────────────────────────────────────────────────────────────

.PHONY: fingerprint license-verify license-info

# ──────────────────────────────────────────────────────────────────────────────
#  LICENSE (anti-piracy gate)
# ──────────────────────────────────────────────────────────────────────────────

fingerprint:         ## Print THIS machine's hardware fingerprint
		@docker pull -q public.ecr.aws/w8x4g9h7/obs-v1/license-checker:1.0.0 >/dev/null
	@FP=$$(docker run --rm \
	  -e HOST_MACHINE_ID="$(HOST_MACHINE_ID)" \
	  -e HOST_MAC="$(HOST_MAC)" \
	  -e HOST_HOSTNAME="$(HOST_HOSTNAME)" \
	  public.ecr.aws/w8x4g9h7/obs-v1/license-checker:1.0.0 fingerprint); \
	echo ""; \
	echo "  fingerprint: $$FP"; \
	echo ""; \
	echo "  Send the fingerprint above to your trainer; they will email back a"; \
	echo "  JWT to paste into .env as LICENSE_KEY=<jwt>"

license-verify:      ## Verify a JWT:  make license-verify JWT=eyJ...
	@[ -n "$(JWT)" ] || { echo "usage: make license-verify JWT=<token>"; exit 1; }

license-info:        ## Show this machine's current license status
	@curl -s -m 3 http://localhost:7743/validate 2>/dev/null | jq . || \
	  echo "  license-checker not reachable (stack down? run 'make up')"

.PHONY: clean clean-volumes clean-volumes-force clean-all prune

clean:               ## Stop + remove containers (preserves volumes & images)
	@$(COMPOSE) $(COMPOSE_FILES) down

clean-volumes:       ## Stop + remove containers AND all named volumes (asks first)
	@echo "Volumes that will be destroyed:"
	@docker volume ls --filter "name=bankobserve360_" --format '  - {{.Name}}' || true
	@echo ""
	@printf "⚠️  This DELETES all DB data, Kafka topics, dashboards, etc. Continue? [y/N] "; \
	  read ans; [ "$$ans" = "y" ] || { echo "aborted"; exit 1; }
	@$(COMPOSE) $(COMPOSE_FILES) down -v
	@echo "→ removing any leftover bankobserve360_* volumes…"
	@docker volume ls -q --filter "name=bankobserve360_" | xargs -r docker volume rm 2>/dev/null || true
	@echo "✓ all volumes cleaned. Run 'make up && make seed' to rebuild data."

clean-volumes-force: ## Same as clean-volumes but skips the confirmation prompt
	@$(COMPOSE) $(COMPOSE_FILES) down -v
	@docker volume ls -q --filter "name=bankobserve360_" | xargs -r docker volume rm 2>/dev/null || true
	@echo "✓ all volumes cleaned"

clean-all:           ## clean-volumes + remove the bankobserve360 images
	@$(MAKE) clean-volumes
	@docker images --filter "reference=bankobserve360-*" -q | xargs -r docker rmi -f 2>/dev/null || true
	@echo "✓ images removed too. Next 'make up' will trigger a full rebuild."

prune:               ## Reclaim disk: dangling images + build cache
	@docker image prune -f
	@docker builder prune -f

# ──────────────────────────────────────────────────────────────────────────────
#  HELP
# ──────────────────────────────────────────────────────────────────────────────

.PHONY: help

help:                ## Show this help
	@echo ""
	@echo "  BankObserve360 — Makefile"
	@echo "  ────────────────────────"
	@awk 'BEGIN {FS = ":.*?## "} \
	  /^# ──/ {gsub("# ","",$$0); gsub("─","",$$0); section=$$0; printed=0; next} \
	  /^[a-zA-Z_-]+:.*?## / { \
	    if (!printed && section!="") { printf "\n  \033[1;33m%s\033[0m\n", section; printed=1 } \
	    printf "    \033[36m%-22s\033[0m %s\n", $$1, $$2 \
	  }' $(MAKEFILE_LIST)
	@echo ""
	@echo "  Tip: service-scoped targets accept S=<service-name>"
	@echo "       e.g. make build-svc S=fraud-detection  |  make logs-svc S=upi-service"
	@echo ""

# ────────────────────────────────────────────────────────────────────
# ── Deployment paths: compose (local) vs EKS (AWS) ──
# ────────────────────────────────────────────────────────────────────

compose-up: up       ## Run the BANKING APPLICATION locally (no observability stack)

compose-down: down   ## Stop the local docker-compose platform (alias for `down`)

EKS_TF_DIR   := eks-terraform
EKS_HELM_DIR := helm/bankobserve360
EKS_REGION       ?= ap-south-1
EKS_RELEASE      ?= bankobs
# The PUBLIC registry the platform images are published to (trainer-owned).
# Anonymous pulls — students need zero registry auth, in any AWS account.
ECR_PUBLIC_ALIAS ?= w8x4g9h7
ECR_REGISTRY     ?= public.ecr.aws/$(ECR_PUBLIC_ALIAS)
ECR_PREFIX       ?= obs-v1

eks-up:              ## STUDENT: create VPC + EKS on AWS and deploy the platform (pulls published public images)
	@command -v aws >/dev/null       || { echo "✗ aws CLI required";      exit 1; }
	@command -v terraform >/dev/null || { echo "✗ terraform required";    exit 1; }
	@command -v kubectl >/dev/null   || { echo "✗ kubectl required";      exit 1; }
	@command -v helm >/dev/null      || { echo "✗ helm required";         exit 1; }
	@aws sts get-caller-identity >/dev/null 2>&1 || { echo "✗ AWS credentials not configured (aws configure / SSO)"; exit 1; }
	@echo "⚠️  This creates REAL AWS resources (EKS control plane + 3× m5.2xlarge + NAT)."
	@echo "    Rough cost while running: ≈ \$$1.5–2.0/hour. Tear down with: make eks-down"
	@echo ""
	@echo "🏗  [1/4] Terraform — VPC + EKS + node group + EBS CSI (≈ 15–20 min)"
	terraform -chdir=$(EKS_TF_DIR) init -upgrade
	terraform -chdir=$(EKS_TF_DIR) apply -var region=$(EKS_REGION) $(if $(EKS_AUTO),-auto-approve,)
	@echo ""
	@echo "🔑 [2/4] kubeconfig"
	@$$(terraform -chdir=$(EKS_TF_DIR) output -raw kubeconfig_command)
	kubectl get nodes
	@echo ""
	@echo "⛵ [3/4] Helm — deploy the umbrella chart (images pull from $(ECR_REGISTRY)/$(ECR_PREFIX) — no build needed)"
	helm dependency build $(EKS_HELM_DIR) >/dev/null 2>&1 || true
	helm upgrade --install $(EKS_RELEASE) $(EKS_HELM_DIR) \
	  -n bankobs --create-namespace \
	  -f $(EKS_HELM_DIR)/values.yaml \
	  -f $(EKS_HELM_DIR)/values-eks.yaml \
	  --set global.registry=$(ECR_REGISTRY)/$(ECR_PREFIX) \
	  --set license.key=$${LICENSE_KEY:-$$(grep '^LICENSE_KEY=' .env | cut -d= -f2-)} \
	  --timeout 20m
	@echo ""
	@echo "🩺 [4/4] Status (pods take several minutes to settle — Oracle & Cassandra are slow starters)"
	kubectl -n bankobs get pods | head -25
	@echo ""
	@echo "✓ eks-up finished. Next:  make eks-status   |   make eks-smoke   |   make eks-down"

eks-status:          ## Pod health summary on the EKS deployment
	@kubectl -n bankobs get pods --no-headers | awk '{print $$3}' | sort | uniq -c
	@echo "──"
	@kubectl -n bankobs get pods --no-headers | grep -vE 'Running|Completed' | head -15 || true

eks-smoke:           ## Port-forward the portal and probe it end-to-end
	@kubectl -n bankobs port-forward svc/web-portal 18200:8200 >/dev/null 2>&1 & \
	  PF=$$!; sleep 4; \
	  echo "→ portal /"; curl -s -o /dev/null -m 10 -w "  http %{http_code}\n" http://localhost:18200/ ; \
	  kill $$PF 2>/dev/null || true

eks-down:            ## Uninstall the platform and DESTROY all AWS resources
	-helm uninstall $(EKS_RELEASE) -n bankobs 2>/dev/null
	-kubectl delete namespace bankobs --timeout=5m 2>/dev/null
	terraform -chdir=$(EKS_TF_DIR) destroy -var region=$(EKS_REGION) $(if $(EKS_AUTO),-auto-approve,)
	@echo "✓ all AWS resources destroyed (verify in the console: EKS, EC2, NAT, ECR)"

BOOTCAMP_REPO ?= /Users/skalluru/obs-labs/student-bootcamp

publish-bootcamp:    ## TRAINER: regenerate student-bootcamp, sync to the git repo, commit & push
	./scripts/build-student-bootcamp.sh
	rsync -a --delete --exclude .git student-bootcamp/ $(BOOTCAMP_REPO)/
	cd $(BOOTCAMP_REPO) && git add -A && \
	  (git diff --cached --quiet && echo "nothing to publish" || \
	   (git commit -m "course update $$(date +%Y-%m-%d)" && git push && echo "✓ published"))

obs-up:              ## Week 1+: start the observability stack and switch app telemetry ON
	@$(COMPOSE) $(COMPOSE_FILES) -f docker-compose.observability.yml --profile observability up -d
	@echo ""
	@echo "  📊  Grafana   : http://localhost:13000   (admin / admin)"

update:              ## Pull the latest course updates (repo + images) and re-apply
	@git pull --ff-only
	@$(COMPOSE) $(COMPOSE_FILES) --profile observability pull -q
	@$(MAKE) compose-up
	@echo "✓ up to date"

obs-down:            ## Stop only the observability stack (application keeps running)
	@$(COMPOSE) $(COMPOSE_FILES) --profile observability stop otel-collector jaeger prometheus loki grafana alertmanager fluent-bit 2>/dev/null || true
	@$(COMPOSE) $(COMPOSE_FILES) up -d 2>&1 | tail -1
	@echo "✓ observability stack stopped; application telemetry back to quiet"

ec2-prep:            ## Linux/EC2 host prep: sysctls + prereq checks (run once, needs sudo)
	@command -v docker >/dev/null || { echo "✗ install docker first (and the compose plugin)"; exit 1; }
	@docker compose version >/dev/null 2>&1 || { echo "✗ docker compose v2 plugin missing"; exit 1; }
	@command -v jq >/dev/null || { echo "✗ install jq"; exit 1; }
	@CUR=$$(sysctl -n vm.max_map_count 2>/dev/null || echo 0); \
	  if [ "$$CUR" -lt 262144 ]; then \
	    echo "→ raising vm.max_map_count to 262144 (Elasticsearch requirement)"; \
	    sudo sysctl -w vm.max_map_count=262144; \
	    echo "vm.max_map_count=262144" | sudo tee /etc/sysctl.d/99-bankobs.conf >/dev/null; \
	  else echo "✓ vm.max_map_count=$$CUR"; fi
	@FREE=$$(df -BG --output=avail . 2>/dev/null | tail -1 | tr -dc 0-9 || echo 999); \
	  [ "$$FREE" -ge 60 ] 2>/dev/null && echo "✓ disk: $${FREE}G free" || echo "⚠ less than 60G free — image pulls + data need ~60G"
	@echo "✓ host ready. Next: make fingerprint"
