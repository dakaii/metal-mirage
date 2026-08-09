#!/usr/bin/env bash
# Install Flux on a cluster and point it at this repo's gitops/ path.
# Usage: KUBECONFIG=./.secrets/primary.kubeconfig ./scripts/install-flux.sh primary
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLUSTER="${1:-primary}"
REPO_URL="${GITOPS_REPO_URL:-$(git -C "${ROOT}" remote get-url origin 2>/dev/null || echo "https://github.com/OWNER/metal-mirage")}"
BRANCH="${GITOPS_BRANCH:-main}"

command -v flux >/dev/null || {
  echo "Install flux CLI: https://fluxcd.io/flux/installation/" >&2
  exit 1
}

flux check --pre
flux install

flux create source git metal-mirage \
  --url="${REPO_URL}" \
  --branch="${BRANCH}" \
  --interval=1m

flux create kustomization infrastructure \
  --source=metal-mirage \
  --path="./gitops/clusters/${CLUSTER}" \
  --prune=true \
  --interval=5m

echo "Flux watching ${REPO_URL} → gitops/clusters/${CLUSTER}"
