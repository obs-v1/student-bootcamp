# kind cluster for BankObserve360 on a single EC2 server.
# extraPortMappings publish NodePorts on the EC2 host so the portal and
# observability UIs are reachable on the same ports the docker-compose
# setup uses (80, 13000, 16686, 9090).
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: bankobs
nodes:
  - role: control-plane
    # Kubernetes version of the cluster — pinned so it doesn't drift with the
    # kind binary. Needs kind >= v0.32.0 (see scripts/install-tools.sh).
    image: kindest/node:v1.36.1@sha256:3489c7674813ba5d8b1a9977baea8a6e553784dab7b84759d1014dbd78f7ebd5
    extraPortMappings:
      - containerPort: 30080   # web-portal  (NodePort) → http://<ec2-ip>/
        hostPort: 80
        protocol: TCP
      - containerPort: 31300   # grafana     (NodePort) → http://<ec2-ip>:13000
        hostPort: 13000
        protocol: TCP
      - containerPort: 31686   # jaeger      (NodePort) → http://<ec2-ip>:16686
        hostPort: 16686
        protocol: TCP
      - containerPort: 30990   # prometheus  (NodePort) → http://<ec2-ip>:9090
        hostPort: 9090
        protocol: TCP
