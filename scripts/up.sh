#!/usr/bin/env bash
# Bring up a stack: primary | standby | shared | vpn | all
# primary/standby dirs come from config/clusters.yaml (provisioner switch).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "${ROOT}/scripts/lib.sh"
TARGET="${1:-primary}"
STACK="${PULUMI_STACK:-dev}"

need pulumi "Install: https://www.pulumi.com/docs/install/"
need go "Need Go 1.26.x (matches CI / infra go.mod). See AGENTS.md."

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

primary_dir() {
  resolve_pulumi_dir primary
}

standby_dir() {
  resolve_pulumi_dir standby
}

wire_shared_from_outputs() {
  local primary_ingress primary_api standby_fqdn pdir sdir
  pdir="$(primary_dir)"
  sdir="$(standby_dir)"
  primary_ingress="$(stack_output "${pdir}" ingressIP)"
  primary_api="$(stack_output "${pdir}" clusterEndpoint)"
  standby_fqdn="$(stack_output "${sdir}" aksFqdn)"

  if [[ -z "${primary_ingress}" || "${primary_ingress}" == "null" ]]; then
    echo "error: primary ingressIP not available from ${pdir} (stack=${STACK})" >&2
    echo "  Bring up primary first: ./scripts/up.sh primary" >&2
    echo "  Or set manually: pulumi -C infra/shared config set shared:primaryIngressIP <ip>" >&2
    exit 1
  fi
  if [[ -z "${primary_api}" || "${primary_api}" == "null" ]]; then
    echo "warn: primary clusterEndpoint missing — witness primaryAPIURL will not be wired" >&2
    echo "  Set later: pulumi -C infra/shared config set shared:primaryAPIURL 'https://<api-ip>:6443/readyz'" >&2
  fi
  if [[ -z "${standby_fqdn}" || "${standby_fqdn}" == "null" ]]; then
    echo "warn: standby aksFqdn missing — Traffic Manager priority-2 endpoint will not be wired" >&2
    echo "  Bring up standby first (./scripts/up.sh standby) or set shared:standbyFQDN manually" >&2
  fi

  echo "==> wiring shared stack from primary/standby outputs (${pdir})"
  (
    cd "${ROOT}/infra/shared"
    pulumi stack select "${STACK}" 2>/dev/null || pulumi stack init "${STACK}"
    # Traffic Manager must target the ingress PIP (HTTP demo), not the Talos API PIP.
    pulumi config set shared:primaryIngressIP "${primary_ingress}"
    if [[ -n "${primary_api}" && "${primary_api}" != "null" ]]; then
      pulumi config set shared:primaryAPIURL "${primary_api}/readyz"
    fi
    if [[ -n "${standby_fqdn}" && "${standby_fqdn}" != "null" ]]; then
      pulumi config set shared:standbyFQDN "${standby_fqdn}"
    fi
  )
}

case "${TARGET}" in
  primary)
    up_one "$(primary_dir)"
    ;;
  standby)
    up_one "$(standby_dir)"
    ;;
  shared)
    wire_shared_from_outputs
    up_one infra/shared
    ;;
  vpn)
    up_one infra/vpn-gateways
    ;;
  all)
    up_one "$(primary_dir)"
    up_one "$(standby_dir)"
    wire_shared_from_outputs
    up_one infra/shared
    up_one infra/vpn-gateways
    ;;
  *)
    echo "usage: $0 primary|standby|shared|vpn|all" >&2
    echo "env: PULUMI_STACK (default: dev)" >&2
    echo "primary dir follows config/clusters.yaml (azure-metal-sim → infra/primary, bare-metal → infra/bare-metal)" >&2
    exit 1
    ;;
esac

echo "Done (${TARGET}). See docs/DEPLOY.md for Flux / witness / VPN next steps."
