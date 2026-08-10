#!/usr/bin/env bash
# Thin wrapper around tools/talos-installer (Go) — checksum-verified Talos metal assets.
#
# Usage:
#   ./scripts/fetch-talos-installer.sh              # metal ISO (default)
#   ./scripts/fetch-talos-installer.sh pxe-set       # kernel+initramfs + boot.ipxe
#   ./scripts/fetch-talos-installer.sh iso --version v1.9.5 --arch amd64
#
# Env: TALOS_VERSION, TALOS_ARCH, OUT_DIR, HTTP_BASE (for iPXE)
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

args=(-version "${VERSION}" -arch "${ARCH}" -asset "${ASSET}" -out "${OUT_DIR}")
# Extra CLI flags after asset name, e.g. --write-ipxe via passthrough as -write-ipxe
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      args+=(-version "$2"); shift 2 || exit 1
      ;;
    --arch)
      args+=(-arch "$2"); shift 2 || exit 1
      ;;
    --out)
      args+=(-out "$2"); shift 2 || exit 1
      ;;
    --write-ipxe)
      args+=(-write-ipxe); shift
      ;;
    --http-base)
      args+=(-http-base "$2"); shift 2 || exit 1
      ;;
    -*)
      # allow raw Go flags
      args+=("$1"); shift
      ;;
    *)
      echo "unexpected arg: $1" >&2
      exit 1
      ;;
  esac
done

# Always pass http-base for pxe-set / write-ipxe convenience
if [[ "${ASSET}" == "pxe-set" ]]; then
  args+=(-http-base "${HTTP_BASE}")
fi

echo "==> go run (tools/talos-installer) ${args[*]}"
go -C "${ROOT}/tools/talos-installer" run . "${args[@]}"
