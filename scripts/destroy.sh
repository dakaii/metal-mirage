#!/usr/bin/env bash
# Destroy stacks to stop billing: primary | standby | shared | vpn | flux | all
# primary/standby dirs come from config/clusters.yaml (provisioner switch).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "${ROOT}/scripts/lib.sh"
TARGET="${1:-all}"
STACK="${PULUMI_STACK:-dev}"

need pulumi "Install: https://www.pulumi.com/docs/install/"

destroy_one() {
  local dir="$1"
  local stack="${2:-${STACK}}"
  echo "==> pulumi destroy (${dir}, stack=${stack})"
  (
    cd "${ROOT}/${dir}"
    if ! pulumi stack select "${stack}" 2>/dev/null; then
      echo "skip: no stack ${stack} in ${dir}"
      return 0
    fi
    if ! pulumi destroy --yes; then
      echo "error: destroy failed for ${dir} (stack=${stack}) — fix cloud/Pulumi state before retrying" >&2
      return 1
    fi
  )
}

# up.sh uses STACK for primary Flux and ${STACK}-standby for standby Flux.
destroy_flux() {
  destroy_one infra/flux-bootstrap "${STACK}" || true
  destroy_one infra/flux-bootstrap "${STACK}-standby" || true
}

primary_dir() {
  resolve_pulumi_dir primary
}

standby_dir() {
  resolve_pulumi_dir standby
}

case "${TARGET}" in
  primary)  destroy_one "$(primary_dir)" ;;
  standby)  destroy_one "$(standby_dir)" ;;
  shared)   destroy_one infra/shared ;;
  vpn | remote_access)
    dir="$(resolve_pulumi_dir vpn)"
    if [[ -z "${dir}" ]]; then
      # provider=none still may have leftover stacks — try default adapter dir.
      dir="infra/vpn-gateways"
    fi
    destroy_one "${dir}"
    ;;
  flux)     destroy_flux ;;
  all)
    # Tear down dependents first. flux-bootstrap only removes Helm release;
    # cluster deletion (primary/standby) removes in-cluster Flux anyway.
    ra_dir="$(resolve_pulumi_dir vpn)"
    if [[ -z "${ra_dir}" ]]; then
      # provider=none: still attempt default adapter dir so leftover stacks are not stranded.
      ra_dir="infra/vpn-gateways"
    fi
    destroy_one "${ra_dir}"
    destroy_one infra/shared
    destroy_flux
    destroy_one "$(standby_dir)"
    destroy_one "$(primary_dir)"
    # If switching provisioners, also try the sibling primary stack so leftover
    # Azure metal-sim spend is not stranded when clusters.yaml already points at bare-metal.
    if [[ "$(primary_dir)" == "infra/bare-metal" ]]; then
      destroy_one infra/primary || true
    elif [[ "$(primary_dir)" == "infra/primary" ]]; then
      destroy_one infra/bare-metal || true
    fi
    ;;
  *)
    echo "usage: $0 primary|standby|shared|vpn|remote_access|flux|all" >&2
    echo "env: PULUMI_STACK (default: dev)" >&2
    exit 1
    ;;
esac

echo "Done. Verify in Azure Portal that resource groups are gone (and delete talos-images RG if you registered a gallery image)."
