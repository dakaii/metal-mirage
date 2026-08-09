#!/usr/bin/env bash
# Offline validation of the portable L1 inventory contract (no Azure / no hardware).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required tool: $1" >&2
    exit 1
  }
}

need go

echo "==> validate config/clusters.yaml + bare-metal inventory contract"
(
  cd "${ROOT}/infra/bare-metal"
  go test ./...
)

echo "OK — inventory contract is valid (offline)."
