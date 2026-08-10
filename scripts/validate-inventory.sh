#!/usr/bin/env bash
# Offline validation of the portable L1 inventory contract (no Azure / no hardware).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "${ROOT}/scripts/lib.sh"

need go "Need Go 1.26.x (matches CI / infra go.mod)."

echo "==> validate config/clusters.yaml capability ports (remote_access)"
(
  cd "${ROOT}/pkg/ports"
  go test ./...
)

echo "==> validate config/clusters.yaml + bare-metal inventory contract"
(
  cd "${ROOT}/infra/bare-metal"
  go test ./...
)

echo "OK — inventory + capability-port contracts are valid (offline)."
