#!/usr/bin/env bash
# Register a Talos Linux VHD as an Azure shared image (one-time per region).
# Usage: ./scripts/register-talos-image.sh [location] [talos-version]
set -euo pipefail

LOCATION="${1:-eastus}"
TALOS_VERSION="${2:-v1.9.5}"
RG="${TALOS_IMAGE_RG:-talos-images}"
GALLERY="${TALOS_IMAGE_GALLERY:-talosgallery}"
IMAGE_DEF="${TALOS_IMAGE_DEF:-talos}"
IMAGE_VERSION="${TALOS_VERSION#v}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORKDIR="${ROOT}/.secrets/talos-image-${LOCATION}"
mkdir -p "${WORKDIR}"

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required tool: $1" >&2
    exit 1
  }
}

need az
need curl
need xz

if ! az account show >/dev/null 2>&1; then
  echo "az not logged in — run: az login" >&2
  exit 1
fi

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

VHD_URL="https://github.com/siderolabs/talos/releases/download/${TALOS_VERSION}/azure-amd64.vhd.xz"
VHD_XZ="${WORKDIR}/azure-amd64.vhd.xz"
VHD="${WORKDIR}/azure-amd64.vhd"

if [[ ! -f "${VHD}" ]]; then
  echo "==> Downloading ${VHD_URL}"
  curl -fsSL -o "${VHD_XZ}" "${VHD_URL}"
  echo "==> Decompressing VHD (this takes a while)"
  xz -dkf "${VHD_XZ}"
fi

SA="talosimg${LOCATION}"
SA="${SA//-/}"
SA="$(echo "${SA}" | tr '[:upper:]' '[:lower:]' | cut -c1-24)"

echo "==> Ensuring storage account ${SA}"
az storage account create \
  --name "${SA}" \
  --resource-group "${RG}" \
  --location "${LOCATION}" \
  --sku Standard_LRS \
  --kind StorageV2 \
  --output none 2>/dev/null || true

az storage container create --account-name "${SA}" --name vhds --auth-mode login --output none 2>/dev/null || \
  az storage container create --account-name "${SA}" --name vhds --output none

echo "==> Uploading VHD (azcopy or az storage)"
BLOB_URL="$(az storage blob url --account-name "${SA}" --container-name vhds --name "talos-${TALOS_VERSION}.vhd" --output tsv)"
if command -v azcopy >/dev/null 2>&1; then
  azcopy copy "${VHD}" "${BLOB_URL}" --blob-type PageBlob
else
  echo "azcopy not found; using az storage blob upload (slower)"
  az storage blob upload \
    --account-name "${SA}" \
    --container-name vhds \
    --name "talos-${TALOS_VERSION}.vhd" \
    --file "${VHD}" \
    --type page \
    --overwrite true
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
echo "Configure primary stack:"
echo "  cd infra/primary && pulumi config set primary:talosImageId '${IMAGE_ID}'"
echo "Disk device default for metal-sim patches is /dev/sda (override with primary:installDisk)."
echo "Note: gallery RG ${RG} is NOT destroyed by ./scripts/destroy.sh — delete manually when done."
