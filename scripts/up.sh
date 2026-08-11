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

# Ensure primary:adminCidr allows Talos apid (:50000) from the operator laptop.
# Azure metal-sim lab default is 0.0.0.0/0 — residential CGNAT often jumps
# across /24s mid-Bootstrap (e.g. 187.15.98.0/24 → 187.15.91.0/24).
# Tighten: ADMIN_CIDR=x.x.x.x/32| /24, or ADMIN_CIDR_PREFIX_LEN=24|32.
# Skip: SKIP_ADMIN_CIDR_AUTO=1.
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

  # Opt-in host/subnet lock (requires curl).
  if [[ -n "${ADMIN_CIDR_PREFIX_LEN:-}" ]]; then
    if ! command -v curl >/dev/null 2>&1; then
      echo "==> curl missing — cannot honor ADMIN_CIDR_PREFIX_LEN=${ADMIN_CIDR_PREFIX_LEN}" >&2
      return 0
    fi
    prefix="${ADMIN_CIDR_PREFIX_LEN}"
    if ! now="$(detect_admin_cidr "${prefix}")"; then
      echo "==> could not detect public IP — leave primary:adminCidr unchanged" >&2
      return 0
    fi
    if [[ "${current}" == "${now}" ]]; then
      echo "==> primary:adminCidr already ${now}"
      return 0
    fi
    if [[ -n "${current}" ]]; then
      echo "==> primary:adminCidr ${current} → ${now} (ADMIN_CIDR_PREFIX_LEN=${prefix})"
    else
      echo "==> primary:adminCidr → ${now}"
    fi
    pulumi -C "${ROOT}/${dir}" config set primary:adminCidr "${now}"
    return 0
  fi

  # Lab default: wide open (CGNAT-safe). Intentional locks via ADMIN_CIDR=… stick
  # only when SKIP_ADMIN_CIDR_AUTO=1; otherwise we open so Bootstrap can dial.
  now="0.0.0.0/0"
  if [[ "${current}" == "${now}" ]]; then
    echo "==> primary:adminCidr already ${now} (lab default; set ADMIN_CIDR=… or ADMIN_CIDR_PREFIX_LEN=24|32 to lock)"
    return 0
  fi
  if [[ -n "${current}" ]]; then
    echo "==> primary:adminCidr ${current} → ${now} (azure-metal-sim lab default; CGNAT-safe)"
  else
    echo "==> primary:adminCidr → ${now} (azure-metal-sim lab default)"
  fi
  pulumi -C "${ROOT}/${dir}" config set primary:adminCidr "${now}"
}

# After adminCidr refresh: if the API PIP exists, warn when :50000 is blocked
# so operators notice before a 10m Bootstrap dial. Never hard-fail here — NSG
# rule updates only apply inside the upcoming `pulumi up`.
# Skip: SKIP_TALOS_APID_PREFLIGHT=1.
preflight_azure_metal_sim_talos_apid() {
  local dir api admin
  dir="$(primary_dir)"
  if [[ "${SKIP_TALOS_APID_PREFLIGHT:-0}" == "1" ]]; then
    return 0
  fi
  if [[ ! -d "${ROOT}/${dir}" ]]; then
    return 0
  fi
  api="$(pulumi -C "${ROOT}/${dir}" stack output apiLoadBalancerIP 2>/dev/null || true)"
  if [[ -z "${api}" || "${api}" == "null" ]]; then
    return 0
  fi
  admin="$(pulumi -C "${ROOT}/${dir}" config get primary:adminCidr 2>/dev/null || true)"
  echo "==> preflight Talos apid ${api}:50000 (adminCidr=${admin:-unset})"
  if ! command -v nc >/dev/null 2>&1; then
    echo "==> nc missing — skip apid preflight"
    return 0
  fi
  if nc -z -w 5 "${api}" 50000 >/dev/null 2>&1; then
    echo "==> ${api}:50000 reachable"
    return 0
  fi
  if nc -z -w 5 "${api}" 6443 >/dev/null 2>&1; then
    echo "warn: ${api}:6443 open but :50000 blocked — NSG/adminCidr likely stale until this up applies" >&2
  else
    echo "warn: ${api}:50000 unreachable (:6443 also closed — node may be down/rebooting, or NSG still stale)" >&2
  fi
  echo "  Lab open: adminCidr should be 0.0.0.0/0 for CGNAT; continuing into pulumi up" >&2
  return 0
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
      preflight_azure_metal_sim_talos_apid
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
      preflight_azure_metal_sim_talos_apid
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
    echo "      SKIP_TALOS_APID_PREFLIGHT (azure-metal-sim :50000 check)" >&2
    echo "primary dir follows config/clusters.yaml (azure-metal-sim → infra/primary, bare-metal → infra/bare-metal)" >&2
    echo "remote_access.provider=wireguard|none selects the optional RemoteAccess adapter" >&2
    exit 1
    ;;
esac

echo "Done (${TARGET}). See docs/DEPLOY.md for Flux / witness / VPN next steps."
