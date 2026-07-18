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
what lets the configs under `config/` (Prometheus scrape targets,
Grafana datasources, OTel exporters) be mounted as ConfigMaps **verbatim**.

## 1 · Create EC2 instance

| Item | Requirement | Why |
|---|---|---|
| Instance type | **m5.4xlarge** (16 vCPU / 64 GB) recommended | ~90 pods on one node; the Helm chart requests 100m CPU / 128 Mi per app pod, plus the data stores. On an m5.2xlarge you must disable sub-charts in `values-kind.yaml` (comments included). |
| Root volume | **150 GB gp3** | Images are stored twice: once in docker on the host, once inside the kind node's containerd. |
| AMI | Redhat-9-DevOps-Practice (ami-0220d79f3f480ecf5) |
| Security group | Inbound **80** (portal), and after Week 1: **13000** (Grafana), **16686** (Jaeger), **9090** (Prometheus) — restrict to *your* IP | These are the only host-published ports (see `kind-config.yaml`). |

All the above setup can also be done with code

```
make tf-apply
```

## 2 · Install tools

On the EC2 host:

```bash
git clone <this-repo>            # clone the WHOLE repo — manifests mount
cd student-bootcamp/ec2-k8s      # configs/init-scripts from ../config and
bash scripts/install-tools.sh    # ../infrastructure
```

## 3 · License

The license binds to the EC2 machine's hardware fingerprint, so run this **on
the EC2 host** (not your laptop):

```bash
cd student-bootcamp
cp .env.example .env
```

### paste the license you receive into .env as LICENSE_KEY=...

```
LICENSE_KEY=eyJhbGciOiJFZERTQSIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJjb2hvcnRAYmFua29ic2VydmUzNjAudHJhaW5pbmciLCJodyI6IioiLCJ0aWVyIjoic3R1ZGVudCIsImZlYXR1cmVzIjpbImFsbCJdLCJqdGkiOiI0NDY4OTRhNS00NDg5LTQ5ZDctOGE2Mi0zM2FkYTYxY2MwNjMiLCJpc3MiOiJiYW5rb2JzZXJ2ZTM2MCIsImV4cCI6MTc5ODgwMzM0MSwiaWF0IjoxNzgzMjUxMzQxfQ.RuC_RlHu6yHRrLglVd_ExZynHq1Lb9nlYruoyFfEO5Hk1uU7PU9z5b_F9F7nzW3Hj3MHVJMj5MhGOjYYZWeiAQ
```

### Bring the services up 

```bash
cd ec2-k8s
make up
```

You can login to portal using this.

Portal: `http://<ec2-ip>/` — login `CUST-00000001` / `Training@123`.

