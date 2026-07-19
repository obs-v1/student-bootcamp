# B3 — Containers & Kubernetes Recap

The banking platform on our training server runs as ~70 pods in a Kubernetes
cluster. This module is a tour of that cluster. Every output is real — and
two services in it are genuinely broken (on purpose, more on that later),
which gives us live examples of the failure states you'll spend this course
diagnosing.

Setup on this box, for orientation: the whole cluster runs inside **one
Docker container** using `kind` (Kubernetes-in-Docker). From the host:

```
$ docker ps
CONTAINER ID   IMAGE                  STATUS         PORTS                                    NAMES
0bae1c300d90   kindest/node:v1.36.1   Up 5 minutes   0.0.0.0:80->30080/tcp, ...               bankobs-control-plane
```

One container pretending to be a whole node. Everything below works the same
on a real multi-node cluster (like the EKS path in B4).

---

## 1. Containers in three ideas

A container is **not** a small virtual machine. It is a normal Linux process
with three tricks applied:

1. **Namespaces** — the process gets its own view of the system: its own
   process list, network interfaces, hostname, filesystem root. It *thinks*
   it's alone.
2. **cgroups** — the kernel caps how much CPU and memory that process may
   use. This is where "OOMKilled" will come from later.
3. **Image layers** — the filesystem is a stack of read-only layers
   (base OS → runtime → your app) plus one writable layer on top. Layers are
   shared between containers, which is why 60 Java services don't cost 60
   copies of the JVM on disk.

The images for our services live inside the cluster node:

```
$ docker exec bankobs-control-plane crictl images | head -5
IMAGE                                             TAG        SIZE
docker.elastic.co/elasticsearch/elasticsearch     8.11.4     740MB
docker.io/apache/kafka                            3.7.0      210MB
docker.io/gvenzl/oracle-xe                        21-slim    755MB
```

**Lifecycle and stdout.** A container lives exactly as long as its main
process (PID 1 inside). Process exits → container exits. And well-behaved
containers don't write log files — they write to **stdout**, and the runtime
captures it. That one convention is what makes `kubectl logs` possible.

---

## 2. The Kubernetes objects, via our cluster

You rarely create pods directly. You create higher-level objects and they
manage pods. Our namespace `bankobs` contains, right now:

```
$ kubectl -n bankobs get deploy | wc -l      # 61 Deployments  (the app services)
$ kubectl -n bankobs get sts                 # 8 StatefulSets  (the databases)
NAME            READY   AGE
cassandra       1/1     5m
elasticsearch   1/1     5m
kafka           1/1     5m
mongodb         1/1     5m
oracle          1/1     5m
postgres        1/1     5m
rabbitmq        1/1     5m
redis           1/1     5m
$ kubectl -n bankobs get jobs                # 3 Jobs          (one-time seeding)
NAME                 STATUS     COMPLETIONS   DURATION
cassandra-init       Complete   1/1           2m2s
elasticsearch-init   Complete   1/1           2m2s
kafka-init           Complete   1/1           2m26s
```

Cheat sheet:

| Object | What it's for | In our app |
|---|---|---|
| Pod | 1+ containers scheduled together — the atom | everything |
| Deployment | "keep N copies of this stateless thing running" | all 60 banking services |
| ReplicaSet | created *by* Deployments to do the counting — you read it, never write it | (behind every deploy) |
| StatefulSet | pods with stable names + their own disks | oracle-0, kafka-0… |
| DaemonSet | one pod per node | log collector (added in week 1) |
| Job | run to completion, then stop | kafka topic creation |
| Service | one stable name/IP in front of pods | `oracle`, `upi-service`… (69 of them) |
| Ingress | HTTP routing into the cluster | (we use a NodePort on :80 instead) |
| HPA | autoscale a Deployment on load | not used in training |

Notice the pattern in the real listing: **stateless things are Deployments,
stateful things are StatefulSets**. A database wants to wake up with the same
name and the same disk; `oracle-0` does, a Deployment pod (random suffix,
fresh filesystem) does not.

---

## 3. Pod lifecycle — the states and what they really mean

The states you'll stare at all course:

```
$ kubectl -n bankobs get pods | head -8
NAME                                 READY   STATUS             RESTARTS      AGE
aadhaar-adapter-66b47fcfb8-6dpct     1/1     Running            0             4m29s
account-service-6c55f779c5-rps7f    1/1     Running            0             4m26s
balance-service-cb8f7bb5f-ptld2     0/1     CrashLoopBackOff   4 (4s ago)    4m28s
cassandra-0                          1/1     Running            0             5m36s
cassandra-init-cjrv4                 0/1     Completed          0             5m27s
```

**Pending** — no node accepted the pod yet. `describe` tells you why. Caught
live during this cluster's install (all images were downloading and old pods
still held their slots):

```
Events:
  Warning  FailedScheduling  default-scheduler  0/1 nodes are available: 1 Too many pods.
```

Other classic Pending reasons: `Insufficient cpu`, `Insufficient memory` —
the node can't fit the pod's *requests* (section 5).

**ContainerCreating** — scheduled, now pulling the image / mounting volumes:

```
Events:
  Normal  Scheduled  default-scheduler  Successfully assigned bankobs/audit-service-... to bankobs-control-plane
  Normal  Pulling    kubelet            Pulling image "public.ecr.aws/w8x4g9h7/obs-v1/audit-service:1.0.0"
```

Stuck here for long = slow registry or a volume problem.

**ImagePullBackOff** — the image can't be fetched: name typo, missing tag, or
no registry credentials. "BackOff" means kubernetes retries with growing
delays. Read the exact error with `kubectl describe pod`.

**CrashLoopBackOff** — the container starts, dies, starts, dies… Our
balance-service is doing it right now, for real:

```
$ kubectl -n bankobs describe pod -l app=balance-service | grep -E "State|Reason|Exit|Restart"
    State:          Waiting
      Reason:       CrashLoopBackOff
    Last State:     Terminated
      Reason:       Error
      Exit Code:    1
    Restart Count:  4
```

The pod is fine, the *program inside* keeps exiting. So the next question is
always: what did it say before dying? →

```
$ kubectl -n bankobs logs deploy/balance-service --previous | tail -5
org.yaml.snakeyaml.parser.ParserException: while parsing a flow mapping
 in 'reader', line 13, column 12:
        redis: { host: ${REDIS_HOST:redis}, por ...
expected ',' or '}', but got {
```

`--previous` shows the logs of the *crashed* container, not the current
attempt. There's the crime: a broken YAML config inside the app. (This one
and cheque-service are the course's two intentionally-broken services — we
leave them crashing as a permanent specimen. You'll hunt bugs like this in
week 2.)

**OOMKilled vs Evicted** — both are "killed for memory" and people mix them
up:

- **OOMKilled** — *this container* exceeded *its own* memory **limit**. The
  cgroup killed it. Look for `Last State: Terminated, Reason: OOMKilled,
  Exit Code: 137` in `describe`. Fix: raise the limit or fix the leak.
- **Evicted** — the *node* ran out of memory and kubelet threw pods overboard
  to save itself. Innocent pods get evicted. Fix: node sizing / rebalancing.

One is "you exceeded your quota", the other is "the ship was sinking".

**QoS classes** — decided automatically from requests/limits, and it decides
eviction order:

```
$ kubectl -n bankobs get pod oracle-0 -o jsonpath='{.status.qosClass}'
Burstable
```

- **Guaranteed**: requests == limits for everything. Evicted last.
- **Burstable**: has requests, limits higher (all our pods). Middle.
- **BestEffort**: no requests/limits at all. Evicted first — never ship
  production pods like this.

---

## 4. Probes

Kubernetes doesn't guess whether your app is healthy — it asks. Three
questions, three probes. Here's a real one from our upi-service:

```
$ kubectl -n bankobs get deploy upi-service -o yaml | grep -A4 -E "(liveness|readiness)Probe"
        livenessProbe:
          httpGet:
            path: /health/live
            port: 8011
        readinessProbe:
          httpGet:
            path: /health/ready
            port: 8011
```

- **Liveness** — "are you alive?" Fails repeatedly → **restart** the
  container.
- **Readiness** — "can you take traffic?" Fails → pod is **removed from the
  Service endpoints** (no restart). This is how a pod that lost its DB
  connection stops receiving requests without being killed.
- **Startup** — "still booting?" Disables the other two until the app is up.
  For slow starters — our Oracle takes minutes on first boot.

### Misconfiguration patterns (all real, all painful)

1. **Liveness probe too aggressive** → restart storms. The app is merely slow
   (GC pause, cold cache) and kubernetes keeps killing it, making everything
   worse.
2. **Exec probe with the default 1-second timeout.** True story from building
   this very environment: our database probes ran commands like `nodetool
   status` and `mongosh ping`, which need 2–5 s. Default `timeoutSeconds: 1`
   → every probe "failed" → kubelet killed perfectly healthy databases in a
   loop for hours. If your probe runs a command, set `timeoutSeconds: 10`.
3. **No readiness probe** → traffic hits pods that are still booting → users
   see errors on every deploy.
4. **Liveness that checks a dependency** (e.g. pings the DB). DB blips →
   *every* app pod gets restarted simultaneously. Liveness should test the
   process itself only; dependencies belong in readiness.

---

## 5. Resources — requests and limits

Every container in our app declares:

```
$ kubectl -n bankobs get deploy upi-service -o jsonpath='{.spec.template.spec.containers[0].resources}'
{"limits":{"cpu":"500m","memory":"512Mi"},"requests":{"cpu":"50m","memory":"128Mi"}}
```

- **request** = reserved for scheduling. The scheduler adds up requests to
  decide if a pod fits on a node. (`500m` = half a CPU core.)
- **limit** = hard cap at runtime.

And the crucial asymmetry — what happens when you hit the limit:

- **CPU limit → throttled.** The app doesn't die, it gets *slow*. Sneaky:
  latency graphs go up, no errors anywhere.
- **Memory limit → OOMKilled.** Instant death, exit 137, restart.

The node's ledger (note limits happily over 100% — that's overcommit, fine as
long as everyone doesn't burst at once):

```
$ kubectl describe node bankobs-control-plane | grep -A5 "Allocated resources"
  Resource           Requests       Limits
  cpu                6150m (38%)    40600m (253%)
  memory             12706Mi (10%)  43398Mi (34%)
```

---

## 6. Container logs — the plumbing

The path your log line travels: app prints to **stdout** → container runtime
writes it to a file on the node → `kubectl logs` (and later, log collectors)
read that file. On our node:

```
$ docker exec bankobs-control-plane sh -c 'ls /var/log/containers | head -3; ls /var/log/containers | wc -l'
aadhaar-adapter-66b47fcfb8-6dpct_bankobs_aadhaar-adapter-b002a77e....log
account-service-6c55f779c5-rps7f_bankobs_account-service-4379c7cc....log
aml-service-664cc57f5b-7vqbm_bankobs_aml-service-585990a7ff28....log
82
```

One file per container, named `<pod>_<namespace>_<container>-<id>.log`. Week
1's log pipeline tails exactly these files.

Two gotchas to remember for later:

- **Multi-line fragmentation** — the runtime stores logs line by line. A Java
  stack trace (40 lines) becomes 40 separate records unless your pipeline
  stitches them back. You'll see this problem first-hand.
- **Rotation limits** — kubelet rotates these files (default ~10 MB × a few
  files). A chatty container's history disappears fast; `kubectl logs` only
  has what's still on disk. That's *why* we ship logs to a central store.

---

## 7. kubectl triage kit

The seven commands, in the order you actually use them:

```
kubectl -n bankobs get pods                        # 1. what's not Running?
kubectl -n bankobs describe pod <pod>              # 2. why? (events at the bottom)
kubectl -n bankobs logs <pod>                      # 3. what does the app say?
kubectl -n bankobs logs <pod> --previous           # 3b. what did it say BEFORE the crash?
kubectl -n bankobs get events --sort-by=.lastTimestamp | tail   # 4. cluster-wide story
kubectl -n bankobs exec -it <pod> -- sh            # 5. get inside
kubectl -n bankobs port-forward svc/grafana 3000:3000           # 6. reach a private service
kubectl top nodes / kubectl top pods               # 7. who's eating resources
```

Real examples of 4 and 7 from this cluster:

```
$ kubectl -n bankobs get events --sort-by=.lastTimestamp | tail -3
10s   Normal    Started   pod/balance-service-...   Container started
9s    Warning   BackOff   pod/cheque-service-...    Back-off restarting failed container
3s    Warning   BackOff   pod/balance-service-...   Back-off restarting failed container

$ kubectl top nodes
error: Metrics API not available
```

That error is itself a lesson: `kubectl top` needs the **metrics-server**
add-on, which plain clusters (like this kind one) don't ship. Managed
clusters like EKS usually have it. When it's missing you fall back to
`docker stats` / node-level tools — or install metrics-server.

`exec` example — open a SQL prompt inside the Postgres pod:

```
kubectl -n bankobs exec -it postgres-0 -- psql -U bankobs -d bankobs_retail
```

---

## 8. Helm — how those 60 services got here

Nobody applies 60 deployment YAMLs by hand. **Helm** packages them:

- **Chart** — a folder of YAML templates (ours: `helm/bankobserve360`)
- **Values** — the settings poured into the templates (image registry,
  replica counts, toggles per domain)
- **Release** — one installed instance of a chart in a cluster

```
$ helm list -n bankobs
NAME     NAMESPACE  REVISION  STATUS    CHART                 APP VERSION
bankobs  bankobs    1         deployed  bankobserve360-1.0.0  1.0.0
```

The three commands: `helm install` (first time), `helm upgrade` (new
values/version — bumps REVISION), `helm list` (what's here). One release,
REVISION 1: this cluster was installed once and not upgraded yet.

---

## 9. Hands-on

1. Find both CrashLoopBackOff pods. For each: `describe` (exit code? restart
   count?), then `logs --previous`. Write down the root cause of
   balance-service in one sentence.
2. Pick any Running service pod. What are its requests, limits and QoS class?
   (`kubectl get pod <p> -o jsonpath=...` or read `describe`.)
3. Kill a pod and watch the Deployment heal:
   `kubectl -n bankobs delete pod <any upi-service pod>` then
   `kubectl -n bankobs get pods -w`. How long until Running again?
4. Scale something: `kubectl -n bankobs scale deploy/branch-service
   --replicas=2`, watch, scale back to 1.
5. Exec into `postgres-0` and count credit cards:
   `SELECT COUNT(*) FROM credit_cards;` (expect 500 — B4 explains them).
6. From `describe pod cassandra-0`, find its liveness probe command and its
   `timeoutSeconds`. Why is it not 1?
