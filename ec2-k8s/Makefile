# ──────────────────────────────────────────────────────────────────────────────
#  BankObserve360 — kind-on-EC2 deployment
#  Run from the ec2-k8s/ directory on the EC2 host. `make help` lists targets.
# ──────────────────────────────────────────────────────────────────────────────

SHELL          := /bin/bash
.DEFAULT_GOAL  := help

NS             := bankobs
CLUSTER        := bankobs
ROOT           := ..
HELM_DIR       := $(ROOT)/helm/bankobserve360
RELEASE        := bankobs
KCTL           := kubectl -n $(NS)

# Host hardware identifiers — the license binds to the EC2 machine, so these
# are computed on the host and passed into the in-cluster license-checker.
# Same derivation as the root Makefile.
HOST_MACHINE_ID := $(shell if [ -f /etc/machine-id ]; then cat /etc/machine-id; else echo unknown; fi)
HOST_MAC        := $(shell ip -o link show 2>/dev/null | awk -F'link/ether ' 'NR==2{print $$2}' | awk '{print $$1}')
HOST_HOSTNAME   := $(shell hostname)
LICENSE_KEY     := $(shell grep '^LICENSE_KEY=' $(ROOT)/.env 2>/dev/null | cut -d= -f2-)

.PHONY: help prep fingerprint cluster-up deploy wait-infra status health smoke urls \
        obs-on obs-off seed-verify logs-svc restart-svc fix-cassandra \
        shell-oracle shell-pg shell-mongo shell-redis shell-cassandra shell-kafka \
        down nuke

help:                ## Show this help
	@grep -E '^[a-zA-Z0-9_-]+:.*##' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

# ──────────────────────────────────────────────────────────────────────────────
#  HOST PREP + CLUSTER
# ──────────────────────────────────────────────────────────────────────────────

prep:                ## Host prep: prereq checks + sysctls (run once, needs sudo)
	@command -v docker  >/dev/null || { echo "✗ docker missing  — run scripts/install-tools.sh"; exit 1; }
	@command -v kind    >/dev/null || { echo "✗ kind missing    — run scripts/install-tools.sh"; exit 1; }
	@command -v kubectl >/dev/null || { echo "✗ kubectl missing — run scripts/install-tools.sh"; exit 1; }
	@command -v helm    >/dev/null || { echo "✗ helm missing    — run scripts/install-tools.sh"; exit 1; }
	@command -v jq      >/dev/null || { echo "✗ jq missing      — run scripts/install-tools.sh"; exit 1; }
	@docker info >/dev/null 2>&1 || { echo "✗ docker not usable by this user (newgrp docker / re-login)"; exit 1; }
	@CUR=$$(sysctl -n vm.max_map_count 2>/dev/null || echo 0); \
	  if [ "$$CUR" -lt 262144 ]; then \
	    echo "→ raising vm.max_map_count to 262144 (Elasticsearch requirement)"; \
	    sudo sysctl -w vm.max_map_count=262144; \
	    echo "vm.max_map_count=262144" | sudo tee /etc/sysctl.d/99-bankobs.conf >/dev/null; \
	  else echo "✓ vm.max_map_count=$$CUR"; fi
	@CUR=$$(sysctl -n fs.inotify.max_user_watches 2>/dev/null || echo 0); \
	  if [ "$$CUR" -lt 1048576 ]; then \
	    echo "→ raising inotify limits (kind + ~90 pods on one node needs them)"; \
	    sudo sysctl -w fs.inotify.max_user_watches=1048576 fs.inotify.max_user_instances=8192; \
	    printf "fs.inotify.max_user_watches=1048576\nfs.inotify.max_user_instances=8192\n" | \
	      sudo tee /etc/sysctl.d/99-bankobs-inotify.conf >/dev/null; \
	  else echo "✓ inotify limits ok"; fi
	@FREE=$$(df -BG --output=avail . 2>/dev/null | tail -1 | tr -dc 0-9 || echo 999); \
	  [ "$$FREE" -ge 80 ] 2>/dev/null && echo "✓ disk: $${FREE}G free" || \
	  echo "⚠ less than 80G free — images are pulled into BOTH docker and the kind node (~2×)"
	@echo "✓ host ready. Next: make fingerprint (license), then make cluster-up"

fingerprint:         ## Print THIS EC2 machine's license fingerprint (runs at repo root)
	@$(MAKE) -C $(ROOT) fingerprint

cluster-up:          ## Create the kind cluster (idempotent)
	@kind get clusters 2>/dev/null | grep -qx $(CLUSTER) && \
	  echo "✓ kind cluster '$(CLUSTER)' already exists" || \
	  kind create cluster --config kind-config.yaml
	@kubectl cluster-info --context kind-$(CLUSTER) | head -2
	@kubectl get nodes

# ──────────────────────────────────────────────────────────────────────────────
#  DEPLOY
# ──────────────────────────────────────────────────────────────────────────────

deploy: _check-license  ## Deploy the platform: infra manifests + Helm chart + env wiring
	@echo "🏗  [1/6] namespace + config/init ConfigMaps + license Secret"
	@kubectl create namespace $(NS) --dry-run=client -o yaml | kubectl apply -f -
	@$(KCTL) create configmap oracle-init            --from-file=$(ROOT)/infrastructure/databases/oracle/init-scripts        --dry-run=client -o yaml | kubectl apply -f -
	@$(KCTL) create configmap postgres-init          --from-file=$(ROOT)/infrastructure/databases/postgres/init-scripts      --dry-run=client -o yaml | kubectl apply -f -
	@$(KCTL) create configmap mongo-init             --from-file=$(ROOT)/infrastructure/databases/mongodb/init-scripts       --dry-run=client -o yaml | kubectl apply -f -
	@$(KCTL) create configmap cassandra-init-scripts --from-file=$(ROOT)/infrastructure/databases/cassandra/init-scripts     --dry-run=client -o yaml | kubectl apply -f -
	@$(KCTL) create configmap es-init-scripts        --from-file=$(ROOT)/infrastructure/databases/elasticsearch/init-scripts --dry-run=client -o yaml | kubectl apply -f -
	@$(KCTL) create configmap kafka-init-scripts     --from-file=$(ROOT)/infrastructure/messaging/kafka                      --dry-run=client -o yaml | kubectl apply -f -
	@$(KCTL) create configmap rabbitmq-definitions   --from-file=$(ROOT)/infrastructure/messaging/rabbitmq/definitions.json  --dry-run=client -o yaml | kubectl apply -f -
	@$(KCTL) create configmap redis-conf             --from-file=$(ROOT)/infrastructure/databases/redis/redis.conf           --dry-run=client -o yaml | kubectl apply -f -
	@$(KCTL) create secret generic bankobs-license \
	  --from-literal=LICENSE_KEY='$(LICENSE_KEY)' \
	  --from-literal=HOST_MACHINE_ID='$(HOST_MACHINE_ID)' \
	  --from-literal=HOST_MAC='$(HOST_MAC)' \
	  --from-literal=HOST_HOSTNAME='$(HOST_HOSTNAME)' \
	  --dry-run=client -o yaml | kubectl apply -f -
	@echo ""
	@echo "🗄  [2/6] infrastructure (databases, Kafka, RabbitMQ, license-checker, portal)"
	@$(KCTL) delete job -l part-of=bankobs-init --ignore-not-found >/dev/null
	@kubectl apply -f manifests/platform/
	@echo ""
	@echo "🔑 [3/6] waiting for license-checker (app services refuse to start without it)"
	@$(KCTL) rollout status deployment/license-checker --timeout=10m
	@echo ""
	@echo "⛵ [4/6] Helm — the 65 application services (public images, no build)"
	@helm dependency build $(HELM_DIR) >/dev/null 2>&1 || true
	@helm upgrade --install $(RELEASE) $(HELM_DIR) -n $(NS) \
	  -f $(HELM_DIR)/values.yaml -f values-kind.yaml --timeout 20m
	@echo ""
	@echo "🔌 [5/6] wiring compose-equivalent environment into every app service"
	@# kubectl can't combine --from=configmap with a label selector, so enumerate:
	@$(KCTL) get deploy -l domain -o name | \
	  xargs -I{} $(KCTL) set env {} --from=configmap/bankobs-env >/dev/null
	@echo "✓ env injected (deployments roll once with the DB/Kafka/license settings)"
	@$(KCTL) get svc loadrunner -o jsonpath='{.spec.ports[*].port}' 2>/dev/null | grep -q 9090 || \
	  $(KCTL) patch svc loadrunner --type=json \
	    -p='[{"op":"add","path":"/spec/ports/-","value":{"name":"metrics","port":9090,"targetPort":9090}}]' 2>/dev/null || true
	@echo ""
	@echo "🩺 [6/6] first-run image pulls take 15–40 min; Oracle & Cassandra are slow starters."
	@echo "   Watch with:  make status        Wait for data stores:  make wait-infra"
	@echo "   Then:        make smoke  ·  make urls  ·  (Week 1) make obs-on"

_check-license:
	@[ -n "$(LICENSE_KEY)" ] || { \
	  echo "✗ LICENSE_KEY is empty. On THIS EC2 host:"; \
	  echo "    1. cd $(ROOT) && cp .env.example .env   (if not done)"; \
	  echo "    2. make fingerprint   → send to trainer"; \
	  echo "    3. paste the JWT into $(ROOT)/.env as LICENSE_KEY=..."; exit 1; }

wait-infra:          ## Block until all data stores are Ready (Oracle can take ~10 min)
	@for s in postgres mongodb redis rabbitmq kafka elasticsearch cassandra oracle; do \
	  echo "→ waiting for $$s"; \
	  $(KCTL) rollout status statefulset/$$s --timeout=20m || exit 1; \
	done
	@echo "→ waiting for init jobs (Kafka topics, Cassandra keyspace, ES indices)"
	@$(KCTL) wait --for=condition=complete job -l part-of=bankobs-init --timeout=15m
	@echo "✓ all data stores ready and seeded"

# ──────────────────────────────────────────────────────────────────────────────
#  OBSERVABILITY (Week 1 — the `make obs-up` equivalent)
# ──────────────────────────────────────────────────────────────────────────────

obs-on:              ## Deploy Grafana/Prometheus/Loki/Jaeger/OTel/Alertmanager/Fluent Bit + switch app telemetry ON
	@$(KCTL) create configmap otel-collector-config    --from-file=$(ROOT)/config/otel/otel-collector-config.yaml      --dry-run=client -o yaml | kubectl apply -f -
	@$(KCTL) create configmap prometheus-config        --from-file=$(ROOT)/config/prometheus/prometheus.yml            --dry-run=client -o yaml | kubectl apply -f -
	@$(KCTL) create configmap prometheus-alerts        --from-file=$(ROOT)/config/prometheus/alerts                    --dry-run=client -o yaml | kubectl apply -f -
	@$(KCTL) create configmap loki-config              --from-file=$(ROOT)/config/loki/loki-config.yaml                --dry-run=client -o yaml | kubectl apply -f -
	@$(KCTL) create configmap alertmanager-config      --from-file=$(ROOT)/config/alertmanager/alertmanager.yml        --dry-run=client -o yaml | kubectl apply -f -
	@$(KCTL) create configmap grafana-datasources      --from-file=$(ROOT)/config/grafana/provisioning/datasources     --dry-run=client -o yaml | kubectl apply -f -
	@$(KCTL) create configmap grafana-dashboard-provider --from-file=$(ROOT)/config/grafana/provisioning/dashboards    --dry-run=client -o yaml | kubectl apply -f -
	@$(KCTL) create configmap grafana-dashboards       --from-file=$(ROOT)/config/grafana/dashboards                   --dry-run=client -o yaml | kubectl apply -f -
	@$(KCTL) create configmap fluent-bit-lua \
	  --from-file=$(ROOT)/config/fluent-bit/pii-mask.lua \
	  --from-file=$(ROOT)/config/fluent-bit/parsers.conf --dry-run=client -o yaml | kubectl apply -f -
	@kubectl apply -f manifests/observability/
	@echo "→ switching application telemetry ON (all app deployments roll)"
	@$(KCTL) set env deployment -l domain \
	  OBSERVABILITY_MODE=full OTEL_SDK_DISABLED=false MANAGEMENT_TRACING_ENABLED=true \
	  MANAGEMENT_OTLP_METRICS_EXPORT_ENABLED=true LOGGING_LEVEL_IO_OPENTELEMETRY=INFO >/dev/null
	@echo ""
	@echo "  📊  Grafana    : http://<ec2-ip>:13000   (admin / admin)"
	@echo "  🔍  Jaeger     : http://<ec2-ip>:16686"
	@echo "  📈  Prometheus : http://<ec2-ip>:9090"

obs-off:             ## Switch application telemetry back to dark (obs stack keeps running)
	@$(KCTL) set env deployment -l domain \
	  OBSERVABILITY_MODE=dark OTEL_SDK_DISABLED=true MANAGEMENT_TRACING_ENABLED=false \
	  MANAGEMENT_OTLP_METRICS_EXPORT_ENABLED=false LOGGING_LEVEL_IO_OPENTELEMETRY=OFF >/dev/null
	@echo "✓ telemetry dark"

# ──────────────────────────────────────────────────────────────────────────────
#  DAILY OPS
# ──────────────────────────────────────────────────────────────────────────────

status:              ## Pod health summary (like eks-status)
	@$(KCTL) get pods --no-headers | awk '{print $$3}' | sort | uniq -c
	@echo "──"
	@$(KCTL) get pods --no-headers | grep -vE 'Running|Completed' | head -20 || true

health:              ## Probe critical service /health endpoints in-cluster
	@for s in gateway-service:8000 auth-service:8080 account-service:8001 upi-service:8011 loan-origination:8021; do \
	  n=$${s%%:*}; p=$${s##*:}; \
	  code=$$($(KCTL) exec deploy/web-portal -- wget -q -O- -T 5 http://$$n:$$p/health/ready >/dev/null 2>&1 && echo OK || echo FAIL); \
	  printf "  %-22s %s\n" "$$n" "$$code"; \
	done

smoke:               ## Probe the portal (host :80) and the gateway end-to-end
	@echo "→ portal via host port 80"
	@curl -s -o /dev/null -m 10 -w "  http %{http_code}\n" http://localhost/ || echo "  ✗ portal not reachable"
	@echo "→ gateway in-cluster"
	@$(KCTL) run smoke-$$RANDOM --rm -i --restart=Never --image=curlimages/curl:8.5.0 -- \
	  -s -m 10 -o /dev/null -w "  http %{http_code}\n" http://gateway-service:8000/health/ready

urls:                ## Print every UI and where to find it
	@IP=$$(curl -s -m 2 http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || echo "<ec2-ip>"); \
	echo "  🏦  Portal     : http://$$IP/            (CUST-00000001 / Training@123)"; \
	echo "  📊  Grafana    : http://$$IP:13000       (admin / admin — after make obs-on)"; \
	echo "  🔍  Jaeger     : http://$$IP:16686       (after make obs-on)"; \
	echo "  📈  Prometheus : http://$$IP:9090        (after make obs-on)"; \
	echo "  ── anything else: kubectl -n $(NS) port-forward svc/<name> <port>:<port>"

seed-verify:         ## Check the seeds landed (Oracle rows, Cassandra keyspace, Kafka topics)
	@echo "→ Oracle accounts"
	@$(KCTL) exec oracle-0 -- bash -c \
	  "echo 'SELECT COUNT(*) FROM accounts;' | sqlplus -s BANKOBS_CORE/Training123!@localhost/XEPDB1" | grep -E '^[ ]*[0-9]+' || echo "  ✗ no rows"
	@echo "→ Cassandra keyspace"
	@$(KCTL) exec cassandra-0 -- cqlsh -e 'describe keyspaces' | tr ' ' '\n' | grep -x bankobs_payments || echo "  ✗ keyspace missing"
	@echo "→ Kafka topics"
	@$(KCTL) exec kafka-0 -- /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --list | head -20

logs-svc:            ## Tail one service:  make logs-svc S=upi-service
	@[ -n "$(S)" ] || { echo "usage: make logs-svc S=<service>"; exit 1; }
	@$(KCTL) logs -f deploy/$(S) --tail=100

restart-svc:         ## Restart one service:  make restart-svc S=upi-service
	@[ -n "$(S)" ] || { echo "usage: make restart-svc S=<service>"; exit 1; }
	@$(KCTL) rollout restart deploy/$(S)

fix-cassandra:       ## Wipe corrupted Cassandra commit-log and restart (known recovery)
	@$(KCTL) exec cassandra-0 -- bash -c 'rm -rf /var/lib/cassandra/commitlog/*' || true
	@$(KCTL) delete pod cassandra-0
	@echo "→ Cassandra restarting; when Ready, re-run the seed:"
	@echo "    kubectl -n $(NS) delete job cassandra-init --ignore-not-found && kubectl apply -f manifests/platform/50-init-jobs.yaml"

shell-oracle:        ## SQL*Plus on Oracle XE
	@$(KCTL) exec -it oracle-0 -- sqlplus BANKOBS_CORE/Training123!@localhost/XEPDB1
shell-pg:            ## psql (DB=bankobs_retail by default; override with DB=)
	@$(KCTL) exec -it postgres-0 -- psql -U bankobs -d $(if $(DB),$(DB),bankobs_retail)
shell-mongo:         ## mongosh
	@$(KCTL) exec -it mongodb-0 -- mongosh -u bankobs -p Training123!
shell-redis:         ## redis-cli
	@$(KCTL) exec -it redis-0 -- redis-cli
shell-cassandra:     ## cqlsh
	@$(KCTL) exec -it cassandra-0 -- cqlsh
shell-kafka:         ## List Kafka topics
	@$(KCTL) exec kafka-0 -- /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --list

# ──────────────────────────────────────────────────────────────────────────────
#  TEARDOWN
# ──────────────────────────────────────────────────────────────────────────────

down:                ## Delete the ENTIRE kind cluster (all data gone; images stay in docker)
	@kind delete cluster --name $(CLUSTER)

nuke: down           ## down + prune the pulled images (frees ~40G of disk)
	@docker system prune -af --volumes
