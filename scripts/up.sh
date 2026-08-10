#!/usr/bin/env bash
# Bring up a stack: primary | standby | shared | vpn | all
# primary/standby dirs come from config/clusters.yaml (provisioner switch).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "${ROOT}/scripts/lib.sh"
TARGET="${1:-primary}"
STACK="${PULUMI_STACK:-dev}"

# RemoteAccess disabled: allow a no-op without Pulumi installed.
if [[ "${TARGET}" == "vpn" || "${TARGET}" == "remote_access" ]]; then
  if [[ "$(remote_access_provider)" == "none" ]]; then
    echo "==> remote_access.provider=none — skipping WireGuard adapter (RemoteAccess port disabled)"
    echo "Done (${TARGET}). Platform-only mode; see docs/CAPABILITY-PORTS.md."
    exit 0
  fi
fi

need pulumi "Install: https://www.pulumi.com/docs/install/"
need go "Need Go 1.26.x (matches CI / infra go.mod). See AGENTS.md."
# shellcheck source=scripts/lib-azure-vm.sh
source "${ROOT}/scripts/lib-azure-vm.sh"

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

# For azure-metal-sim: probe quota/SKU and set primary:vmSize so operators
# do not have to discover Standard_B2s capacity misses by hand.
# Skip when PRIMARY_VM_SIZE is set, SKIP_AZURE_VM_SIZE_AUTO=1, or an explicit
# non-default vmSize is already configured (unless FORCE_AZURE_VM_SIZE_AUTO=1).
ensure_azure_metal_sim_vm_size() {
  local dir loc current size cp_n w_n cores
  dir="$(primary_dir)"
  if [[ ! -d "${ROOT}/${dir}" ]]; then
    return 0
  fi
  if [[ "${SKIP_AZURE_VM_SIZE_AUTO:-0}" == "1" ]]; then
    echo "==> SKIP_AZURE_VM_SIZE_AUTO=1 — leaving primary:vmSize unchanged"
    return 0
  fi
  if ! command -v az >/dev/null 2>&1 || ! az account show >/dev/null 2>&1; then
    echo "==> az not ready — skip VM size auto-select (set primary:vmSize manually if up fails)"
    return 0
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    echo "==> python3 missing — skip VM size auto-select"
    return 0
  fi

  (
    cd "${ROOT}/${dir}"
    pulumi stack select "${STACK}" 2>/dev/null || pulumi stack init "${STACK}"
  )

  loc="$(pulumi -C "${ROOT}/${dir}" config get azure-native:location 2>/dev/null || true)"
  loc="${loc:-eastus}"
  current="$(pulumi -C "${ROOT}/${dir}" config get primary:vmSize 2>/dev/null || true)"

  if [[ -n "${PRIMARY_VM_SIZE:-}" ]]; then
    echo "==> PRIMARY_VM_SIZE=${PRIMARY_VM_SIZE} — setting primary:vmSize"
    pulumi -C "${ROOT}/${dir}" config set primary:vmSize "${PRIMARY_VM_SIZE}"
    return 0
  fi

  if [[ -n "${current}" && "${current}" != "Standard_B2s" && "${FORCE_AZURE_VM_SIZE_AUTO:-0}" != "1" ]]; then
    echo "==> keeping primary:vmSize=${current} (set FORCE_AZURE_VM_SIZE_AUTO=1 to re-probe)"
    return 0
  fi

  cp_n="$(pulumi -C "${ROOT}/${dir}" config get primary:controlPlaneCount 2>/dev/null || true)"
  w_n="$(pulumi -C "${ROOT}/${dir}" config get primary:workerCount 2>/dev/null || true)"
  cp_n="${cp_n:-1}"
  w_n="${w_n:-1}"
  cores=$((2 * (cp_n + w_n)))

  echo "==> Auto-selecting primary:vmSize in ${loc} (need ~${cores} vCPUs for ${cp_n} cp + ${w_n} workers)"
  if ! size="$(pick_azure_vm_size "${loc}" "${current}" "${cores}")"; then
    echo "error: no Azure VM size with enough quota/capacity in ${loc}" >&2
    echo "  Try: az vm list-usage -l ${loc} -o table" >&2
    echo "  Or:  PRIMARY_VM_SIZE=Standard_D2s_v4 ./scripts/up.sh primary" >&2
    echo "  Or:  raise Compute quota / lower controlPlaneCount+workerCount" >&2
    exit 1
  fi
  echo "==> primary:vmSize → ${size}"
  pulumi -C "${ROOT}/${dir}" config set primary:vmSize "${size}"
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

vpn_dir() {
  resolve_pulumi_dir vpn
}

case "${TARGET}" in
  primary)
    # bare-metal: config/clusters.yaml is SoT — sync into Pulumi before up.
    if [[ "$(yaml_section_key primary provisioner | tr -d '[:space:]')" == "bare-metal" ]]; then
      "${ROOT}/scripts/sync-baremetal-config.sh"
    elif [[ "$(yaml_section_key primary provisioner | tr -d '[:space:]')" == "azure-metal-sim" ]]; then
      ensure_azure_metal_sim_vm_size
    fi
    up_one "$(primary_dir)"
    ;;
  standby)
    up_one "$(standby_dir)"
    ;;
  shared)
    wire_shared_from_outputs
    up_one infra/shared
    ;;
  vpn | remote_access)
    # none already handled above (before need pulumi)
    dir="$(vpn_dir)"
    if [[ -z "${dir}" ]]; then
      echo "remote_access.pulumi_dir unresolved — set remote_access.pulumi_dir in config/clusters.yaml" >&2
      exit 1
    fi
    up_one "${dir}"
    ;;
  all)
    if [[ "$(yaml_section_key primary provisioner | tr -d '[:space:]')" == "bare-metal" ]]; then
      "${ROOT}/scripts/sync-baremetal-config.sh"
    elif [[ "$(yaml_section_key primary provisioner | tr -d '[:space:]')" == "azure-metal-sim" ]]; then
      ensure_azure_metal_sim_vm_size
    fi
    up_one "$(primary_dir)"
    up_one "$(standby_dir)"
    wire_shared_from_outputs
    up_one infra/shared
    if [[ "$(remote_access_provider)" == "none" ]]; then
      echo "==> remote_access.provider=none — skipping WireGuard adapter"
    else
      dir="$(vpn_dir)"
      if [[ -z "${dir}" ]]; then
        echo "remote_access.pulumi_dir unresolved — set remote_access.pulumi_dir in config/clusters.yaml" >&2
        exit 1
      fi
      up_one "${dir}"
    fi
    ;;
  *)
    echo "usage: $0 primary|standby|shared|vpn|remote_access|all" >&2
    echo "env: PULUMI_STACK (default: dev)" >&2
    echo "      PRIMARY_VM_SIZE / FORCE_AZURE_VM_SIZE_AUTO / SKIP_AZURE_VM_SIZE_AUTO (azure-metal-sim)" >&2
    echo "primary dir follows config/clusters.yaml (azure-metal-sim → infra/primary, bare-metal → infra/bare-metal)" >&2
    echo "remote_access.provider=wireguard|none selects the optional RemoteAccess adapter" >&2
    exit 1
    ;;
esac

echo "Done (${TARGET}). See docs/DEPLOY.md for Flux / witness / VPN next steps."
