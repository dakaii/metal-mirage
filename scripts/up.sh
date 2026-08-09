#!/usr/bin/env bash
# Bring up a stack: primary | standby | shared | vpn | all
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="${1:-primary}"

up_one() {
  local dir="$1"
  local stack="${2:-dev}"
  echo "==> pulumi up (${dir})"
  (
    cd "${ROOT}/${dir}"
    if [[ ! -f go.mod ]]; then
      echo "missing go.mod in ${dir}" >&2
      exit 1
    fi
    pulumi stack select "${stack}" 2>/dev/null || pulumi stack init "${stack}"
    pulumi up --yes
  )
}

case "${TARGET}" in
  primary)  up_one infra/primary ;;
  standby)  up_one infra/standby-aks ;;
  shared)   up_one infra/shared ;;
  vpn)      up_one infra/vpn-gateways ;;
  all)
    up_one infra/primary
    up_one infra/standby-aks
    # Wire shared from primary/standby outputs when present.
    # Traffic Manager must target the ingress PIP (HTTP/S demo), not the Talos API PIP.
    if command -v pulumi >/dev/null; then
      PRIMARY_INGRESS="$(cd "${ROOT}/infra/primary" && pulumi stack output ingressIP 2>/dev/null || true)"
      PRIMARY_API="$(cd "${ROOT}/infra/primary" && pulumi stack output clusterEndpoint 2>/dev/null || true)"
      STANDBY_FQDN="$(cd "${ROOT}/infra/standby-aks" && pulumi stack output aksFqdn 2>/dev/null || true)"
      if [[ -n "${PRIMARY_INGRESS}" ]]; then
        (
          cd "${ROOT}/infra/shared"
          pulumi stack select dev 2>/dev/null || pulumi stack init dev
          pulumi config set shared:primaryIngressIP "${PRIMARY_INGRESS}"
          [[ -n "${PRIMARY_API}" ]] && pulumi config set shared:primaryAPIURL "${PRIMARY_API}/readyz"
          [[ -n "${STANDBY_FQDN}" ]] && pulumi config set shared:standbyFQDN "${STANDBY_FQDN}"
        )
      fi
    fi
    up_one infra/shared
    up_one infra/vpn-gateways
    ;;
  *)
    echo "usage: $0 primary|standby|shared|vpn|all" >&2
    exit 1
    ;;
esac
