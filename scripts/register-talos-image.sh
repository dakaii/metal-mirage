#!/usr/bin/env bash
# Register a Talos Linux VHD as an Azure shared image (one-time per region).
#
# Usage:
#   ./scripts/register-talos-image.sh [--in-azure] [location] [talos-version]
#
# Modes:
#   (default)   Download + decompress on this machine, then upload to Azure.
#   --in-azure  Spin up a short-lived helper VM in Azure to download/decompress/
#               upload (keeps the multi-GB VHD off your laptop). Helper RG is
#               deleted when finished.
#
# Azure VHDs are no longer published on GitHub Releases. Downloads come from
# Talos Image Factory (https://factory.talos.dev) by default.
#
# Env:
#   TALOS_SCHEMATIC_ID     Image Factory schematic (default: empty/vanilla)
#   TALOS_IMAGE_URL        Full URL override for azure-amd64.vhd.xz
#   TALOS_IMAGE_RG         Gallery / storage resource group (default: talos-images)
#   TALOS_IMAGE_GALLERY    Gallery name (default: talosgallery)
#   TALOS_IMAGE_DEF        Image definition (default: talos)
#   TALOS_HELPER_VM_SIZE   Prefer this helper VM size first (--in-azure)
#   TALOS_HELPER_VM_SIZES  Space-separated fallback list (overrides built-in list)
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./scripts/register-talos-image.sh [--in-azure] [location] [talos-version]

  --in-azure   Download/decompress/upload inside a temporary Azure VM
               (recommended on laptops — avoids a multi-GB local copy).

Env: TALOS_SCHEMATIC_ID, TALOS_IMAGE_URL, TALOS_IMAGE_RG,
     TALOS_HELPER_VM_SIZE, TALOS_HELPER_VM_SIZES
EOF
}

IN_AZURE=0
POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    --in-azure)
      IN_AZURE=1
      shift
      ;;
    -*)
      echo "unknown flag: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      POSITIONAL+=("$1")
      shift
      ;;
  esac
done

LOCATION="${POSITIONAL[0]:-eastus}"
TALOS_VERSION="${POSITIONAL[1]:-v1.9.5}"
RG="${TALOS_IMAGE_RG:-talos-images}"
GALLERY="${TALOS_IMAGE_GALLERY:-talosgallery}"
IMAGE_DEF="${TALOS_IMAGE_DEF:-talos}"
IMAGE_VERSION="${TALOS_VERSION#v}"
HELPER_RG="${RG}-helper"
HELPER_VM="talos-vhd-helper"

# Empty (vanilla) schematic — official Image Factory ID for no extensions.
# Customize at https://factory.talos.dev if you need system extensions.
SCHEMATIC_ID="${TALOS_SCHEMATIC_ID:-376567988ad370138ad8b2698212367b8edcb69b5fd68c80be1f2ec7d603b4ba}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/lib-azure-vm.sh
source "${ROOT}/scripts/lib-azure-vm.sh"

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required tool: $1" >&2
    exit 1
  }
}

utc_expiry_hours() {
  # Portable SAS expiry (macOS date lacks -d).
  local hours="${1:-6}"
  if command -v python3 >/dev/null 2>&1; then
    python3 -c "from datetime import datetime, timedelta, timezone; print((datetime.now(timezone.utc)+timedelta(hours=${hours})).strftime('%Y-%m-%dT%H:%MZ'))"
  else
    # GNU date fallback
    date -u -d "+${hours} hours" +%Y-%m-%dT%H:%MZ
  fi
}

need az

if ! az account show >/dev/null 2>&1; then
  echo "az not logged in — run: ./scripts/login.sh --force --local-pulumi  (or az login)" >&2
  exit 1
fi

if [[ -n "${TALOS_IMAGE_URL:-}" ]]; then
  VHD_URL="${TALOS_IMAGE_URL}"
else
  VHD_URL="https://factory.talos.dev/image/${SCHEMATIC_ID}/${TALOS_VERSION}/azure-amd64.vhd.xz"
fi

BLOB_NAME="talos-${TALOS_VERSION}.vhd"
SA="talosimg${LOCATION}"
SA="${SA//-/}"
SA="$(echo "${SA}" | tr '[:upper:]' '[:lower:]' | cut -c1-24)"

echo "==> Ensuring resource group ${RG} in ${LOCATION}"
az group create --name "${RG}" --location "${LOCATION}" --output none

echo "==> Ensuring gallery ${GALLERY}"
az sig create --resource-group "${RG}" --gallery-name "${GALLERY}" --location "${LOCATION}" --output none 2>/dev/null || true

echo "==> Ensuring image definition ${IMAGE_DEF}"
az sig image-definition create \
  --resource-group "${RG}" \
  --gallery-name "${GALLERY}" \
  --gallery-image-definition "${IMAGE_DEF}" \
  --publisher siderolabs \
  --offer talos \
  --sku "${TALOS_VERSION}" \
  --os-type Linux \
  --os-state generalized \
  --hyper-v-generation V2 \
  --location "${LOCATION}" \
  --output none 2>/dev/null || true

echo "==> Ensuring storage account ${SA}"
az storage account create \
  --name "${SA}" \
  --resource-group "${RG}" \
  --location "${LOCATION}" \
  --sku Standard_LRS \
  --kind StorageV2 \
  --output none 2>/dev/null || true

# Account key works for SAS + blob ops without AAD role assignment races.
SA_KEY="$(az storage account keys list \
  --resource-group "${RG}" \
  --account-name "${SA}" \
  --query '[0].value' -o tsv)"

az storage container create \
  --account-name "${SA}" \
  --account-key "${SA_KEY}" \
  --name vhds \
  --output none 2>/dev/null || true

BLOB_URL="$(az storage blob url \
  --account-name "${SA}" \
  --account-key "${SA_KEY}" \
  --container-name vhds \
  --name "${BLOB_NAME}" \
  --output tsv)"

upload_local() {
  need curl
  need xz

  local workdir="${ROOT}/.secrets/talos-image-${LOCATION}"
  mkdir -p "${workdir}"
  local vhd_xz="${workdir}/azure-amd64.vhd.xz"
  local vhd="${workdir}/azure-amd64.vhd"

  if [[ ! -f "${vhd}" ]]; then
    echo "==> Downloading ${VHD_URL} (local)"
    if ! curl -fsSL -o "${vhd_xz}" "${VHD_URL}"; then
      echo "download failed. Azure VHDs come from Image Factory (not GitHub Releases)." >&2
      echo "  URL: ${VHD_URL}" >&2
      echo "  Override: TALOS_IMAGE_URL=... or TALOS_SCHEMATIC_ID=... (https://factory.talos.dev)" >&2
      exit 1
    fi
    if ! xz -t "${vhd_xz}" 2>/dev/null; then
      echo "downloaded file is not a valid xz archive: ${VHD_URL}" >&2
      rm -f "${vhd_xz}"
      exit 1
    fi
    echo "==> Decompressing VHD (this takes a while)"
    xz -dkf "${vhd_xz}"
  fi

  echo "==> Uploading VHD from this machine (azcopy or az storage)"
  if command -v azcopy >/dev/null 2>&1; then
    local sas expiry dest
    expiry="$(utc_expiry_hours 6)"
    sas="$(az storage container generate-sas \
      --account-name "${SA}" \
      --account-key "${SA_KEY}" \
      --name vhds \
      --permissions rwc \
      --expiry "${expiry}" \
      -o tsv)"
    dest="${BLOB_URL}?${sas}"
    azcopy copy "${vhd}" "${dest}" --blob-type PageBlob
  else
    echo "azcopy not found; using az storage blob upload (slower)"
    az storage blob upload \
      --account-name "${SA}" \
      --account-key "${SA_KEY}" \
      --container-name vhds \
      --name "${BLOB_NAME}" \
      --file "${vhd}" \
      --type page \
      --overwrite true
  fi
}

upload_in_azure() {
  local expiry sas dest_with_sas
  expiry="$(utc_expiry_hours 8)"
  sas="$(az storage container generate-sas \
    --account-name "${SA}" \
    --account-key "${SA_KEY}" \
    --name vhds \
    --permissions rwc \
    --expiry "${expiry}" \
    -o tsv)"
  dest_with_sas="${BLOB_URL}?${sas}"

  echo "==> Creating helper resource group ${HELPER_RG}"
  if ! az group create --name "${HELPER_RG}" --location "${LOCATION}" --output none 2>/tmp/talos-helper-rg.err; then
    if grep -qi 'ResourceGroupBeingDeleted' /tmp/talos-helper-rg.err; then
      echo "helper RG ${HELPER_RG} is still deleting — wait then retry:" >&2
      echo "  az group wait --deleted --resource-group ${HELPER_RG}" >&2
    fi
    cat /tmp/talos-helper-rg.err >&2
    exit 1
  fi

  cleanup_helper() {
    echo "==> Deleting helper resource group ${HELPER_RG}"
    az group delete --name "${HELPER_RG}" --yes --no-wait 2>/dev/null || true
  }
  trap cleanup_helper EXIT

  # Probe quota/SKU first, then try-create (capacity restrictions are not always
  # visible in list-skus — keep create fallback).
  local sizes=() size chosen="" err reason probed=""
  err="$(mktemp)"
  if [[ -n "${TALOS_HELPER_VM_SIZES:-}" ]]; then
    # shellcheck disable=SC2206
    sizes=(${TALOS_HELPER_VM_SIZES})
  else
    if command -v python3 >/dev/null 2>&1; then
      echo "==> Probing helper VM sizes in ${LOCATION}"
      probed="$(pick_azure_vm_size "${LOCATION}" "${TALOS_HELPER_VM_SIZE:-}" 2 || true)"
      if [[ -n "${probed}" ]]; then
        echo "==> probe prefers ${probed}"
        sizes+=("${probed}")
      fi
    fi
    if [[ -n "${TALOS_HELPER_VM_SIZE:-}" ]]; then
      sizes+=("${TALOS_HELPER_VM_SIZE}")
    fi
    # shellcheck disable=SC2207
    sizes+=($(azure_vm_size_candidates))
  fi

  # run-command does not need SSH/public IP; VHD never touches the laptop.
  local seen_try=""
  for size in "${sizes[@]}"; do
    [[ " ${seen_try} " == *" ${size} "* ]] && continue
    seen_try+=" ${size}"
    echo "==> Creating helper VM ${HELPER_VM} (${size}, 64GiB OS disk, no public IP)"
    # Capture full stderr: az 2.87 can crash after printing the real ARM error.
    if az vm create \
      --resource-group "${HELPER_RG}" \
      --name "${HELPER_VM}" \
      --location "${LOCATION}" \
      --image Ubuntu2204 \
      --size "${size}" \
      --os-disk-size-gb 64 \
      --public-ip-address "" \
      --admin-username azureuser \
      --generate-ssh-keys \
      --output none 2>"${err}"; then
      chosen="${size}"
      break
    fi
    reason="$(grep -oiE 'QuotaExceeded|SkuNotAvailable|ZonalAllocationFailed|AllocationFailed' "${err}" | head -n1 || true)"
    if [[ -n "${reason}" ]]; then
      echo "    ${size}: ${reason} in ${LOCATION}; trying next…"
      continue
    fi
    echo "helper VM create failed:" >&2
    # Prefer the ARM message; skip the az-cli "content already consumed" traceback noise.
    if grep -q 'QuotaExceeded\|SkuNotAvailable\|InvalidTemplateDeployment' "${err}"; then
      grep -E 'QuotaExceeded|SkuNotAvailable|Message:|Exception Details|Current Limit' "${err}" | head -n 20 >&2 || cat "${err}" >&2
    else
      cat "${err}" >&2
    fi
    rm -f "${err}"
    exit 1
  done
  rm -f "${err}"

  if [[ -z "${chosen}" ]]; then
    echo "no helper VM size available in ${LOCATION} (quota and/or capacity)." >&2
    echo "  Check quota: az vm list-usage -l ${LOCATION} -o table | awk 'NR==1 || /CurrentLimit|Family|Total/'" >&2
    echo "  Or skip the helper VM and download locally:" >&2
    echo "    ./scripts/register-talos-image.sh ${LOCATION} ${TALOS_VERSION}" >&2
    echo "  Or set TALOS_HELPER_VM_SIZE to a family with quota > 0." >&2
    exit 1
  fi
  echo "==> Helper VM ready (${chosen})"

  echo "==> Helper VM downloading + uploading VHD (Image Factory → page blob)"
  echo "    This can take 10–20+ minutes; waiting on az vm run-command…"

  # Embed URLs in the remote script (SAS has shell-hostile chars; avoid --parameters).
  # Azure RunShellScript invokes via /bin/sh (dash) — re-exec under bash before pipefail.
  local remote_script
  remote_script="$(mktemp)"
  cat >"${remote_script}" <<EOF
if [ -z "\${BASH_VERSION:-}" ]; then exec /bin/bash "\$0" "\$@"; fi
set -euo pipefail
VHD_URL=$(printf '%q' "${VHD_URL}")
DEST=$(printf '%q' "${dest_with_sas}")
WORKDIR=/var/tmp/talos-vhd
mkdir -p "\${WORKDIR}"
cd "\${WORKDIR}"
echo "Downloading \${VHD_URL}"
curl -fsSL -o azure-amd64.vhd.xz "\${VHD_URL}"
xz -t azure-amd64.vhd.xz
xz -dkf azure-amd64.vhd.xz
echo "Installing azcopy"
curl -fsSL -o /tmp/azcopy.tgz https://aka.ms/downloadazcopy-v10-linux
tar -xzf /tmp/azcopy.tgz -C /tmp
AZCOPY="\$(find /tmp -type f -name azcopy | head -n1)"
test -n "\${AZCOPY}"
echo "Uploading page blob"
"\${AZCOPY}" copy "\${WORKDIR}/azure-amd64.vhd" "\${DEST}" --blob-type PageBlob --overwrite true
echo "Cleaning local VHD on helper"
rm -rf "\${WORKDIR}"
echo "DONE"
EOF

  az vm run-command invoke \
    --resource-group "${HELPER_RG}" \
    --name "${HELPER_VM}" \
    --command-id RunShellScript \
    --scripts @"${remote_script}" \
    --output json >/tmp/talos-vhd-helper-run.json
  rm -f "${remote_script}"

  if ! grep -q 'DONE' /tmp/talos-vhd-helper-run.json 2>/dev/null; then
    echo "helper VM run-command did not report DONE — see /tmp/talos-vhd-helper-run.json" >&2
    cat /tmp/talos-vhd-helper-run.json >&2 || true
    exit 1
  fi

  if ! az storage blob show \
    --account-name "${SA}" \
    --account-key "${SA_KEY}" \
    --container-name vhds \
    --name "${BLOB_NAME}" \
    --query name -o tsv >/dev/null; then
    echo "blob ${BLOB_NAME} missing after helper upload" >&2
    exit 1
  fi

  cleanup_helper
  trap - EXIT
}

if [[ "${IN_AZURE}" -eq 1 ]]; then
  upload_in_azure
else
  upload_local
fi

echo "==> Creating gallery image version ${IMAGE_VERSION}"
az sig image-version create \
  --resource-group "${RG}" \
  --gallery-name "${GALLERY}" \
  --gallery-image-definition "${IMAGE_DEF}" \
  --gallery-image-version "${IMAGE_VERSION}" \
  --os-vhd-uri "${BLOB_URL}" \
  --os-vhd-storage-account "/subscriptions/$(az account show --query id -o tsv)/resourceGroups/${RG}/providers/Microsoft.Storage/storageAccounts/${SA}" \
  --location "${LOCATION}" \
  --output none

IMAGE_ID="$(az sig image-version show \
  --resource-group "${RG}" \
  --gallery-name "${GALLERY}" \
  --gallery-image-definition "${IMAGE_DEF}" \
  --gallery-image-version "${IMAGE_VERSION}" \
  --query id -o tsv)"

echo ""
echo "Talos image ready:"
echo "  ${IMAGE_ID}"
echo ""
echo "Configure + bring up primary (one shot):"
echo "  ./scripts/init-azure-metal-sim.sh --write-clusters --location ${LOCATION} --image-id '${IMAGE_ID}' --up"
echo "Or config only:"
echo "  ./scripts/init-azure-metal-sim.sh --write-clusters --location ${LOCATION} --image-id '${IMAGE_ID}'"
echo "Disk device default for metal-sim patches is /dev/sda (override with primary:installDisk)."
echo "Note: gallery RG ${RG} is NOT destroyed by ./scripts/destroy.sh — delete with:"
echo "  az group delete -n ${RG} --yes --no-wait"
if [[ "${IN_AZURE}" -eq 0 ]]; then
  echo "Local temp (optional cleanup): rm -rf ${ROOT}/.secrets/talos-image-${LOCATION}"
fi
