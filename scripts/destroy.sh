#!/usr/bin/env bash
# Destroy stacks to stop billing: primary | standby | shared | vpn | all
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="${1:-all}"

destroy_one() {
  local dir="$1"
  echo "==> pulumi destroy (${dir})"
  (
    cd "${ROOT}/${dir}"
    pulumi stack select dev 2>/dev/null || return 0
    pulumi destroy --yes || true
  )
}

case "${TARGET}" in
  primary)  destroy_one infra/primary ;;
  standby)  destroy_one infra/standby-aks ;;
  shared)   destroy_one infra/shared ;;
  vpn)      destroy_one infra/vpn-gateways ;;
  all)
    destroy_one infra/vpn-gateways
    destroy_one infra/shared
    destroy_one infra/standby-aks
    destroy_one infra/primary
    ;;
  *)
    echo "usage: $0 primary|standby|shared|vpn|all" >&2
    exit 1
    ;;
esac

echo "Done. Verify in Azure Portal that resource groups are gone."
