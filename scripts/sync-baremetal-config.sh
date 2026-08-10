#!/usr/bin/env bash
# Push config/clusters.yaml primary inventory into Pulumi baremetal:* keys.
# Single source of truth: clusters.yaml (no separate pulumi config set baremetal:nodes).
#
# Usage: ./scripts/sync-baremetal-config.sh
# Env:   PULUMI_STACK (default: dev)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "${ROOT}/scripts/lib.sh"
STACK="${PULUMI_STACK:-dev}"
CLUSTERS="${ROOT}/config/clusters.yaml"

need pulumi "Install: https://www.pulumi.com/docs/install/"
need go "Need Go 1.26.x (matches CI)."

provisioner="$(yaml_section_key primary provisioner | tr -d '[:space:]')"
if [[ "${provisioner}" != "bare-metal" ]]; then
  echo "primary.provisioner is ${provisioner:-unset} — sync only applies to bare-metal (nothing to do)"
  exit 0
fi

echo "==> resolving baremetal:* from config/clusters.yaml"
mapfile -t LINES < <(
  cd "${ROOT}/infra/bare-metal"
  go run -tags syncconfig . "${CLUSTERS}"
)
if [[ "${#LINES[@]}" -lt 5 ]]; then
  echo "syncconfig produced incomplete output" >&2
  exit 1
fi

NODES_JSON="${LINES[0]}"
API_IP="${LINES[1]}"
INGRESS_IP="${LINES[2]}"
INSTALL_DISK="${LINES[3]}"
DRY_RUN="${LINES[4]}"

echo "==> writing Pulumi stack ${STACK} (infra/bare-metal)"
(
  cd "${ROOT}/infra/bare-metal"
  pulumi stack select "${STACK}" 2>/dev/null || pulumi stack init "${STACK}"
  pulumi config set baremetal:nodes "${NODES_JSON}"
  pulumi config set baremetal:apiEndpointIP "${API_IP}"
  pulumi config set baremetal:ingressIP "${INGRESS_IP}"
  pulumi config set baremetal:installDisk "${INSTALL_DISK}"
  pulumi config set baremetal:dryRun "${DRY_RUN}"
)

echo "  nodes:         ${NODES_JSON}"
echo "  apiEndpointIP: ${API_IP}"
echo "  ingressIP:     ${INGRESS_IP}"
echo "  installDisk:   ${INSTALL_DISK}"
echo "  dryRun:        ${DRY_RUN}"
echo "Done. Edit config/clusters.yaml and re-run (or ./scripts/up.sh primary) to refresh."
