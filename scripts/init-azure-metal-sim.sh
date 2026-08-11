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
#   --talos-version VER  primary:talosVersion (default: v1.9.5 — must match gallery VHD)
#   --admin-cidr CIDR    NSG admin CIDR (default: public IP /32)
#   --write-clusters     Ensure config/clusters.yaml is azure-metal-sim (backup if replacing)
#   --force-clusters     Always overwrite clusters.yaml from the example
#   --up                 Run ./scripts/up.sh primary after config
#   -h, --help
#
# Env: PULUMI_CONFIG_PASSPHRASE (recommended), PULUMI_STACK,
#      TALOS_IMAGE_ID, TALOS_IMAGE_RG, TALOS_IMAGE_GALLERY, TALOS_IMAGE_DEF,
#      TALOS_VERSION, ADMIN_CIDR
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "${ROOT}/scripts/lib.sh"

LOCATION="eastus"
STACK="${PULUMI_STACK:-dev}"
IMAGE_ID="${TALOS_IMAGE_ID:-}"
CP_COUNT=1
WORKER_COUNT=1
TALOS_VERSION="${TALOS_VERSION:-v1.9.5}"
ADMIN_CIDR="${ADMIN_CIDR:-}"
WRITE_CLUSTERS=0
FORCE_CLUSTERS=0
DO_UP=0
RG="${TALOS_IMAGE_RG:-talos-images}"
GALLERY="${TALOS_IMAGE_GALLERY:-talosgallery}"
IMAGE_DEF="${TALOS_IMAGE_DEF:-talos}"

usage() {
  sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'
}

need_arg() {
  local flag="$1"
  if [[ $# -lt 2 || -z "${2:-}" || "${2:-}" == -* ]]; then
    echo "flag ${flag} requires a value" >&2
    exit 1
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    --location)
      need_arg "$1" "${2:-}"
      LOCATION="$2"
      shift 2
      ;;
    --stack)
      need_arg "$1" "${2:-}"
      STACK="$2"
      shift 2
      ;;
    --image-id)
      need_arg "$1" "${2:-}"
      IMAGE_ID="$2"
      shift 2
      ;;
    --cp)
      need_arg "$1" "${2:-}"
      CP_COUNT="$2"
      shift 2
      ;;
    --workers)
      need_arg "$1" "${2:-}"
      WORKER_COUNT="$2"
      shift 2
      ;;
    --talos-version)
      need_arg "$1" "${2:-}"
      TALOS_VERSION="$2"
      shift 2
      ;;
    --admin-cidr)
      need_arg "$1" "${2:-}"
      ADMIN_CIDR="$2"
      shift 2
      ;;
    --write-clusters)
      WRITE_CLUSTERS=1
      shift
      ;;
    --force-clusters)
      WRITE_CLUSTERS=1
      FORCE_CLUSTERS=1
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

if ! [[ "${CP_COUNT}" =~ ^[0-9]+$ && "${WORKER_COUNT}" =~ ^[0-9]+$ ]]; then
  echo "--cp and --workers must be non-negative integers" >&2
  exit 1
fi

discover_image_id() {
  need az
  if ! az account show >/dev/null 2>&1; then
    echo "az not logged in — run ./scripts/login.sh (or pass --image-id)" >&2
    exit 1
  fi
  local id
  # Prefer newest by publishedDate; fall back to name sort for older API shapes.
  id="$(az sig image-version list \
    --resource-group "${RG}" \
    --gallery-name "${GALLERY}" \
    --gallery-image-definition "${IMAGE_DEF}" \
    --query "max_by(@, &publishingProfile.publishedDate).id" \
    -o tsv 2>/dev/null || true)"
  if [[ -z "${id}" || "${id}" == "null" ]]; then
    id="$(az sig image-version list \
      --resource-group "${RG}" \
      --gallery-name "${GALLERY}" \
      --gallery-image-definition "${IMAGE_DEF}" \
      --query "sort_by(@, &name)[-1].id" \
      -o tsv 2>/dev/null || true)"
  fi
  if [[ -z "${id}" || "${id}" == "null" ]]; then
    echo "no gallery image in ${RG}/${GALLERY}/${IMAGE_DEF}." >&2
    echo "  Run: ./scripts/register-talos-image.sh --in-azure ${LOCATION}" >&2
    echo "  Or:  --image-id '/subscriptions/.../versions/1.9.5'" >&2
    exit 1
  fi
  printf '%s\n' "${id}"
}

# shellcheck source=scripts/lib-azure-vm.sh
source "${ROOT}/scripts/lib-azure-vm.sh"

if [[ "${WRITE_CLUSTERS}" -eq 1 ]]; then
  src="${ROOT}/config/clusters.azure-metal-sim.example.yaml"
  dst="${ROOT}/config/clusters.yaml"
  if [[ ! -f "${src}" ]]; then
    echo "missing ${src}" >&2
    exit 1
  fi
  prov=""
  if [[ -f "${dst}" ]]; then
    prov="$(yaml_section_key primary provisioner | tr -d '[:space:]')"
  fi
  if [[ "${FORCE_CLUSTERS}" -eq 0 && "${prov}" == "azure-metal-sim" ]]; then
    echo "==> config/clusters.yaml already azure-metal-sim (use --force-clusters to overwrite)"
  else
    if [[ -f "${dst}" ]]; then
      bak="${dst}.bak.$(date +%Y%m%d%H%M%S)"
      cp "${dst}" "${bak}"
      echo "==> backed up clusters.yaml → ${bak#"${ROOT}"/}"
    fi
    cp "${src}" "${dst}"
    echo "==> wrote config/clusters.yaml (azure-metal-sim)"
  fi
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
  echo "==> Detecting public IP for adminCidr (/24 — CGNAT-friendly; override with --admin-cidr)"
  if ! ADMIN_CIDR="$(detect_admin_cidr "${ADMIN_CIDR_PREFIX_LEN:-24}")"; then
    echo "  Pass --admin-cidr 'x.x.x.x/32' (or a /24) explicitly." >&2
    exit 1
  fi
fi
if ! [[ "${ADMIN_CIDR}" =~ ^[0-9./]+$ || "${ADMIN_CIDR}" =~ : ]]; then
  echo "adminCidr looks invalid: ${ADMIN_CIDR}" >&2
  exit 1
fi
echo "==> adminCidr: ${ADMIN_CIDR}"

echo "==> Configuring Pulumi stack ${STACK} in ${DIR}"
(
  cd "${ROOT}/${DIR}"
  pulumi stack select "${STACK}" 2>/dev/null || pulumi stack init "${STACK}"
  pulumi config set azure-native:location "${LOCATION}"
  pulumi config set primary:talosImageId "${IMAGE_ID}"
  pulumi config set primary:talosVersion "${TALOS_VERSION}"
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
