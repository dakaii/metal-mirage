#!/usr/bin/env bash
# Point Flux at this repo's gitops/ path (controllers must already exist).
# Prefer: pulumi up in infra/flux-bootstrap, then this script for GitRepository + root Kustomization.
# Usage: KUBECONFIG=./.secrets/primary.kubeconfig ./scripts/install-flux.sh primary
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLUSTER="${1:-primary}"
REPO_URL="${GITOPS_REPO_URL:-$(git -C "${ROOT}" remote get-url origin 2>/dev/null || echo "https://github.com/dakaii/metal-mirage")}"
BRANCH="${GITOPS_BRANCH:-main}"
INSTALL_CONTROLLERS="${FLUX_INSTALL_CONTROLLERS:-auto}"

case "${CLUSTER}" in
  primary|standby) ;;
  *)
    echo "usage: $0 primary|standby" >&2
    exit 1
    ;;
esac

if [[ -z "${KUBECONFIG:-}" && ! -f "${ROOT}/.secrets/${CLUSTER}.kubeconfig" ]]; then
  echo "Set KUBECONFIG or write .secrets/${CLUSTER}.kubeconfig first" >&2
  echo "  pulumi -C infra/primary stack output kubeconfig --show-secrets > .secrets/primary.kubeconfig" >&2
  exit 1
fi
export KUBECONFIG="${KUBECONFIG:-${ROOT}/.secrets/${CLUSTER}.kubeconfig}"

command -v flux >/dev/null || {
  echo "Install flux CLI: https://fluxcd.io/flux/installation/" >&2
  exit 1
}
command -v kubectl >/dev/null || {
  echo "missing kubectl" >&2
  exit 1
}

flux check --pre

# Controllers: skip if flux-bootstrap Helm already installed them.
if kubectl get ns flux-system >/dev/null 2>&1 && kubectl -n flux-system get deploy source-controller >/dev/null 2>&1; then
  echo "==> Flux controllers already present (skipping flux install)"
elif [[ "${INSTALL_CONTROLLERS}" == "never" ]]; then
  echo "Flux controllers missing; run infra/flux-bootstrap or unset FLUX_INSTALL_CONTROLLERS=never" >&2
  exit 1
else
  echo "==> Installing Flux controllers via flux CLI"
  flux install
fi

# Convert git@github.com:org/repo.git remotes to HTTPS for anonymous fetch.
if [[ "${REPO_URL}" == git@github.com:* ]]; then
  REPO_URL="https://github.com/${REPO_URL#git@github.com:}"
  REPO_URL="${REPO_URL%.git}"
fi

flux create source git metal-mirage \
  --url="${REPO_URL}" \
  --branch="${BRANCH}" \
  --interval=1m \
  --export | kubectl apply -f -

# Root Kustomization applies gitops/clusters/<name> (kustomize → Flux child Kustomizations).
flux create kustomization cluster-root \
  --source=metal-mirage \
  --path="./gitops/clusters/${CLUSTER}" \
  --prune=true \
  --interval=5m \
  --export | kubectl apply -f -

echo "Flux watching ${REPO_URL}@${BRANCH} → gitops/clusters/${CLUSTER}"
echo "Check: flux get kustomizations -A"
