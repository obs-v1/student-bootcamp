# BankObserve360 — Student Bootcamp

A complete 75-service banking platform for the Observability course.
All images are PUBLIC at public.ecr.aws/w8x4g9h7/obs-v1/* — nothing to build, no registry login needed.

## Quick start (local — docker-compose)

```bash
cp .env.example .env
make fingerprint            # send the fingerprint to your trainer
# paste the license you receive into .env as LICENSE_KEY=...
make compose-up             # bring up the full platform (first run pulls ~60 images)
make seed                   # load banking data (accounts, transactions, topics)
make smoke                  # balance → UPI payment → loan application, end-to-end
make urls                   # every UI and where to find it
```

## Quick start (AWS — EKS)

```bash
cp .env.example .env        # license flow as above
make eks-up                 # Terraform: VPC + EKS + nodes, then Helm-deploys the platform
make eks-status
make eks-down               # DESTROYS all AWS resources when you're done
```

⚠️ `eks-up` creates real AWS resources (≈ $1.5–2/hour while running).

## Daily commands

`make status` · `make health` · `make smoke` · `make logs-svc S=<name>` · `make compose-down`

## Running on a Linux EC2 server

Works natively (the images are x86_64). Checklist:

1. Instance: **m5.2xlarge minimum** (8 vCPU / 32 GB), **100 GB gp3** root volume
2. Install Docker + the compose v2 plugin, `make`, `jq`, `git`
3. Clone this WHOLE folder (the compose file bind-mounts `./config` and `./infrastructure`)
4. `make ec2-prep` — sets `vm.max_map_count` (Elasticsearch dies without it) and checks prereqs
5. `make fingerprint` — the license binds to the EC2 machine, so run it THERE
6. Security group: every UI binds 0.0.0.0 (portal :8200, Grafana :13000, Prometheus :9090, Jaeger :16686). Restrict the SG to your IP, or keep ports closed and use SSH tunnels: `ssh -L 8200:localhost:8200 -L 13000:localhost:13000 ec2-user@<ip>`

## If something misbehaves

`make fix-cassandra` handles the known Cassandra cold-start issue (re-run `make seed` after).
For anything else: `make status`, then `docker logs bankobs-<service>`.
