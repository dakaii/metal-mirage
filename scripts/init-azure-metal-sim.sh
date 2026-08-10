#!/usr/bin/env bash
# One-shot Azure metal-sim lab bootstrap: clusters.yaml + Pulumi primary config.
#
# Usage:
#   ./scripts/init-azure-metal-sim.sh [flags]
#
# Typical:
#   ./scripts/register-talos-image.sh --in-azure eastus
#   ./scripts/init-azure-metal-sim.sh --write-clusters --up
#
# Flags:
#   --location LOC       Azure region (default: eastus)
#   --stack NAME         Pulumi stack (default: $PULUMI_STACK or dev)
#   --image-id ID        Gallery image resource ID (default: discover latest in talos-images)
#   --cp N               controlPlaneCount (default: 1)
#   --workers N          workerCount (default: 1)
#   --admin-cidr CIDR    NSG admin CIDR (default: $(curl ifconfig.me)/32)
#   --write-clusters     Copy config/clusters.azure-metal-sim.example.yaml → clusters.yaml
#   --up                 Run ./scripts/up.sh primary after config
#   -h, --help
#
# Env: PULUMI_CONFIG_PASSPHRASE (recommended), PULUMI_STACK, TALOS_IMAGE_RG / GALLERY / DEF
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "${ROOT}/scripts/lib.sh"

LOCATION="eastus"
STACK="${PULUMI_STACK:-dev}"
IMAGE_ID="${TALOS_IMAGE_ID:-}"
CP_COUNT=1
WORKER_COUNT=1
ADMIN_CIDR="${ADMIN_CIDR:-}"
WRITE_CLUSTERS=0
DO_UP=0
RG="${TALOS_IMAGE_RG:-talos-images}"
GALLERY="${TALOS_IMAGE_GALLERY:-talosgallery}"
IMAGE_DEF="${TALOS_IMAGE_DEF:-talos}"

usage() {
  sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    --location)
      LOCATION="$2"
      shift 2
      ;;
    --stack)
      STACK="$2"
      shift 2
      ;;
    --image-id)
      IMAGE_ID="$2"
      shift 2
      ;;
    --cp)
      CP_COUNT="$2"
      shift 2
      ;;
    --workers)
      WORKER_COUNT="$2"
      shift 2
      ;;
    --admin-cidr)
      ADMIN_CIDR="$2"
      shift 2
      ;;
    --write-clusters)
      WRITE_CLUSTERS=1
      shift
      ;;
    --up)
      DO_UP=1
      shift
      ;;
    -*)
      echo "unknown flag: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      echo "unexpected argument: $1" >&2
      exit 1
      ;;
  esac
done

need pulumi
need curl

discover_image_id() {
  need az
  if ! az account show >/dev/null 2>&1; then
    echo "az not logged in — run ./scripts/login.sh (or pass --image-id)" >&2
    exit 1
  fi
  local id
  id="$(az sig image-version list \
    --resource-group "${RG}" \
    --gallery-name "${GALLERY}" \
    --gallery-image-definition "${IMAGE_DEF}" \
    --query "sort_by(@, &name)[-1].id" \
    -o tsv 2>/dev/null || true)"
  if [[ -z "${id}" || "${id}" == "null" ]]; then
    echo "no gallery image in ${RG}/${GALLERY}/${IMAGE_DEF}." >&2
    echo "  Run: ./scripts/register-talos-image.sh --in-azure ${LOCATION}" >&2
    echo "  Or:  --image-id '/subscriptions/.../versions/1.9.5'" >&2
    exit 1
  fi
  printf '%s\n' "${id}"
}

if [[ "${WRITE_CLUSTERS}" -eq 1 ]]; then
  src="${ROOT}/config/clusters.azure-metal-sim.example.yaml"
  dst="${ROOT}/config/clusters.yaml"
  if [[ ! -f "${src}" ]]; then
    echo "missing ${src}" >&2
    exit 1
  fi
  if [[ -f "${dst}" ]]; then
    bak="${dst}.bak.$(date +%Y%m%d%H%M%S)"
    cp "${dst}" "${bak}"
    echo "==> backed up clusters.yaml → ${bak#"${ROOT}"/}"
  fi
  cp "${src}" "${dst}"
  echo "==> wrote config/clusters.yaml (azure-metal-sim)"
else
  prov="$(yaml_section_key primary provisioner | tr -d '[:space:]')"
  if [[ "${prov}" != "azure-metal-sim" ]]; then
    echo "primary.provisioner is '${prov:-unset}' (want azure-metal-sim)." >&2
    echo "  Re-run with --write-clusters  or: cp config/clusters.azure-metal-sim.example.yaml config/clusters.yaml" >&2
    exit 1
  fi
fi

DIR="$(resolve_pulumi_dir primary)"
if [[ -z "${DIR}" || ! -d "${ROOT}/${DIR}" ]]; then
  echo "primary.pulumi_dir unresolved — check config/clusters.yaml" >&2
  exit 1
fi

if [[ -z "${IMAGE_ID}" ]]; then
  echo "==> Discovering latest Talos gallery image (${RG}/${GALLERY}/${IMAGE_DEF})"
  IMAGE_ID="$(discover_image_id)"
fi
echo "==> talosImageId: ${IMAGE_ID}"

if [[ -z "${ADMIN_CIDR}" ]]; then
  echo "==> Detecting public IP for adminCidr"
  ADMIN_CIDR="$(curl -fsSL ifconfig.me)/32"
fi
echo "==> adminCidr: ${ADMIN_CIDR}"

echo "==> Configuring Pulumi stack ${STACK} in ${DIR}"
(
  cd "${ROOT}/${DIR}"
  pulumi stack select "${STACK}" 2>/dev/null || pulumi stack init "${STACK}"
  pulumi config set azure-native:location "${LOCATION}"
  pulumi config set primary:talosImageId "${IMAGE_ID}"
  pulumi config set primary:adminCidr "${ADMIN_CIDR}"
  pulumi config set primary:controlPlaneCount "${CP_COUNT}"
  pulumi config set primary:workerCount "${WORKER_COUNT}"
)

echo ""
echo "Primary stack configured."
echo "  Tip: export PULUMI_CONFIG_PASSPHRASE=… to avoid passphrase prompts."
if [[ "${DO_UP}" -eq 1 ]]; then
  echo "==> ./scripts/up.sh primary"
  PULUMI_STACK="${STACK}" "${ROOT}/scripts/up.sh" primary
else
  echo "Next: ./scripts/up.sh primary"
  echo "  (or re-run with --up)"
fi
