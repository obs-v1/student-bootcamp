# BankObserve360 on Kubernetes — kind on a single EC2 server

This folder deploys the full 75-service banking platform on a **kind**
(Kubernetes-in-Docker) cluster running on **one Linux EC2 instance** — the
Kubernetes middle ground between the docker-compose setup (root `README.md`)
and the full AWS EKS setup (`make eks-up`). Same public images
(`public.ecr.aws/w8x4g9h7/obs-v1/*`), nothing to build.

```
EC2 host (m5.4xlarge)
└── docker
    └── kind node "bankobs-control-plane"  (single-node Kubernetes)
        └── namespace bankobs
            ├── Helm release "bankobs"  → 65 app services (../helm/bankobserve360)
            ├── manifests/platform/     → Oracle · Postgres · MongoDB · Redis ·
            │                             Cassandra · Elasticsearch · Kafka ·
            │                             RabbitMQ · license-checker · web-portal ·
            │                             init Jobs (topics, keyspace, indices)
            └── manifests/observability/ → OTel Collector · Prometheus · Grafana ·
                                          Loki · Jaeger · Alertmanager · Fluent Bit
                                          (deployed in Week 1 by `make obs-on`)
```

Everything runs in the single `bankobs` namespace so that the compose-era
hostnames (`oracle`, `kafka`, `license-checker`, …) resolve unchanged, which is
what lets the course configs under `config/` (Prometheus scrape targets,
Grafana datasources, OTel exporters) be mounted as ConfigMaps **verbatim**.

## 1 · EC2 instance

| Item | Requirement | Why |
|---|---|---|
| Instance type | **m5.4xlarge** (16 vCPU / 64 GB) recommended | ~90 pods on one node; the Helm chart requests 100m CPU / 128 Mi per app pod, plus the data stores. On an m5.2xlarge you must disable sub-charts in `values-kind.yaml` (comments included). |
| Root volume | **150 GB gp3** | Images are stored twice: once in docker on the host, once inside the kind node's containerd. |
| AMI | Amazon Linux 2023 or Ubuntu 22.04+, **x86_64** | Images are amd64. |
| Security group | Inbound **80** (portal), and after Week 1: **13000** (Grafana), **16686** (Jaeger), **9090** (Prometheus) — restrict to *your* IP | These are the only host-published ports (see `kind-config.yaml`). |

No security group opening needed if you prefer SSH tunnels:
`ssh -L 8080:localhost:80 -L 13000:localhost:13000 ec2-user@<ip>`.

## 2 · Install tools

On the EC2 host:

```bash
git clone <this-repo>            # clone the WHOLE repo — manifests mount
cd student-bootcamp/ec2-k8s      # configs/init-scripts from ../config and
bash scripts/install-tools.sh    # ../infrastructure
# log out & back in (docker group), then:
make prep                        # sysctls (vm.max_map_count, inotify) + checks
```

## 3 · License

The license binds to the EC2 machine's hardware fingerprint, so run this **on
the EC2 host** (not your laptop):

```bash
cd ..                # repo root
cp .env.example .env
make fingerprint     # email the fingerprint to your trainer
# paste the JWT you receive into .env:  LICENSE_KEY=eyJ...
cd ec2-k8s
```

`make deploy` reads `../.env` and passes `LICENSE_KEY` plus the host's
machine-id / MAC / hostname into the in-cluster `license-checker` — the same
values the fingerprint was computed from.

## 4 · Create the cluster and deploy

```bash
make cluster-up      # kind cluster with host ports 80/13000/16686/9090 mapped
make deploy          # ConfigMaps + Secret → infra manifests → Helm chart → env wiring
```

`make deploy` does, in order:

1. Creates the `bankobs` namespace, builds ConfigMaps from
   `../infrastructure/` (DB init scripts, Kafka `topics.sh`, RabbitMQ
   definitions, `redis.conf`) and the `bankobs-license` Secret from `../.env`.
2. Applies `manifests/platform/` — data stores as StatefulSets with
   PersistentVolumeClaims (kind's `standard` local-path storage), plus
   `license-checker`, `web-portal`, and three one-shot init Jobs
   (Kafka topics, Cassandra keyspace + seed, Elasticsearch indices).
   Oracle/Postgres/MongoDB seed themselves on first boot via their
   `initdb.d` ConfigMaps — the K8s equivalent of `make seed`.
3. Waits for `license-checker` (app services refuse to start without it).
4. `helm upgrade --install` of `../helm/bankobserve360` with
   [`values-kind.yaml`](values-kind.yaml) — the 65 application services.
5. Injects the compose-equivalent environment (DB URLs, Kafka, JWT, license
   URL — see [`manifests/platform/00-env-configmap.yaml`](manifests/platform/00-env-configmap.yaml))
   into every chart deployment: the chart itself only sets
   `SERVICE_NAME`/`SERVICE_PORT`, exactly as on EKS.

**First run takes 15–40 minutes** (image pulls) and Oracle needs ~5–10 minutes
of first-boot time on top. Watch progress:

```bash
make status          # pod phase summary + anything not Running
make wait-infra      # blocks until all data stores are Ready and init Jobs done
```

## 5 · Verify

```bash
make smoke           # portal on host :80 + gateway /health/ready in-cluster
make seed-verify     # Oracle rows, Cassandra keyspace, Kafka topics
make urls            # where every UI lives (uses the EC2 public IP)
```

Portal: `http://<ec2-ip>/` — login `CUST-00000001` / `Training@123`.

## 6 · Week 1 — turn observability on

The apps start **dark** (telemetry off), matching the compose course flow.
The `make obs-up` equivalent:

```bash
make obs-on          # deploys the observability stack + flips app telemetry to full
```

This builds ConfigMaps from `../config/` (Prometheus config + alert rules,
Grafana datasources + all 13 dashboards, Loki, OTel Collector, Alertmanager,
the PII-masking `pii-mask.lua`), applies `manifests/observability/`, and rolls
every app deployment with `OBSERVABILITY_MODE=full` + OTel enabled.

* Grafana `http://<ec2-ip>:13000` (admin/admin) — dashboards pre-provisioned
* Jaeger `http://<ec2-ip>:16686` · Prometheus `http://<ec2-ip>:9090`
* `make obs-off` flips telemetry back to dark (labs that compare modes)

## 7 · Daily commands

```
make status · make health · make smoke · make logs-svc S=upi-service
make restart-svc S=loan-origination · make shell-oracle / shell-pg / shell-mongo /
shell-redis / shell-cassandra / shell-kafka · make fix-cassandra
```

Anything not covered: it's a normal Kubernetes cluster —
`kubectl -n bankobs get pods`, `kubectl -n bankobs describe pod <p>`,
`kubectl -n bankobs port-forward svc/<name> <port>:<port>`.

## 8 · Teardown

```bash
make down            # deletes the kind cluster (all in-cluster data)
make nuke            # down + docker image prune (frees ~40 GB)
```

Then stop/terminate the EC2 instance from the AWS console.

## 9 · What differs from docker-compose

| Compose | Here | Notes |
|---|---|---|
| `depends_on` + healthchecks | K8s probes + restart loops | Apps crash-loop briefly until their store is Ready — normal, self-heals. |
| `*-init` one-shot containers | Kubernetes Jobs | Same scripts, mounted from ConfigMaps; scripts self-wait. |
| `make seed` (docker exec) | initdb ConfigMaps + init Jobs at first boot | `make seed-verify` checks the result. |
| Fluent Bit tails Docker JSON logs | DaemonSet tails containerd/CRI logs | Only config that could not be reused verbatim — see the header of [`manifests/observability/66-fluent-bit.yaml`](manifests/observability/66-fluent-bit.yaml). Same PII lua mask, same Loki labels. |
| `transit-gateway-proxy` (HAProxy) + per-"VPC" docker networks | omitted | It simulates cross-VPC routing between compose networks; kind has one flat pod network, so there is nothing to route. |
| Per-service host ports (18001, 18011, …) | not published | Only 80/13000/16686/9090 reach the host; use `kubectl port-forward` for the rest. |
| `OTEL_EXPORTER_OTLP_ENDPOINT` per-protocol mix | gRPC :4317 for all | The collector listens on both 4317/4318 regardless. |

Known cosmetic wart: the OTel Collector config keeps the `docker` resource
detector from the compose setup; inside Kubernetes it logs one detection
warning at startup and is otherwise harmless.

## 10 · Troubleshooting

| Symptom | Fix |
|---|---|
| Pods stuck `Pending` | Node out of allocatable CPU/memory — `kubectl describe pod <p>` shows it. Use a bigger instance or disable sub-charts in `values-kind.yaml`, then re-run `make deploy`. |
| `ImagePullBackOff` | Transient registry throttling — it retries itself. `kubectl -n bankobs describe pod <p>` to confirm. |
| Elasticsearch `CrashLoopBackOff`, "max virtual memory areas too low" | `make prep` wasn't run — it sets `vm.max_map_count` on the host (kind shares the kernel). |
| Many pods `CrashLoopBackOff` right after deploy | Usually just waiting on Oracle/Cassandra — `make wait-infra`, then give it a few minutes. |
| Everything crash-loops with license errors | `LICENSE_KEY` empty/wrong in `../.env`, or fingerprint was generated on a different machine. `kubectl -n bankobs logs deploy/license-checker`. |
| Cassandra won't go Ready after node restart | `make fix-cassandra` (wipes commit log, restarts, prints the re-seed command). |
| "too many open files" / inotify errors in pod logs | `make prep` sets the inotify sysctls; re-run it. |
| Node pod limit | Single kind node allows 110 pods; this stack uses ~95 incl. kube-system. Don't scale replicas up without headroom. |
| Portal unreachable from your browser | Security group inbound 80 missing, or portal pod not Ready yet (`make status`). Locally on the host `curl -I http://localhost/` must return 200 first. |
