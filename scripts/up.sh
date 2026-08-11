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
  if ! [[ "${cp_n}" =~ ^[0-9]+$ && "${w_n}" =~ ^[0-9]+$ ]]; then
    echo "error: primary:controlPlaneCount/workerCount must be integers (got cp=${cp_n} workers=${w_n})" >&2
    exit 1
  fi
  # Candidate SKUs are 2-vCPU; scale by node count.
  cores=$(($(azure_vm_size_cores Standard_D2s_v4) * (cp_n + w_n)))

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

# Refresh primary:adminCidr from the operator's current public IP so Talos
# apid (:50000) NSG rules stay reachable when the laptop IP drifts.
# Azure metal-sim defaults to /24 (CGNAT last-octet flaps mid-Bootstrap).
# Override: ADMIN_CIDR=…, ADMIN_CIDR_PREFIX_LEN=32, or SKIP_ADMIN_CIDR_AUTO=1.
ensure_azure_metal_sim_admin_cidr() {
  local dir current now prefix
  dir="$(primary_dir)"
  if [[ ! -d "${ROOT}/${dir}" ]]; then
    return 0
  fi
  if [[ "${SKIP_ADMIN_CIDR_AUTO:-0}" == "1" ]]; then
    echo "==> SKIP_ADMIN_CIDR_AUTO=1 — leaving primary:adminCidr unchanged"
    return 0
  fi
  if ! command -v curl >/dev/null 2>&1; then
    echo "==> curl missing — skip adminCidr refresh"
    return 0
  fi

  (
    cd "${ROOT}/${dir}"
    pulumi stack select "${STACK}" 2>/dev/null || pulumi stack init "${STACK}"
  )

  if [[ -n "${ADMIN_CIDR:-}" ]]; then
    echo "==> ADMIN_CIDR=${ADMIN_CIDR} — setting primary:adminCidr"
    pulumi -C "${ROOT}/${dir}" config set primary:adminCidr "${ADMIN_CIDR}"
    return 0
  fi

  current="$(pulumi -C "${ROOT}/${dir}" config get primary:adminCidr 2>/dev/null || true)"
  # Do not shrink an intentional wide-open lab allowlist.
  if [[ "${current}" == "0.0.0.0/0" ]]; then
    echo "==> primary:adminCidr is 0.0.0.0/0 — leaving open (set ADMIN_CIDR=… to lock, or SKIP_ADMIN_CIDR_AUTO=1)"
    return 0
  fi

  # Lab default /24: ISP CGNAT often rotates .176/.178/.179 during a 10m dial.
  prefix="${ADMIN_CIDR_PREFIX_LEN:-24}"
  if ! now="$(detect_admin_cidr "${prefix}")"; then
    echo "==> could not detect public IP — leave primary:adminCidr unchanged" >&2
    echo "  Set ADMIN_CIDR=x.x.x.x/32 or: pulumi -C ${dir} config set primary:adminCidr …" >&2
    return 0
  fi
  if [[ "${current}" == "${now}" ]]; then
    echo "==> primary:adminCidr already ${now}"
    return 0
  fi
  if [[ -n "${current}" ]]; then
    echo "==> primary:adminCidr ${current} → ${now} (public IP / prefix refresh)"
  else
    echo "==> primary:adminCidr → ${now}"
  fi
  pulumi -C "${ROOT}/${dir}" config set primary:adminCidr "${now}"
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

PRIMARY_PROVISIONER="$(yaml_section_key primary provisioner | tr -d '[:space:]')"

case "${TARGET}" in
  primary)
    # bare-metal: config/clusters.yaml is SoT — sync into Pulumi before up.
    if [[ "${PRIMARY_PROVISIONER}" == "bare-metal" ]]; then
      "${ROOT}/scripts/sync-baremetal-config.sh"
    elif [[ "${PRIMARY_PROVISIONER}" == "azure-metal-sim" ]]; then
      ensure_azure_metal_sim_admin_cidr
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
    if [[ "${PRIMARY_PROVISIONER}" == "bare-metal" ]]; then
      "${ROOT}/scripts/sync-baremetal-config.sh"
    elif [[ "${PRIMARY_PROVISIONER}" == "azure-metal-sim" ]]; then
      ensure_azure_metal_sim_admin_cidr
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
    echo "      ADMIN_CIDR / ADMIN_CIDR_PREFIX_LEN / SKIP_ADMIN_CIDR_AUTO (azure-metal-sim NSG)" >&2
    echo "primary dir follows config/clusters.yaml (azure-metal-sim → infra/primary, bare-metal → infra/bare-metal)" >&2
    echo "remote_access.provider=wireguard|none selects the optional RemoteAccess adapter" >&2
    exit 1
    ;;
esac

echo "Done (${TARGET}). See docs/DEPLOY.md for Flux / witness / VPN next steps."
