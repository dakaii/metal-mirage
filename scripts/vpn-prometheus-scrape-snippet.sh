#!/usr/bin/env bash
# Print a Prometheus scrape snippet for the VPN gateway node_exporter.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}/infra/vpn-gateways"
IP="$(pulumi stack output publicIP)"
PORT="$(pulumi stack output metricsPort)"
CITY="$(pulumi stack output city)"

cat <<EOF
# Add under kube-prometheus-stack additionalScrapeConfigs:
- job_name: vpn-gateway
  static_configs:
    - targets: ['${IP}:${PORT}']
      labels:
        city: ${CITY}
        role: vpn-gateway
EOF
