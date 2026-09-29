# ──────────────────────────────────────────────────────────────────────────────
#  minik8s — a bare Kubernetes lab box on EC2
#
#  Same provisioning path as the root Makefile's tf-apply, minus the banking
#  platform: this brings up a t3.large spot instance running an EMPTY kind
#  cluster. Deploy whatever you like onto it.
#
#      make tf-apply     # ~5 min: instance → tools → kind cluster
#      make kubeconfig   # drive that cluster from this machine
#      make kube-check   # prove it works
#      make tf-destroy   # give the money back
#
#  Run `make help` for everything else.
# ──────────────────────────────────────────────────────────────────────────────

SHELL          := /bin/bash
.DEFAULT_GOAL  := help

# Lazily evaluated — terraform is only shelled out to when a target uses it.
EC2_HOST        ?= $(shell terraform output -raw public_ip 2>/dev/null)
EC2_USER        ?= ec2-user
EC2_PASS        ?= DevOps321

KIND_CLUSTER    ?= minik8s
KUBECONFIG_OUT  ?= $(HOME)/.kube/minik8s-ec2.config
KUBE_API_PORT   ?= 6443
KUBE_CONTEXT    ?= minik8s-ec2

# scripts/ is shared with the parent bootcamp repo — no forked copies here.
SCRIPTS         := ../scripts

# Spot boxes recycle IPs, so don't pollute (or trip over) known_hosts.
SSH_OPTS        := -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
                   -o ConnectTimeout=10
# The instance has no key pair — terraform provisions it over SSH *password*
# auth. sshpass makes that non-interactive; without it ssh just prompts.
SSH_WRAP         = $(shell command -v sshpass >/dev/null 2>&1 && echo sshpass -p '$(EC2_PASS)')

# ──────────────────────────────────────────────────────────────────────────────
#  PROVISION
# ──────────────────────────────────────────────────────────────────────────────

.PHONY: tf-install tf-apply tf-destroy tf-plan ip _post-apply

tf-install:
	command -v terraform >/dev/null 2>&1 || sudo labauto terraform

tf-apply: tf-install  ## Create the EC2 spot box and the kind cluster on it
	terraform init
	terraform apply -auto-approve
	@$(MAKE) -s _post-apply

_post-apply:
	@echo ""
	@echo "  ✓ instance up at $$(terraform output -raw public_ip 2>/dev/null) with an empty kind cluster."
	@echo ""
	@echo "      make kubeconfig     # write a kubeconfig for it on this machine"
	@echo "      make kube-check     # kubectl get nodes, through that kubeconfig"
	@echo "      make ssh            # shell on the box"
	@echo ""

tf-plan: tf-install   ## Show what an apply would change
	terraform init -input=false
	terraform plan

tf-destroy: tf-install  ## DESTROY the instance and everything on it
	terraform init
	terraform destroy -auto-approve

ip:                  ## Print the instance's public IP
	@terraform output -raw public_ip 2>/dev/null && echo "" || \
	  { echo "  ✗ no instance — run 'make tf-apply'"; exit 1; }

# ──────────────────────────────────────────────────────────────────────────────
#  REMOTE ACCESS
# ──────────────────────────────────────────────────────────────────────────────

.PHONY: ssh kubeconfig kube-check nodes

ssh:                 ## SSH into the box (password: DevOps321)
	@HOST="$(EC2_HOST)"; \
	[ -n "$$HOST" ] || { echo "  ✗ no instance — run 'make tf-apply'"; exit 1; }; \
	$(SSH_WRAP) ssh $(SSH_OPTS) "$(EC2_USER)@$$HOST"

# kind binds the API server to 127.0.0.1:<random-port> on the instance, so it
# isn't reachable from here, and its serving cert has no SAN for the public IP.
# ../scripts/expose-kube-api.sh fixes both without touching the cluster: a socat
# unit republishes the API on :$(KUBE_API_PORT), and the kubeconfig below pins
# verification to the name "kubernetes" (already a SAN) via tls-server-name.
# TLS verification stays ON. See that script's header for the full reasoning.
kubeconfig:          ## Fetch a kubeconfig for the remote kind cluster
	@command -v ssh >/dev/null || { echo "✗ ssh not found"; exit 1; }
	@[ -f "$(SCRIPTS)/expose-kube-api.sh" ] || { echo "✗ $(SCRIPTS)/expose-kube-api.sh missing — run this from minik8s/ inside the bootcamp repo"; exit 1; }
	@command -v sshpass >/dev/null 2>&1 || \
	  echo "  note: sshpass not installed — ssh will prompt for the password ($(EC2_PASS))"
	@HOST="$(EC2_HOST)"; \
	if [ -z "$$HOST" ]; then \
	  echo "  ✗ no EC2 host found."; \
	  echo "    Run 'make tf-apply' first, or pass one explicitly:  make kubeconfig EC2_HOST=<ip>"; \
	  exit 1; \
	fi; \
	mkdir -p $(dir $(KUBECONFIG_OUT)); \
	echo "→ $(EC2_USER)@$$HOST: exposing the '$(KIND_CLUSTER)' API server and fetching its kubeconfig…"; \
	$(SSH_WRAP) ssh $(SSH_OPTS) "$(EC2_USER)@$$HOST" \
	  "PUBLIC_IP='$$HOST' CLUSTER='$(KIND_CLUSTER)' LISTEN_PORT='$(KUBE_API_PORT)' \
	   CONTEXT_NAME='$(KUBE_CONTEXT)' bash -s" \
	  < $(SCRIPTS)/expose-kube-api.sh > "$(KUBECONFIG_OUT).tmp" || true; \
	if ! grep -q 'server: https://' "$(KUBECONFIG_OUT).tmp" 2>/dev/null; then \
	  rm -f "$(KUBECONFIG_OUT).tmp"; \
	  echo "  ✗ no kubeconfig came back (see the errors above)."; \
	  echo "    ssh $(EC2_USER)@$$HOST 'kind get clusters'   # expect: $(KIND_CLUSTER)"; \
	  exit 1; \
	fi; \
	mv "$(KUBECONFIG_OUT).tmp" "$(KUBECONFIG_OUT)"; \
	chmod 600 "$(KUBECONFIG_OUT)"; \
	echo ""; \
	echo "  ✓ wrote $(KUBECONFIG_OUT)  (context: $(KUBE_CONTEXT) → $$HOST:$(KUBE_API_PORT))"; \
	echo ""; \
	echo "      export KUBECONFIG=$(KUBECONFIG_OUT)"; \
	echo "      kubectl get nodes"; \
	echo ""; \
	echo "  ⚠ the Kubernetes API is now reachable on the public internet; that file"; \
	echo "    is a cluster-admin credential — keep it (and the security group) tight."

kube-check:          ## Verify the fetched kubeconfig actually reaches the cluster
	@[ -f "$(KUBECONFIG_OUT)" ] || { echo "✗ run 'make kubeconfig' first"; exit 1; }
	@command -v kubectl >/dev/null || { echo "✗ kubectl not installed on this machine"; exit 1; }
	@echo "→ $$(sed -n 's|.*server: \(.*\)|\1|p' "$(KUBECONFIG_OUT)" | head -1)"
	@KUBECONFIG="$(KUBECONFIG_OUT)" kubectl get nodes && \
	 KUBECONFIG="$(KUBECONFIG_OUT)" kubectl get pods -A --no-headers 2>/dev/null | \
	   awk '{print $$4}' | sort | uniq -c || \
	 { echo ""; echo "  ✗ could not reach the cluster. Check that :$(KUBE_API_PORT) is open in the"; \
	   echo "    security group, then re-run 'make kubeconfig' (it repairs the forwarder)."; exit 1; }

nodes:               ## kubectl get nodes, using the fetched kubeconfig
	@[ -f "$(KUBECONFIG_OUT)" ] || { echo "✗ run 'make kubeconfig' first"; exit 1; }
	@KUBECONFIG="$(KUBECONFIG_OUT)" kubectl get nodes -o wide

# ──────────────────────────────────────────────────────────────────────────────
#  CLUSTER (on the remote box)
# ──────────────────────────────────────────────────────────────────────────────

.PHONY: cluster-up cluster-down cluster-reset

cluster-up:          ## (Re)create the kind cluster on the box — idempotent
	@HOST="$(EC2_HOST)"; \
	[ -n "$$HOST" ] || { echo "  ✗ no instance — run 'make tf-apply'"; exit 1; }; \
	$(SSH_WRAP) ssh $(SSH_OPTS) "$(EC2_USER)@$$HOST" \
	  "export PATH=/usr/local/bin:\$$PATH; \
	   kind get clusters 2>/dev/null | grep -qx $(KIND_CLUSTER) && echo '✓ cluster $(KIND_CLUSTER) already exists' || \
	   kind create cluster --name $(KIND_CLUSTER) --config /home/$(EC2_USER)/kind-config.yaml; \
	   kubectl get nodes"

cluster-down:        ## Delete the kind cluster (the instance keeps running)
	@HOST="$(EC2_HOST)"; \
	[ -n "$$HOST" ] || { echo "  ✗ no instance — run 'make tf-apply'"; exit 1; }; \
	$(SSH_WRAP) ssh $(SSH_OPTS) "$(EC2_USER)@$$HOST" \
	  "export PATH=/usr/local/bin:\$$PATH; kind delete cluster --name $(KIND_CLUSTER)"

cluster-reset:       ## cluster-down + cluster-up (fresh, empty cluster)
	@$(MAKE) -s cluster-down
	@$(MAKE) -s cluster-up
	@$(MAKE) -s kubeconfig

# ──────────────────────────────────────────────────────────────────────────────
#  HELP
# ──────────────────────────────────────────────────────────────────────────────

.PHONY: help

help:                ## Show this help
	@echo ""
	@echo "  minik8s — bare Kubernetes on an EC2 spot box"
	@echo "  ───────────────────────────────────────────"
	@# Sections are the banner blocks: a ── rule line, then the title line.
	@awk 'BEGIN {FS = ":.*?## "} \
	  /^# ──/ {grab=1; next} \
	  grab {if ($$0 ~ /^#  /) {section=substr($$0,4); printed=0} grab=0; next} \
	  /^[a-zA-Z_-]+:.*?## / { \
	    if (!printed && section!="") { printf "\n  \033[1;33m%s\033[0m\n", section; printed=1 } \
	    printf "    \033[36m%-18s\033[0m %s\n", $$1, $$2 \
	  }' $(MAKEFILE_LIST)
	@echo ""
	@echo "  Typical run:  make tf-apply → make kubeconfig → make kube-check → make tf-destroy"
	@echo ""
