#!/usr/bin/env bash
# Bring up a stack: primary | standby | shared | vpn | all
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="${1:-primary}"
STACK="${PULUMI_STACK:-dev}"

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required tool: $1" >&2
    exit 1
  }
}

need pulumi
need go

up_one() {
  local dir="$1"
  echo "==> pulumi up (${dir}, stack=${STACK})"
  (
    cd "${ROOT}/${dir}"
    if [[ ! -f go.mod ]]; then
      echo "missing go.mod in ${dir}" >&2
      exit 1
    fi
    pulumi stack select "${STACK}" 2>/dev/null || pulumi stack init "${STACK}"
    pulumi up --yes
  )
}

wire_shared_from_outputs() {
  local primary_ingress primary_api standby_fqdn
  primary_ingress="$(cd "${ROOT}/infra/primary" && pulumi stack select "${STACK}" >/dev/null 2>&1 && pulumi stack output ingressIP 2>/dev/null || true)"
  primary_api="$(cd "${ROOT}/infra/primary" && pulumi stack select "${STACK}" >/dev/null 2>&1 && pulumi stack output clusterEndpoint 2>/dev/null || true)"
  standby_fqdn="$(cd "${ROOT}/infra/standby-aks" && pulumi stack select "${STACK}" >/dev/null 2>&1 && pulumi stack output aksFqdn 2>/dev/null || true)"

  if [[ -z "${primary_ingress}" ]]; then
    echo "warn: primary ingressIP not available; set shared:primaryIngressIP manually" >&2
    return 0
  fi

  echo "==> wiring shared stack from primary/standby outputs"
  (
    cd "${ROOT}/infra/shared"
    pulumi stack select "${STACK}" 2>/dev/null || pulumi stack init "${STACK}"
    # Traffic Manager must target the ingress PIP (HTTP demo), not the Talos API PIP.
    pulumi config set shared:primaryIngressIP "${primary_ingress}"
    if [[ -n "${primary_api}" ]]; then
      pulumi config set shared:primaryAPIURL "${primary_api}/readyz"
    fi
    if [[ -n "${standby_fqdn}" ]]; then
      pulumi config set shared:standbyFQDN "${standby_fqdn}"
    fi
  )
}

case "${TARGET}" in
  primary)
    up_one infra/primary
    ;;
  standby)
    up_one infra/standby-aks
    ;;
  shared)
    wire_shared_from_outputs
    up_one infra/shared
    ;;
  vpn)
    up_one infra/vpn-gateways
    ;;
  all)
    up_one infra/primary
    up_one infra/standby-aks
    wire_shared_from_outputs
    up_one infra/shared
    up_one infra/vpn-gateways
    ;;
  *)
    echo "usage: $0 primary|standby|shared|vpn|all" >&2
    echo "env: PULUMI_STACK (default: dev)" >&2
    exit 1
    ;;
esac

echo "Done (${TARGET}). See docs/DEPLOY.md for Flux / witness / VPN next steps."
