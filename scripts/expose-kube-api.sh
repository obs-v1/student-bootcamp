#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Expose this host's kind API server on its public interface, then print a
# kubeconfig that points at it.
#
# WHY THIS EXISTS
#   ec2-k8s/kind-config.yaml sets no networking.apiServerAddress, so kind binds
#   the API server to 127.0.0.1:<random-port> ON THIS HOST. Nothing outside the
#   box can reach it, and the serving cert has no SAN for the public IP. Both
#   are create-time properties — changing them means destroying the cluster.
#
#   So instead: a systemd-managed TCP forwarder from 0.0.0.0:<LISTEN_PORT> to
#   that loopback port. socat is a dumb byte pump — TLS (and client-cert auth)
#   passes through end to end, untouched.
#
#   The cert SAN problem is solved on the *client* side: the emitted kubeconfig
#   sets `tls-server-name: kubernetes`, which is already a SAN on kind's API
#   server cert, so the client verifies against that name instead of the IP.
#   Full TLS verification stays ON — no --insecure-skip-tls-verify anywhere.
#
# SECURITY
#   This publishes the Kubernetes API on the instance's public interface.
#   Access still requires the client cert in the printed kubeconfig, but treat
#   that file as a root credential for the cluster, and keep the instance's
#   security group tight.
#
# USAGE
#   bash scripts/expose-kube-api.sh > my-kubeconfig     # progress → stderr
#
#   PUBLIC_IP     address to put in the kubeconfig  (default: from EC2 IMDS)
#   CLUSTER       kind cluster name                 (default: bankobs)
#   LISTEN_PORT   port to expose the API on         (default: 6443)
#   CONTEXT_NAME  context name in the kubeconfig    (default: bankobs-ec2)
#
# Idempotent — safe to re-run. Re-running also repairs the forwarder after the
# kind cluster is recreated on a different random port.
# ---------------------------------------------------------------------------
set -euo pipefail

CLUSTER="${CLUSTER:-bankobs}"
LISTEN_PORT="${LISTEN_PORT:-6443}"
CONTEXT_NAME="${CONTEXT_NAME:-bankobs-ec2}"
UNIT="kube-api-proxy"
export PATH="/usr/local/bin:$PATH"

# Everything human-readable goes to stderr; stdout is reserved for the
# kubeconfig, so the caller can redirect it straight into a file.
say() { echo "  $*" >&2; }
die() { echo "  ✗ $*" >&2; exit 1; }

# ── 1. where is kind's API server listening? ────────────────────────────────
command -v kind >/dev/null 2>&1 || die "kind not found on PATH (run scripts/install-tools.sh)"

KCFG="$(kind get kubeconfig --name "$CLUSTER" 2>/dev/null || true)"
[ -n "$KCFG" ] || die "kind cluster '$CLUSTER' not found (kind get clusters)"

TARGET_PORT="$(printf '%s\n' "$KCFG" \
  | sed -n 's|.*server: https://[^:]*:\([0-9][0-9]*\).*|\1|p' | head -1)"
[ -n "$TARGET_PORT" ] || die "could not parse the API port out of kind's kubeconfig"
say "kind API server is on 127.0.0.1:${TARGET_PORT}"

# ── 2. which address should clients dial? ───────────────────────────────────
if [ -z "${PUBLIC_IP:-}" ]; then
  # IMDSv2 first (token required), fall back to IMDSv1.
  TOKEN="$(curl -s -m 2 -X PUT http://169.254.169.254/latest/api/token \
             -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' 2>/dev/null || true)"
  if [ -n "$TOKEN" ]; then
    PUBLIC_IP="$(curl -s -m 2 -H "X-aws-ec2-metadata-token: $TOKEN" \
                   http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || true)"
  else
    PUBLIC_IP="$(curl -s -m 2 http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || true)"
  fi
fi
[ -n "${PUBLIC_IP:-}" ] || die "could not determine the public IP — pass PUBLIC_IP=<ip>"
say "clients will connect to ${PUBLIC_IP}:${LISTEN_PORT}"

# ── 3. socat ────────────────────────────────────────────────────────────────
if ! command -v socat >/dev/null 2>&1; then
  say "installing socat…"
  sudo dnf install -y socat >/dev/null 2>&1 \
    || sudo yum install -y socat >/dev/null 2>&1 \
    || { sudo apt-get update -qq >/dev/null 2>&1 && sudo apt-get install -y socat >/dev/null 2>&1; } \
    || die "could not install socat — install it manually and re-run"
fi
SOCAT="$(command -v socat)"

# ── 4. the forwarder, under systemd so it survives reboots ──────────────────
# The port is baked in at install time. Docker republishes the same host port
# across reboots, so this only goes stale if the kind cluster is recreated —
# which re-running this script fixes.
sudo tee "/etc/systemd/system/${UNIT}.service" >/dev/null <<EOF
[Unit]
Description=Expose kind (${CLUSTER}) API server on :${LISTEN_PORT}
Documentation=https://github.com/obs-v1/student-bootcamp
After=network-online.target docker.service
Wants=network-online.target

[Service]
ExecStart=${SOCAT} TCP-LISTEN:${LISTEN_PORT},fork,reuseaddr TCP:127.0.0.1:${TARGET_PORT}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable "${UNIT}.service" >/dev/null 2>&1 || true
# restart (not just start) so a re-run picks up a changed TARGET_PORT
sudo systemctl restart "${UNIT}.service"

# ── 5. firewalld, if this box runs it ───────────────────────────────────────
if systemctl is-active --quiet firewalld 2>/dev/null; then
  say "opening ${LISTEN_PORT}/tcp in firewalld"
  sudo firewall-cmd --permanent --add-port="${LISTEN_PORT}/tcp" >/dev/null 2>&1 || true
  sudo firewall-cmd --reload >/dev/null 2>&1 || true
fi

# ── 6. verify the forwarder actually answers ────────────────────────────────
for i in $(seq 1 10); do
  if curl -sk -m 3 "https://127.0.0.1:${LISTEN_PORT}/version" >/dev/null 2>&1; then
    say "✓ forwarder is up (${LISTEN_PORT} → ${TARGET_PORT})"
    break
  fi
  [ "$i" = 10 ] && die "forwarder not answering on :${LISTEN_PORT} — check: systemctl status ${UNIT}"
  sleep 1
done

# ── 7. emit the client kubeconfig on stdout ─────────────────────────────────
# - repoint the server at the public IP
# - pin cert verification to the name "kubernetes" (a SAN on kind's cert)
# - rename kind-<cluster> → CONTEXT_NAME so it can't collide with a local kind
printf '%s\n' "$KCFG" \
  | awk -v server="https://${PUBLIC_IP}:${LISTEN_PORT}" '
      /^[[:space:]]*server:[[:space:]]*https:\/\// {
        match($0, /^[[:space:]]*/); indent = substr($0, 1, RLENGTH)
        print indent "server: " server
        print indent "tls-server-name: kubernetes"
        next
      }
      { print }' \
  | sed -e "s|kind-${CLUSTER}|${CONTEXT_NAME}|g"

say ""
say "kubeconfig written to stdout (context: ${CONTEXT_NAME})"
