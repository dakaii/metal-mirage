#!/usr/bin/env bash
# Destroy stacks to stop billing: primary | standby | shared | vpn | flux | all
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="${1:-all}"
STACK="${PULUMI_STACK:-dev}"

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required tool: $1" >&2
    exit 1
  }
}

need pulumi

destroy_one() {
  local dir="$1"
  echo "==> pulumi destroy (${dir}, stack=${STACK})"
  (
    cd "${ROOT}/${dir}"
    if ! pulumi stack select "${STACK}" 2>/dev/null; then
      echo "skip: no stack ${STACK} in ${dir}"
      return 0
    fi
    if ! pulumi destroy --yes; then
      echo "error: destroy failed for ${dir} — fix Azure/Pulumi state before retrying" >&2
      return 1
    fi
  )
}

case "${TARGET}" in
  primary)  destroy_one infra/primary ;;
  standby)  destroy_one infra/standby-aks ;;
  shared)   destroy_one infra/shared ;;
  vpn)      destroy_one infra/vpn-gateways ;;
  flux)     destroy_one infra/flux-bootstrap ;;
  all)
    # Tear down dependents first. flux-bootstrap only removes Helm release;
    # cluster deletion (primary/standby) removes in-cluster Flux anyway.
    destroy_one infra/vpn-gateways
    destroy_one infra/shared
    destroy_one infra/flux-bootstrap || true
    destroy_one infra/standby-aks
    destroy_one infra/primary
    ;;
  *)
    echo "usage: $0 primary|standby|shared|vpn|flux|all" >&2
    echo "env: PULUMI_STACK (default: dev)" >&2
    exit 1
    ;;
esac

echo "Done. Verify in Azure Portal that resource groups are gone (and delete talos-images RG if you registered a gallery image)."
