#!/usr/bin/env bash
# Install everything needed for the kind-on-EC2 deployment:
#   docker · kind · kubectl · helm · make · jq · git
# Supports Amazon Linux 2023 and Ubuntu 22.04/24.04 (x86_64).
# Run as a user with sudo (ec2-user / ubuntu). Idempotent — safe to re-run.
set -euo pipefail

KIND_VERSION="v0.23.0"
ARCH="$(uname -m)"
[ "${ARCH}" = "x86_64" ] || { echo "✗ x86_64 required (images are amd64), got ${ARCH}"; exit 1; }

say() { echo -e "\n─── $* ───"; }

labauto docker-stack

# ── kubectl (latest stable) ──────────────────────────────────────────────────
if ! command -v kubectl >/dev/null 2>&1; then
  say "installing kubectl"
  KUBECTL_VERSION="$(curl -sL https://dl.k8s.io/release/stable.txt)"
  curl -sLo /tmp/kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
  install -m 0755 /tmp/kubectl /usr/local/bin/kubectl && rm /tmp/kubectl
fi

# ── kind ─────────────────────────────────────────────────────────────────────
if ! command -v kind >/dev/null 2>&1; then
  say "installing kind ${KIND_VERSION}"
  curl -sLo /tmp/kind "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-amd64"
  install -m 0755 /tmp/kind /usr/local/bin/kind && rm /tmp/kind
fi

# ── helm ─────────────────────────────────────────────────────────────────────
if [ ! -f /usr/local/bin/helm ] ; then
  say "installing helm"
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-4 | bash
fi

say "versions"
docker --version
kind --version
kubectl version --client --output=yaml | grep gitVersion || true
helm version --short
jq --version
make --version | head -1

echo ""
echo "✓ tools installed."
echo "  ⚠ Log out and back in (or run 'newgrp docker') so your user can use docker"
echo "    without sudo, then continue with the README (make prep)."
