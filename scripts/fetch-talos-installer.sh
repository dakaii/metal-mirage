#!/usr/bin/env bash
# Thin wrapper around tools/talos-installer (Go) — checksum-verified Talos metal assets.
#
# Usage:
#   ./scripts/fetch-talos-installer.sh              # metal ISO (default)
#   ./scripts/fetch-talos-installer.sh pxe-set       # kernel+initramfs + boot.ipxe
#   ./scripts/fetch-talos-installer.sh iso --version v1.9.5 --arch amd64
#   ./scripts/fetch-talos-installer.sh pxe-set --http-base http://192.168.10.2:8080
#
# Env: TALOS_VERSION, TALOS_ARCH, OUT_DIR, HTTP_BASE (for iPXE; CLI --http-base wins)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "${ROOT}/scripts/lib.sh"

need go "Need Go 1.26.x (matches CI)."

ASSET="${1:-iso}"
if [[ "${ASSET}" == -* ]]; then
  ASSET="iso"
else
  shift || true
fi

VERSION="${TALOS_VERSION:-v1.9.5}"
ARCH="${TALOS_ARCH:-amd64}"
OUT_DIR="${OUT_DIR:-${ROOT}/.secrets/talos-installer}"
HTTP_BASE="${HTTP_BASE:-http://PXE_HOST:8080}"
WRITE_IPXE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      VERSION="$2"
      shift 2 || exit 1
      ;;
    --arch)
      ARCH="$2"
      shift 2 || exit 1
      ;;
    --out)
      OUT_DIR="$2"
      shift 2 || exit 1
      ;;
    --write-ipxe)
      WRITE_IPXE=1
      shift
      ;;
    --http-base)
      HTTP_BASE="$2"
      shift 2 || exit 1
      ;;
    -version | -arch | -out | -http-base)
      # raw Go-style flags
      key="$1"
      val="$2"
      shift 2 || exit 1
      case "${key}" in
        -version) VERSION="${val}" ;;
        -arch) ARCH="${val}" ;;
        -out) OUT_DIR="${val}" ;;
        -http-base) HTTP_BASE="${val}" ;;
      esac
      ;;
    -write-ipxe)
      WRITE_IPXE=1
      shift
      ;;
    *)
      echo "unexpected arg: $1" >&2
      exit 1
      ;;
  esac
done

args=(-version "${VERSION}" -arch "${ARCH}" -asset "${ASSET}" -out "${OUT_DIR}")
if [[ "${ASSET}" == "pxe-set" || "${WRITE_IPXE}" -eq 1 ]]; then
  args+=(-http-base "${HTTP_BASE}")
fi
if [[ "${WRITE_IPXE}" -eq 1 && "${ASSET}" != "pxe-set" ]]; then
  args+=(-write-ipxe)
fi

echo "==> go run (tools/talos-installer) ${args[*]}"
go -C "${ROOT}/tools/talos-installer" run . "${args[@]}"
