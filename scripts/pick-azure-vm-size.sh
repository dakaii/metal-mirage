#!/usr/bin/env bash
# Pick an Azure VM size that has quota (and is not SKU-restricted) in a region.
#
# Usage:
#   ./scripts/pick-azure-vm-size.sh [location] [total_cores_needed]
#
# Env:
#   AZURE_VM_SIZE_CANDIDATES  space-separated preference list
#   AZURE_VM_SIZE             prefer this size first (still checked)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "${ROOT}/scripts/lib.sh"
# shellcheck source=scripts/lib-azure-vm.sh
source "${ROOT}/scripts/lib-azure-vm.sh"

LOCATION="${1:-eastus}"
TOTAL_CORES="${2:-2}"

need az
need python3

if ! az account show >/dev/null 2>&1; then
  echo "az not logged in — run: ./scripts/login.sh" >&2
  exit 1
fi

echo "==> Probing Azure VM sizes in ${LOCATION} (need ${TOTAL_CORES} vCPUs)" >&2
if size="$(pick_azure_vm_size "${LOCATION}" "${AZURE_VM_SIZE:-}" "${TOTAL_CORES}")"; then
  echo "${size}"
  exit 0
fi

echo "no suitable VM size in ${LOCATION} with ${TOTAL_CORES} free vCPUs." >&2
echo "  Inspect: az vm list-usage -l ${LOCATION} -o table" >&2
echo "  Override candidates: AZURE_VM_SIZE_CANDIDATES='Standard_D2s_v4 …'" >&2
exit 1
